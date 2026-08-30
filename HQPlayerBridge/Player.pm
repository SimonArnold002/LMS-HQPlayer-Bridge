package Plugins::HQPlayerBridge::Player;

# A virtual LMS player that drives HQPlayer over its XML control API.
#
# No audio passes through this module.  Both LMS and HQPlayer are pull
# engines: LMS hands a player a URL and the player fetches the bytes itself,
# and HQPlayer does exactly the same.  So the bridge only ever moves control
# messages, and hands HQPlayer a URL pointing back at LMS's own HTTP server.
#
# We subclass Slim::Player::Player rather than Slim::Player::Squeezebox
# deliberately: everything that assumes a live SlimProto socket ($client->
# tcpsock) lives in Squeezebox and below, so starting from Player sidesteps
# all of it.  The same trick is what makes philippe44's LMS-Groups work.

use strict;
use warnings;

use base qw(Slim::Player::Player);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Music::Info;
use Slim::Player::ProtocolHandlers;
use Slim::Player::ReplayGain;
use Slim::Utils::Network;
use Slim::Web::HTTP;          # forgetClient, for closeStream below
use Time::HiRes ();

use Plugins::HQPlayerBridge::Control;
use Plugins::HQPlayerBridge::Stream;
use Plugins::HQPlayerBridge::UPnP;

# Slim::Player::Client objects are BLESSED ARRAYS - Slim::Utils::Accessor
# stores each field in a numbered slot ($_[0]->[$n]), not a hash key.  So
# $client->{anything} is a fatal "Not a HASH reference", and every piece of
# per-player state has to be a declared accessor.  ('rw' switches on argument
# count, @_ == 2, so storing 0 and undef both work correctly.)
__PACKAGE__->mk_accessor( 'rw', qw(
    hqControl hqUPnP hqInstance
    hqTier hqRate hqBits hqTransport hqEngine hqProduct
    hqStarted hqExpectStop hqPosition hqLastStatus hqSeekOffset
    hqWanted hqVolDb hqVolMin hqVolMax hqVolFixed hqVolForced
    hqVolSent hqVolSentAt hqVolMissed
    hqGen hqPlayAck hqURL hqPrevURL
    hqNext hqArmNext hqTrackNo hqStaleRun hqStartedAt
) );

my $log        = logger('plugin.hqplayerbridge');
my $serverPrefs = preferences('server');

# <Status/> is a SUBSCRIBE, not a poll: one is enough, after which HQPlayer
# streams status at roughly 1/s on its own.  So we never poll - we only keep a
# slow watchdog to re-subscribe if the stream ever dries up.
use constant STATUS_WATCHDOG => 10;

# How long a stop is held before it is reported as the end of the playlist, and
# ONLY while a hand-over is queued.  A gapless track boundary shows up as a
# transient state 0 that is byte-identical to a real one - see the end-of-track
# branch in _onStatus.  Observed at ~2s on engine 6.0.4; 3 gives it room.
use constant END_GRACE => 3;

# How long after a track is confirmed playing a state 0 is treated as start-up
# noise rather than the end.  A tier 4 stream goes through LMS's transcoder, so
# HQPlayer reports PLAYING and then briefly STOPPED while the first bytes are
# still coming: measured at 0.33s live, which read as end-of-playlist and
# skipped the track outright.  A track cannot meaningfully end this fast, and
# one that did would simply be reported a push or two later.
use constant START_GRACE => 2;

# HQPlayer reports state as an INTEGER, not a word - verified live 2026-08-26
# by driving a real track through Play/Pause/Stop and watching <Status/>.
use constant HQP_STOPPED => 0;
use constant HQP_PAUSED  => 1;
use constant HQP_PLAYING => 2;

# HQPlayer picks its decoder from the HTTP Content-Type, NOT from the filename
# - verified live: it refused a track with "clPlaylist::AddURI(): unknown mime
# type: audio/m4a" even though the URL ended in a sensible extension.  Its mime
# table (extracted from the binary) covers flac, wav, aiff, dsf/dff, wavpack,
# mpeg/mp3 and ogg, and contains NO m4a, mp4, aac or alac entry at all.
#
# So tier 1 is only usable for formats HQPlayer will actually accept; anything
# else has to go through LMS's transcoder on tier 3.  Keyed by LMS content_type.
my %HQP_PLAYS = map { $_ => 1 } qw(
    flc flac wav aif aiff dsf dff wvp wv mp3 mp2 ogg ogf
);

# LMS's internal content-type codes are not all valid filename extensions.  The
# extension still matters to LMS itself: downloadMusicFile only transcodes when
# the resolved type differs from the track's own, so a truthful extension keeps
# it a byte-for-byte passthrough.
#
# There is no MIME table any more.  It existed to fill the DIDL's
# <res protocolInfo>, and the load no longer goes over UPnP; HQPlayer decides
# by Content-Type and reports what it found back on the playlist item's own
# `mime` attribute (audio/x-flac, confirmed live).
my %EXT_FOR_TYPE = (
    flc => 'flac',
    aif => 'aiff',
    wvp => 'wv',
    ogf => 'ogg',
);

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
sub new {
    my $class = shift;

    my $client = $class->SUPER::new(@_);

    $client->init_accessor(
        hqStarted    => 0,
        hqExpectStop => 0,
        hqPosition   => undef,
        hqTier       => undef,
        hqLastStatus => 0,
        hqSeekOffset => 0,
        hqWanted     => 'stop',
        hqGen        => 0,
        hqPlayAck    => 0,
        hqNext       => undef,
        hqArmNext    => 0,
        hqTrackNo    => undef,
        hqStaleRun   => 0,
        hqStartedAt  => 0,
    );

    return $client;
}

sub model     { 'hqplayer' }
sub modelName { 'HQPlayer' }
sub formats   { qw(flc pcm aif mp3) }   # order is LMS's preference order

sub maxSupportedSamplerate { 768000 }

# TRAP: declaring flc first is NOT enough to be sent FLAC.
#
# Slim::Utils::Prefs::maxRate applies a bitrate cap when the maxBitrate client
# pref has never been set, and its default is by player family: wired
# Squeezeboxen and all SB2s get 0 (no limit), and EVERY OTHER PLAYER gets
# 320kbps.  This player is deliberately a Slim::Player::Player subclass rather
# than a Squeezebox (see the note on that choice above), so it lands in "every
# other player" and LMS transcodes to MP3 to fit the cap - a 750kbps Qobuz FLAC
# arrives at HQPlayer as MP3 320, and any tag the original carried, replaygain
# included, is gone with it.  VERIFIED against the live server 2026-08-28: with
# the pref unset the stream is MP3, and with it 0 the same endpoint answers
# Content-Type: audio/x-flac and a body starting `fLaC` + STREAMINFO.
#
# This is invisible in tier 1, which is a plain file download and never goes
# near the cap - which is why local playback always sounded right and only
# streaming was quietly downgraded.
#
# philippe_44's bridges do not need this: their players connect over slimproto,
# so LMS builds them as Squeezebox2 subclasses and the default gives them no
# limit for free.  We have to ask.
#
# Only when the pref has never been set.  A user who has deliberately chosen a
# limit owns that choice, and undef is exactly LMS's own "not been set yet".
sub initBitrateLimit {
    my $self = shift;

    my $cprefs = $serverPrefs->client($self);

    return if defined $cprefs->get('maxBitrate');

    $cprefs->set( 'maxBitrate', 0 );

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': no bitrate limit was set - defaulting to unlimited, so LMS streams FLAC rather than transcoding to MP3' );

    return 1;
}

sub isPlayer          { 1 }
# Volume is shared with HQPlayer rather than owned by either side - see the
# volume() block below for the mapping and for both directions of the sync.
sub hasVolumeControl  { 1 }
sub hasDigitalOut     { 1 }
# DIRECT STREAMING - hand HQPlayer the SERVICE'S OWN final URL (tier 5).
#
# This used to be a flat 0, on the belief that HQPlayer could not fetch a URL
# containing a query string. THAT BELIEF WAS WRONG - disproven on the wire
# 2026-08-28; HQPlayer transmits query strings verbatim and plays the track,
# and merely STRIPS them from everything it reports. See CLAUDE.md.
#
# With that gone there is no reason to proxy a streaming service through LMS's
# player stream. LMS's own hook hands us the resolved, signed CDN URL, exactly
# as it does for a Squeezebox - Slim::Player::Squeezebox2::canDirectStream is
# these same few lines. Returning a URL makes Song::open set directstream(1)
# and open NO socket, so tier 4's one-stream-per-player limit does not apply
# and a streaming track can be pre-queued like a local one.
#
# THE GATING HAS TO BE HERE, NOT IN _resolveURL. Once Song::open has taken the
# direct branch there is no source socket to fall back to, so anything we
# cannot serve directly must be refused HERE and left to tier 4.
sub canDirectStream {
    my ( $client, $url, $song ) = @_;

    return 0 unless $song;

    my $handler = eval { $song->currentTrackHandler } or return 0;

    # A handler that parses the response headers itself (radio, ICY metadata)
    # expects the player to call back into directHeaders with what the server
    # said. A Squeezebox can: it makes the HTTP request. WE DO NOT - HQPlayer
    # fetches the URL and never tells us anything about the response. So those
    # stay on tier 4, where LMS opens the socket and sees the headers itself.
    return 0 if $handler->can('handlesStreamHeaders');

    my $direct =
          $handler->can('canDirectStreamSong') ? eval { $handler->canDirectStreamSong( $client, $song ) }
        : $handler->can('canDirectStream')     ? eval { $handler->canDirectStream( $client, $url ) }
        :                                        undef;

    return 0 unless $direct && !ref $direct;

    # HQPlayer DOES NOT FOLLOW A 302 - the one half of the old rule that
    # survived. The url we hand over has to be the final one, so anything that
    # is not a plain http(s) address goes back to tier 4 rather than being
    # handed over and silently never fetched.
    return 0 unless $direct =~ m{^https?://};

    main::INFOLOG && $log->is_info && $log->info(
        $client->name . ": direct streaming - $url -> $direct" );

    return $direct;
}

# Qobuz and Tidal are HTTPS. HQPlayer does TLS: pointed at
# https://www.signalyst.com it returned a real 404 over the wire, not a
# connection error. LMS only consults this when the url redirects, but the
# answer is still yes.
sub canHTTPS         { 1 }
sub canDoReplayGain   { 0 }
sub needsWeightedPlayPoint { 0 }
sub connected         { $_[0]->tcpsock ? 1 : 0 }
sub opened            { undef }
sub signalStrength    { 100 }

# TRAP: A NON-SQUEEZEBOX PLAYER NEVER LETS GO OF ITS STREAMING SOCKET.
#
# Slim::Player::Client::closeStream is an EMPTY STUB, and the two places that
# would otherwise tidy up are both gated on the class:
# Slim::Player::Squeezebox has its own closeStream (which calls forgetClient),
# and sendStreamingResponse's stale-socket guard is written
# `$client->isa("Slim::Player::Squeezebox") && $httpClient != $client->streamingsocket`.
# We are deliberately neither, so BOTH pass us by.
#
# The result on tier 4: every re-load - a seek, a skip, the load at end of a
# held track - has HQPlayer open a SECOND connection while the first is still
# in LMS's write-select list pulling $client->nextChunk.  Two consumers draw
# from one chunk queue, each gets half the bytes, and what reaches HQPlayer is
# not a FLAC stream.  LIVE 2026-08-28: a seek mid-track played on for a moment
# and then stopped dead with an empty HQPlayer playlist, LMS still reporting
# `play` at a frozen position - no error anywhere, because nothing had failed.
#
# Same fix Squeezebox uses: drop the old socket and flush what was queued for
# it, so the new connection starts on a clean stream.
sub closeStream {
    my $self = shift;

    Slim::Web::HTTP::forgetClient($self);

    @{ $self->chunks } = ();

    return;
}

# An empty chunk is LMS's end-of-stream marker, and sendStreamingResponse acts
# on it by dropping the connection WITHOUT logging an error - so a stream that
# ends before it starts leaves no trace on either side.  It cost a long
# afternoon to find; say so when it happens.
#
# This is not a hot path in disguise: an empty chunk is by definition the last
# one of a stream, so this logs at most once per track.
sub nextChunk {
    my $self = shift;

    my $ref = $self->SUPER::nextChunk(@_);

    if ( defined $ref && !length($$ref) ) {
        main::INFOLOG && $log->is_info && $log->info( $self->name
            . ': end-of-stream marker read from the chunk queue - LMS will now drop the connection' );
    }

    return $ref;
}

# HQPlayer owns the real buffer, so we can never report a true fill level.
#
# TRAP: this is NOT a free-choice constant.  usage() is bufferFullness /
# bufferSize, and _CheckPaused stops the source stream outright when a paused
# remote track sits on a buffer over 98% full (LMS bug 10645 - the point is to
# release a remote connection LMS no longer needs).  HQPlayer keeps pulling
# from us the whole time it is paused, so for this player the answer to "is it
# safe to close the stream" is always no.  Report a buffer that is healthy but
# never full.
sub bufferSize     { 128 * 1024 }
sub bufferFullness { 96 * 1024 }
sub bytesReceived  { 0 }

# Sync with hardware players is out of scope - we do not own the clock.
sub playPoint     { undef }
sub startAt       { 1 }
sub resumeAt      { 1 }
sub skipAhead     { 1 }
sub pauseForInterval { 1 }

# flush() is NOT a stub any more - see the gapless section below.  It was one
# for as long as HQPlayer's playlist only ever held the track that was
# playing; now that a second one can be sitting behind it, LMS discarding the
# track it handed us early has to reach HQPlayer's playlist too.

# ---------------------------------------------------------------------------
# The control link, wired up by Plugin.pm
# ---------------------------------------------------------------------------

sub _send {
    my ( $self, $cmd, $cb ) = @_;

    my $ctl = $self->hqControl;

    if ( !$ctl ) {
        $log->warn( $self->name . ': no control link, dropping ' . $cmd );
        $cb->( undef, undef ) if $cb;
        return;
    }

    $ctl->send( $cmd, $cb );

    return;
}

# ---------------------------------------------------------------------------
# Track resolution - two URL tiers.  Never a filesystem path: HQPlayer's view
# of the library mount will not match LMS's, and reconciling the two would
# need exactly the per-install configuration this plugin exists to avoid.
# ---------------------------------------------------------------------------
sub _serverBase {
    my $self = shift;

    my $host = Slim::Utils::Network::serverAddr();
    my $port = $serverPrefs->get('httpport') || 9000;

    return "http://$host:$port";
}

sub _resolveURL {
    my ( $self, $song ) = @_;

    my $base = $self->_serverBase;

    my $track = eval { $song->currentTrack() };

    if ( $track && !Slim::Music::Info::isRemoteURL( $track->url ) ) {
        my $id = eval { $track->id };
        my $ct = eval { $track->content_type } || '';

        if ($id) {
            if ( $HQP_PLAYS{$ct} ) {
                my $ext = $EXT_FOR_TYPE{$ct} || $ct;

                # Tier 1 - original file bytes straight from LMS, tags and
                # embedded artwork intact, range-seekable, native DSD included.
                # The extension resolves back to the track's own type, so LMS
                # compares equal and streams it through without transcoding.
                $self->hqTier( 1 );

                my $url = $base . '/music/' . $id . '/download' . ( $ext ? ".$ext" : '' );

                main::INFOLOG && $log->is_info && $log->info(
                    $self->name . ": tier 1 (native passthrough) $url" );

                return $url;
            }

            # TIER 3 - a local file in a format HQPlayer cannot decode, asked
            # for AS FLAC so LMS transcodes it on the way out.
            #
            # IT CANNOT GO STRAIGHT TO /music/<id>/download.flac, AND THE
            # REASON IS HTTP, NOT AUDIO.  A transcode has no known length, so
            # LMS frames it `Transfer-Encoding: chunked` for an HTTP/1.1
            # client - and HQPLAYER DOES NOT DE-CHUNK.  It reads the chunk-size
            # lines as audio and its FLAC decoder tears itself apart on them:
            #
            #   ReadFLACErrorCB(): lost sync
            #   ReadFLACErrorCB(): unparseable stream
            #   ReadFLACErrorCB(): CRC error
            #
            # Reported as garbled mp4 playback 2026-08-28.  A native file gets
            # `Content-Length` and no chunking, which is why tier 1 was fine.
            #
            # THE FILE ITSELF IS PERFECT - that is what makes this so easy to
            # get wrong.  Downloaded with curl (which de-chunks silently) the
            # transcode is a valid FLAC: right rate, right duration, and a
            # 0.9998 loudness-envelope correlation against the original m4a.
            # Nothing about the audio is wrong; only the framing is.
            #
            # AND `state`, `process_speed` AND `input_fill` ALL LOOK HEALTHY
            # WHILE IT HAPPENS.  This tier was once called "verified" on the
            # strength of exactly those three numbers.  They do not tell you
            # the decoder is failing - only hqplayerd's own log does.
            #
            # 0.2.31 fixed the framing by routing this tier through the tier 4
            # player-stream endpoint, and that cost it gapless: there is one
            # player stream per player, so a pre-queued track would fight the
            # one playing.  It is served on its own route instead, which is
            # LMS's OWN download path with the request declared HTTP/1.0 so
            # that single `if` does not chunk it.  Correct audio AND a seamless
            # join - see the tier 3 section of Stream.pm.
            $self->hqTier( 3 );

            my $url = Plugins::HQPlayerBridge::Stream->downloadUrlFor( $base, $id, 'flac' );

            main::INFOLOG && $log->is_info && $log->info( $self->name
                . ": tier 3 ('$ct' is not in HQPlayer's mime table - LMS transcodes to FLAC,"
                . " served unchunked on the plugin's own download route) $url" );

            return $url;
        }
    }

    # TIER 5 - DIRECT. LMS has taken the direct-streaming branch for this song,
    # which means canDirectStream above returned the service's own final URL and
    # Song::open stored it on the song and opened NO socket. Hand that straight
    # to HQPlayer: no proxy hop, no transcode, and every track has a url of its
    # own, so it can be pre-queued for a real gapless hand-over.
    #
    # Read it off the SONG rather than asking the handler again - LMS may have
    # adjusted it (Song::open replaces streamUrl on a redirect retry), and the
    # song is what LMS believes it is streaming.
    if ( eval { $song->directstream } ) {

        my $url = eval { $song->streamUrl } || '';

        if ( $url =~ m{^https?://} ) {
            $self->hqTier( 5 );

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ": tier 5 (direct from the service) $url" );

            return $url;
        }

        # Should not happen - canDirectStream refused anything else - but a
        # direct song with no usable url has no socket to fall back to either,
        # so say so loudly rather than handing over an empty uri.
        $log->error( $self->name
            . ": direct streaming was accepted but the song has no usable url ('$url')" );
    }

    # TIER 4 - anything genuinely remote (Qobuz, Tidal, Deezer, radio), which
    # has no local file to serve, so the bytes have to come off LMS's own
    # player stream.
    #
    # THE OBVIOUS URL FOR THAT, /stream.mp3?player=<mac>, DOES NOT WORK, AND
    # THE REASON IS NOT WHAT IT LOOKS LIKE.  HQPlayer cannot fetch a URL
    # containing a QUERY STRING.  Isolated live 2026-08-28 against engine
    # 6.0.4:
    #
    #   /music/458773/download.flac                -> plays (state 2, proc 3.27)
    #   /music/458773/download.flac?x=1            -> silent, state 0
    #   /stream.mp3?player=02:ab:88:42:4c:69       -> silent, state 0
    #
    # `PlaylistAdd` answers result="OK" either way and then simply never
    # fetches it, which is why this looked like a transcoding or single-
    # consumer problem for so long.  It is the `?`.  A redirect does not rescue
    # it: HQPlayer issues a HEAD first and DOES NOT FOLLOW the 302 - verified
    # by pointing it at a local server that answered one; the HEAD arrived and
    # no GET ever came.
    #
    # So the plugin serves the same stream on a path of its own, and hands the
    # socket to the very machinery /stream.mp3 uses - see Stream.pm.  Every
    # track gets a url of its own, but this tier is still NOT pre-queued for
    # gapless: a client has one streamingsocket, and arming a hand-over would
    # move LMS on to the next song's source while HQPlayer is still pulling
    # this one.  _armNextTrack holds it instead.
    $self->hqTier( 4 );

    my $url = Plugins::HQPlayerBridge::Stream->urlFor( $self, $base, $song );

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ": tier 4 (plugin stream endpoint) $url" );

    return $url;
}

# WRITE EVERY ATTRIBUTE, THE WAY SIGNALYST'S OWN CLIENT DOES.
#
# `clControlInterface::playlistAdd` takes six parameters and writes ALL of them
# every time, defaults included:
#
#   playlistAdd(uri, queued=false, clear=false, metadata={}, startStream=false,
#               freeWheel=false)
#   -> <PlaylistAdd uri=".." queued="0" clear="0" start="0" freewheel="0">
#
# We were sending `uri` and `queued` (append) or `uri queued clear` (load) and
# leaving `start` and `freewheel` off entirely, so HQPlayer applied whatever its
# own defaults are. THIS REPO HAS BEEN BITTEN BY AN OMITTED ATTRIBUTE BEFORE -
# the `<Status/>` subscribe flag - so match the vendor and say what we mean.
#
# `start` is deliberately 0: the load sends a separate <Play/> afterwards, and
# the four-command ordering is what stopped the daemon crashing (see the
# mixed-channel note). Making the append start playback is a behaviour change,
# not an explicitness fix, so it is not made here.
#
# FREEWHEEL IS ON. It makes the reader fetch a track as fast as it can rather
# than at playback rate, and it is Signalyst's default on new installations -
# Simon's install predates that, so it is off on every surface here
# (`<upnp freewheel="0"/>`, no HQPLAYER_STREAM_FREEWHEEL, and we never sent the
# attribute). The point of it is riding out network trouble, which matters for
# tiers 4 and 5.
#
# It also has to be watched against the early-advance problem: fetch-fast is the
# condition tier 1 already runs under, and tier 1 is the tier that reports
# `End of track` 2-7s before the audio ends. If freewheel spreads that to the
# other tiers, this is where to look first.
use constant HQP_FREEWHEEL => 1;

sub _addAttrs {
    my ( $self, $url, $queued ) = @_;

    my $e = \&Plugins::HQPlayerBridge::Control::escape;

    return join ' ',
        'uri="'       . $e->($url) . '"',
        'queued="'    . ( $queued ? 1 : 0 ) . '"',
        # clear IS IGNORED by HQPlayer (it answers OK and appends anyway), which
        # is why the load sends an explicit <PlaylistClear/>. Written as 0 to
        # match the vendor rather than as a request we know is not honoured.
        'clear="0"',
        'start="0"',
        'freewheel="' . HQP_FREEWHEEL . '"';
}

# Build the <metadata/> child that rides along with PlaylistAdd.
#
# PlaylistAdd is written as an open/close pair rather than self-closing because
# it HAS a body, and that body is where metadata goes.  This was missed for a
# long time: probing the attributes of PlaylistAdd itself found nothing, so the
# load was routed over UPnP for months on the belief that DIDL was the only
# channel that could carry a cover.  It is not.
#
# THE ARTWORK FIELD IS `cover`, AND IT TAKES A PLAIN URL.  Verified against the
# live daemon (engine 6.0.4) on 2026-08-28 by writing an item both ways and
# reading it back with <PlaylistGet picture="1"/>.  The two are byte-identical:
#
#   <metadata cover="http://.../cover.jpg"/>   -> cover="http://.../cover.jpg"
#   SetAVTransportURI + <upnp:albumArtURI>     -> cover="http://.../cover.jpg"
#
#   both -> picture="aHR0cDovLzE5Mi4xNjguMS4yMzQ6OTAwMC9tdXNpYy81MTQ0NjFjZS9jb3Zlci5qcGc="
#
# HQPlayer base64-encodes the URL into `picture` ITSELF.  Handing it base64
# gets that base64 encoded a second time (68 chars in, 92 chars back), so pass
# the URL exactly as it is.
#
# These were all tested and DO NOT work - do not re-test them:
#
#   picture="<url>"  picture="<base64 url>"  albumArtURI="..."  art="..."
#   a <picture> child element inside <metadata>
#
# song/artist/album are merged with, not overridden by, HQPlayer's own tag
# decode: it fills in albumartist, date, bitrate and bits from the file while
# keeping the three fields set here.  The item also carries album_artist, date,
# genre, composer and performer if there is ever a reason to set them.
sub _metadata {
    my ( $self, $song ) = @_;

    my $track = eval { $song->currentTrack() } or return '<metadata/>';
    my $e = \&Plugins::HQPlayerBridge::Control::escape;

    # Deliberately the same four fields the DIDL carried, and no more: this is
    # the set that was proven equivalent end to end.
    # `length` IS ACCEPTED, IN SECONDS, AND IT IS WHY HQPLAYER'S UI SHOWED NO
    # DURATION.  HQPlayer does NOT probe an http:// item for its duration when
    # it accepts it - a bridge-added track came back from <PlaylistGet/> with
    # length="0" (and rate/bits/channels/bitrate all 0 too).  The old UPnP path
    # filled it in because DIDL carries <res duration="">; the XML path has to
    # be told.  Verified live 2026-08-28: length="12.7" reads back as
    # length="13" on the playlist item and length="12.699" on <Status/>.
    my $secs = eval { $track->secs };

    # A REMOTE TRACK CARRIES ALMOST NOTHING ON THE TRACK ROW ITSELF.
    #
    # `artistName` and `albumname` are populated for a library track, but for
    # Tidal/Qobuz/Deezer they come back EMPTY - that metadata lives with the
    # protocol handler, which is where LMS's own displays get it from. The
    # result was a Tidal track reaching HQPlayer as song + cover + length and
    # nothing else: no artist, no album, on the endpoint's screen.
    #
    # `_coverURL` already asked the handler, which is exactly why the artwork
    # was right while the text beside it was blank. Ask once, here, and let
    # both use it.
    #
    # THE HANDLER WINS, IT IS NOT A FALLBACK. On RADIO the track row DOES have
    # a title and it is the wrong one - it is the STATION. Reported live
    # 2026-08-28 on Radio Paradise:
    #
    #   track row      title = 'Main Mix - FLAC Interactive'   <- the station
    #   handler        title = 'Road to Joy'                   <- the track
    #
    # Artist and album looked fine there only because the row had neither and
    # fell through. Preferring the row is wrong for every remote track; it just
    # takes a stream whose row title is populated to show it. _handlerMeta
    # returns {} for a local track, so the library path is untouched.
    my $meta = $self->_handlerMeta($track);
    my $gain = $self->_replayGain( $song, $track );

    my @f = (
        song   => $meta->{title}  || eval { $track->title }      || '',
        artist => $meta->{artist} || eval { $track->artistName } || '',
        album  => $meta->{album}  || eval { $track->albumname }  || '',
        cover  => $self->_coverURL( $track, $meta ) || '',
        # Guarded rather than defaulted: a zero length is worse than none - it
        # is what the UI was already showing.
        ( $secs && $secs > 0 ? ( length => $secs ) : () ),
        ( defined $gain ? ( gain => sprintf( '%.2f', $gain ) ) : () ),
    );

    my $meta = '<metadata';

    while ( my ( $k, $v ) = splice( @f, 0, 2 ) ) {
        next if $v eq '';
        $meta .= ' ' . $k . '="' . $e->($v) . '"';
    }

    return $meta . '/>';
}

# The ReplayGain figure to hand HQPlayer, or undef to send nothing.
#
# STREAMING ONLY, AND DELIBERATELY GATED ON THE TRACK, NOT ON hqTier.  HQPlayer
# reads a local file's own REPLAYGAIN tags itself - verified live 2026-08-30,
# an album tagged REPLAYGAIN_ALBUM_GAIN=-6.31 dB produced `Adaptive transport
# gain: -6.31 dB (0.483615)` with nothing sent from here.  Sending ours as well
# would risk applying it twice.  A service CDN file carries no tags at all,
# which is why every streamed track logged `Adaptive transport gain: 0 dB (1)`.
#
# Gating on the track rather than the tier also keeps this independent of
# whether _resolveURL has run yet on a given path - _appendTrack and
# _queueTrack reach _metadata by different routes.
#
# WHY THE VALUE IS READ PER QUEUE EVENT AND NEVER CACHED AGAINST THE TRACK.
# LMS's "Smart Gain" is context-sensitive: Slim::Player::ReplayGain decides
# album vs track gain by comparing a song's PLAYLIST NEIGHBOURS, and a service
# handler's own trackGain does the same thing with its own metadata.  The same
# track legitimately gets one figure inside its album and another in a mixed
# playlist, so it has to be asked for again every time we queue.
#
# $song->replayGain is already populated for the track being STARTED -
# StreamingController computes it and stores it just before calling play().  A
# track being PRE-QUEUED has not reached that point, so ask for it directly;
# by arm time the playlist neighbours are known, which is all the album/track
# decision needs.
#
# Which of album or track gain comes back is NOT our decision and must not be
# reimplemented here: for a remote track fetchGainMode hands straight off to
# the service plugin's trackGain before any of LMS's own mode logic runs.
# Qobuz supplies both album and track figures, so its choice is a real one;
# a service that only publishes track gain simply yields a track figure.
sub _replayGain {
    my ( $self, $song, $track ) = @_;

    my $url = eval { $track->url } || '';

    return undef unless $url && Slim::Music::Info::isRemoteURL($url);

    my $gain = eval { $song->replayGain };

    $gain = eval { Slim::Player::ReplayGain->fetchGainMode( $self, $song ) }
        if !defined $gain;

    return undef unless defined $gain && $gain =~ /^\s*-?[0-9]*\.?[0-9]+\s*$/;

    # Unity is what HQPlayer already does; saying so adds nothing.
    return undef if abs($gain) < 0.005;

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ": replay gain $gain dB for $url" );

    return $gain;
}

# What the protocol handler knows about a remote track, normalised.
#
# This is the ONLY source for a streaming track's artist and album: the track
# row has neither. Returns {} for a local track, so callers can read it
# unconditionally and let the track's own accessors win.
#
# The value of a field is usually a plain string, but a handler is free to hand
# back an object or a hash for artist/album, so unwrap the obvious shapes
# rather than stringifying a reference into the metadata HQPlayer displays.
sub _handlerMeta {
    my ( $self, $track ) = @_;

    my $url = eval { $track->url } || '';

    return {} unless $url && Slim::Music::Info::isRemoteURL($url);

    my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

    return {} unless $handler && $handler->can('getMetadataFor');

    my $meta = eval { $handler->getMetadataFor( $self, $url ) } || {};

    return {} unless ref $meta eq 'HASH';

    my %out;

    for my $k (qw( title artist album )) {
        my $v = $meta->{$k};

        # radio puts the whole "Artist - Title" line here
        $v = $meta->{remote_title} if !defined $v && $k eq 'title';

        if ( ref $v eq 'HASH' )  { $v = $v->{name} }
        elsif ( ref $v )         { $v = eval { $v->name } }

        $out{$k} = $v if defined $v && !ref $v && $v ne '';
    }

    # the artwork keys, left exactly as _coverURL expects them
    $out{$_} = $meta->{$_} for grep { defined $meta->{$_} } qw( cover coverart icon artwork_url );

    return \%out;
}

sub _coverURL {
    my ( $self, $track, $meta ) = @_;

    my $url = eval { $track->url } || '';

    # Remote tracks (Qobuz, Tidal, radio...) have a NEGATIVE track id and no
    # coverid, so /music/<id>/cover.jpg cannot resolve them - it returns the
    # "no artwork" placeholder.  Their artwork comes from the protocol handler,
    # and it is usually already an /imageproxy/ path, which is exactly what the
    # image proxy is for.
    if ( $url && Slim::Music::Info::isRemoteURL($url) ) {

        # _metadata has usually asked already; only pay for it again if not.
        $meta ||= $self->_handlerMeta($track);

        my $art = $meta->{cover} || $meta->{coverart} || $meta->{icon} || $meta->{artwork_url};

        if ($art) {
            return $art if $art =~ m{^https?://};
            return $self->_serverBase . ( $art =~ m{^/} ? $art : "/$art" );
        }

        return undef;
    }

    # Local track: the direct route serves the real file.
    #
    # NOTE: do NOT wrap this in Slim::Web::ImageProxy::proxiedImage.  The image
    # proxy is for REMOTE artwork; handed a local LMS path it returns the
    # placeholder instead of the cover, which is the blank icon that showed up
    # on the endpoint.
    my $id = eval { $track->coverid } || eval { $track->id } or return undef;

    return $self->_serverBase . '/music/' . $id . '/cover.jpg';
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

# Everything that loads a track is asynchronous, so a transport command has to
# invalidate whatever the previous one left in flight.  Bumping the generation
# makes every outstanding callback recognise itself as superseded.
#
# cancelPlay is still called even though the load no longer runs over UPnP: the
# renderer keeps its own Play retry timer, and a describe that raced a teardown
# could still have one armed.  It is a counter bump, so it costs nothing.
sub _newGeneration {
    my $self = shift;

    # Anything handed over early belonged to the run that is ending.  Nothing
    # extra has to be sent to HQPlayer: the four-command load opens with
    # <PlaylistClear/>, which drops a pre-queued item along with everything
    # else that is not playing.
    $self->hqNext( undef );
    $self->hqArmNext( 0 );

    # HQPlayer numbers its playlist from 1 and starts again after a clear, so
    # the index we last saw means nothing across a load - and leaving it set
    # would make the first status of the new track look like an advance.
    $self->hqTrackNo( undef );

    # ...and a pending end-of-stream belongs to the run that is ending.
    $self->_cancelEndOfStream;

    my $gen = ( $self->hqGen || 0 ) + 1;
    $self->hqGen($gen);

    my $upnp = $self->hqUPnP;
    $upnp->cancelPlay if $upnp;

    return $gen;
}

# True when a callback belongs to a track that has since been superseded.
sub _superseded {
    my ( $self, $gen, $what ) = @_;

    return 0 if ( $self->hqGen || 0 ) == $gen;

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ": $what completed for a superseded track - dropping" );

    return 1;
}

# play() is called for TWO different things, and telling them apart is the
# whole of gapless.
#
#   1. Start playing THIS track, now.  Replaces whatever HQPlayer is doing:
#      the four-command load in _queueTrack.  Every play() was this before.
#
#   2. Here is the NEXT track, while the current one is still playing.  LMS
#      only ever sends this because we asked for it (_armNextTrack), so the
#      request is recognised by our own flag rather than guessed at from the
#      controller's state - a guess would misread the first play() after a
#      pause, a jump or a sync change.
#
# The second one must NOT touch the track that is playing.  A <Stop/> or a
# <PlaylistClear/> there kills it; the whole point is that HQPlayer makes the
# transition itself, out of its own playlist, with no gap.
sub play {
    my ( $self, $params ) = @_;

    my $controller = $params->{controller};
    my $song       = eval { $controller->song } or do {
        $log->error( $self->name . ': play() with no song' );
        return 0;
    };

    my $seek = $params->{seekdata} ? $params->{seekdata}->{timeOffset} : undef;

    # Consume the flag either way.  One left armed would make an ordinary
    # play() later on think it was a hand-over and never start anything.
    my $armed = $self->hqArmNext ? 1 : 0;
    $self->hqArmNext( 0 );

    return $self->_handOver( $song, $seek )
        if $armed && $self->_canHandOver($seek);

    return $self->_startTrack( $song, $seek );
}

# Case 1: replace whatever HQPlayer is playing with this track.
sub _startTrack {
    my ( $self, $song, $seek ) = @_;

    my $url = $self->_resolveURL($song);

    # A new track generation.  Loading a track is several async round trips
    # (Stop, PlaylistClear, PlaylistAdd, then Play), and a stop or a skip during
    # that window must not let the PREVIOUS track's completion callback land on
    # this one - it would re-assert bufferReady and apply the old track's seek.
    # Every callback below is stamped with the generation it started in.
    $self->_newGeneration;

    # What we have asked HQPlayer to play, and what it was playing before.  A
    # status push carries the uri on its <metadata/> child, which is how a
    # push describing the OLD track is recognised in _onStatus.
    $self->hqPrevURL( $self->hqURL );
    $self->hqURL( $url );

    $self->hqStarted( 0 );
    $self->hqPlayAck( 0 );

    # ARMED, not cleared.  Between here and HQPlayer confirming the new track,
    # any stop it reports is the one WE sent to end the previous track - and
    # reading that as end-of-track makes LMS advance past the track it has just
    # started.  _onStatus clears this only when the new track is confirmed
    # playing.
    $self->hqExpectStop( 1 );

    $self->hqPosition( 0 );
    $self->hqSeekOffset( 0 );
    $self->hqWanted( 'play' );

    # HQPlayer owns the buffer, so LMS can never learn about it from a STAT.
    # We assert it ourselves once HQPlayer has the URI and is playing - see
    # _queueTrack.  Until then it must read false, or a stale 1 from the
    # previous track would let the controller start before HQPlayer has the
    # new one.
    $self->bufferReady( 0 );

    $self->_queueTrack( $url, $song, $seek );

    # The controller counts the player as started from here; actual playback
    # is confirmed by the status poll below.
    return 1;
}

# ---------------------------------------------------------------------------
# Gapless: hand the next track to HQPlayer's own playlist
#
# HQPlayer is gapless between the items of its OWN playlist - it is the whole
# reason people run it - but this bridge fed it exactly one item at a time, so
# every track end was an end of playlist and the next track only started after
# LMS had noticed the stop and run a fresh four-command load.  That round trip
# is the gap.
#
# The fix is to be a two-deep player, which is what a real Squeezebox is: ask
# LMS for the next track while the current one plays, append it behind the
# playing item, and let HQPlayer make the transition.  Nothing about the LMS
# side is unusual - ReadyToStream while PLAYING is exactly the signal a
# Squeezebox's decoder sends when it can take another stream.
#
# TWO THINGS CHANGE ON THE STATUS SIDE, and both are handled in _onStatus:
#
#   * There is NO state 0 between tracks any more, because HQPlayer never
#     stops.  The hand-over is observed instead as the playlist index on
#     <Status/> moving on - `track="1"` to `track="2"`.
#   * state 0 now means end of PLAYLIST rather than end of track, which is
#     what the existing end-of-stream path always wanted it to mean.
# ---------------------------------------------------------------------------

# Is a hand-over possible at this instant?
sub _canHandOver {
    my ( $self, $seek ) = @_;

    # Only while a track is genuinely running under our own control.  hqStarted
    # alone is not enough: hqPlayAck says the Play that is running is the one
    # WE sent for the track we think is playing.
    return 0 unless $self->hqStarted && $self->hqPlayAck;
    return 0 unless ( $self->hqWanted || '' ) eq 'play';
    return 0 unless $self->hqControl;

    # A hand-over has nowhere to put a seek - <Seek> acts on what is playing
    # now, not on a queued item.  The full load does have somewhere, so let it
    # take this one.
    return 0 if $seek && $seek > 0;

    return 1;
}

# Case 2: LMS has handed us the next track early.
sub _handOver {
    my ( $self, $song, $seek ) = @_;

    # _resolveURL sets hqTier as a side effect, so remember the playing
    # track's tier: the answer below may not be for the same tier at all, and
    # until the hand-over actually happens hqTier still describes what is
    # playing.
    my $tier = $self->hqTier;
    my $url  = $self->_resolveURL($song);

    my $newTier = $self->hqTier || 0;

    return $self->_appendTrack( $url, $song )
        if $newTier == 1 || $newTier == 3 || $newTier == 5;

    # TIER 4 CANNOT RIDE HQPLAYER'S PLAYLIST, even though its urls ARE unique.
    # A client has ONE streamingsocket and one songStreamController.  Appending
    # would have LMS resolve and OPEN the next song's source now, replacing the
    # controller that is currently feeding bytes down the socket HQPlayer is
    # still pulling - so the rest of the playing track would arrive as the
    # beginning of the next one.  A real Squeezebox survives this because it
    # buffers a whole track ahead of itself; HQPlayer pulls progressively.
    #
    # So hold the track and load it the ordinary way when the current one ends.
    # That is exactly the pre-gapless behaviour, minus the time LMS used to
    # spend resolving the track after the gap had already started.
    $self->hqTier($tier);

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': the next track is tier 4 - holding it for a normal load at end of track' );

    $self->hqNext( { mode => 'load', song => $song, seek => $seek } );

    return 1;
}

# Append behind the playing item.  NO <Stop/> and NO <PlaylistClear/>: those
# are what the four-command load uses to REPLACE a track, and either one here
# would kill the track that is playing.
sub _appendTrack {
    my ( $self, $url, $song ) = @_;

    my $e    = \&Plugins::HQPlayerBridge::Control::escape;
    my $meta = $self->_metadata($song);

    # Deliberately NOT a new generation.  hqGen belongs to the track that is
    # playing and its callbacks must keep running; bumping it here would make
    # the running track supersede itself.
    my $gen = $self->hqGen || 0;

    $self->hqNext( { mode => 'queue', url => $url, song => $song, acked => 0 } );

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ": pre-queuing the next track for a gapless hand-over - $url" );

    # queued="0", NOT queued="1".  THIS ATTRIBUTE CRASHES HQPLAYERD.
    #
    # Isolated live 2026-08-28 on engine 6.0.4, four controlled runs:
    #
    #   both items added before Play, queued="0"   -> plays through, SURVIVES
    #   append mid-playback, queued="0"            -> plays through, SURVIVES
    #   append mid-playback, queued="1"            -> end of playlist, DAEMON EXITS
    #   ...and again, with the playlist trimmed
    #      back to one item before the end         -> DAEMON EXITS anyway
    #
    # `queued="1"` puts the item somewhere that leaves HQPlayer's own track
    # index inconsistent, and at the end of the LAST item the engine walks past
    # it - `clPlaylist::GetAlbumGain(): trackn > last`, unhandled out of
    # clPlayerDaemon::Main(), process gone.  Trimming the playlist first does
    # not undo it, so the damage is done at append time, not at the end.
    #
    # queued="0" appends just the same - CLAUDE.md's note that PlaylistAdd
    # APPENDS regardless of its attributes is exactly why this works - and the
    # gapless advance is identical: tracks_total goes 1 -> 2, track goes 1 -> 2
    # with no state 0 between the tracks.  We get the whole feature and the
    # daemon lives.
    $self->_send(
        '<PlaylistAdd ' . $self->_addAttrs( $url, 0 ) . '>' . $meta . '</PlaylistAdd>',
        sub {
            # TRAP: ($attrs, $raw), not ($res, $err) - see _queueTrack.
            my ( $res, $raw ) = @_;

            return if $self->_superseded( $gen, 'PlaylistAdd (hand-over)' );

            my $next = $self->hqNext;
            return unless $next && ( $next->{url} || '' ) eq $url;

            if ( !$res ) {
                # DO NOT report this as a failed load.  StreamingFailed here
                # leads to _SyncStopNext -> _getNextTrack -> play(), and that
                # play() is not a hand-over - it is a full load, which would
                # stop the track that is still playing perfectly well.  A
                # refused pre-queue is not a reason to interrupt anything.
                #
                # Demote it to a held track instead: the ordinary load runs at
                # end of track, in the state the error handling was written
                # for, and reports the failure properly then if it is real.
                $log->warn( $self->name . ': HQPlayer would not pre-queue the next track ('
                    . ( defined $raw ? $raw : 'no reply' )
                    . ') - falling back to a normal load at end of track' );

                $next->{mode} = 'load';
                delete $next->{url};

                return;
            }

            $next->{acked} = 1;

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': the next track is queued behind the playing one' );
        } );

    return 1;
}

# Ask LMS for the next track.  Called when a track has just been confirmed
# playing - at the start of a run, and again after each hand-over.
sub _armNextTrack {
    my $self = shift;

    # One hand-over at a time.  _NextIfMore makes the same check on its side
    # (it will not fetch a third song while two are queued), but the flag has
    # to be right here too or a second arm would consume the first's play().
    return if $self->hqNext || $self->hqArmNext;

    return unless $self->hqControl;

    # TIERS 1, 3 AND 5 can be pre-queued.  All three leave LMS out of the byte
    # path - tier 1 the original bytes, tier 3 an LMS transcode on the plugin's
    # own download route, tier 5 the service's own CDN url - so a second url
    # can be handed over while the first is still being read.
    #
    # Tier 4 is not: it IS the byte path.  A client has one streamingsocket and
    # one songStreamController, so arming there would move LMS on to the next
    # song's source while HQPlayer is still pulling this one - see _handOver.
    # Arming would still be SAFE (the track is simply held) but it would open
    # that source minutes early for no gain.
    my $tier = $self->hqTier || 0;
    return unless $tier == 1 || $tier == 3 || $tier == 5;

    my $c = $self->controller or return;

    # ReadyToStream in PLAYING/STREAMING is _NextIfMore: LMS resolves the next
    # playlist entry and calls play() again with it, leaving the track that is
    # playing alone.  At the end of the playlist it does nothing at all, which
    # is why nothing here has to know how long the playlist is - hqArmNext is
    # just consumed by whatever the next play() turns out to be.
    #
    # Set the flag BEFORE the call: for a local track LMS resolves the next
    # song synchronously and play() is re-entered before this returns.
    $self->hqArmNext( 1 );

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': asking LMS for the next track' . _ctlState($c) );

    $c->playerReadyToStream($self);

    return;
}

# LMS is discarding the track it handed us early: the playlist was edited, or
# the user jumped.  _FlushGetNext drops it from the song queue, calls this, and
# then asks for a replacement - which arrives as an ordinary play() with
# hqArmNext clear, so it takes the full load path and starts cleanly.
#
# <PlaylistClear/> is exactly the right command here: verified live, it keeps
# the item that is PLAYING and drops the rest.  If the append is still in
# flight the clear queues behind it on the same socket, so it cannot overtake
# the item it is meant to remove.
sub flush {
    my $self = shift;

    my $next = $self->hqNext;

    $self->hqNext( undef );

    # RE-ARM, DO NOT CLEAR.  _FlushGetNext drops the streaming song, calls
    # this, and then immediately asks for a REPLACEMENT - so the very next
    # play() is another hand-over, not a play-now.
    #
    # Clearing the flag here made that play() run the full four-command load
    # over the top of a track that was still playing: observed live, deleting
    # the pre-queued track six seconds into a twelve-second one cut it off and
    # jumped forward.  Editing the queue is not supposed to touch what is
    # playing.
    #
    # Safe if no replacement arrives (the end of the playlist): _canHandOver
    # still requires a track to be playing and acknowledged, and stop() clears
    # the flag through _newGeneration.
    $self->hqArmNext( 1 );

    return 1 unless $next && $next->{mode} eq 'queue';

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': flush - dropping the pre-queued track' );

    $self->_send('<PlaylistClear/>');

    return 1;
}

# The whole load runs on the XML control socket.  Nothing here touches UPnP.
#
# THE ORDER IS THE POINT.  Four commands, one socket, each queued behind the
# last: Stop, PlaylistClear, PlaylistAdd, Play.  The load used to be split
# across two channels - <Stop/> on the control socket while
# SetAVTransportURI/Play went over UPnP - and they could not be ordered against
# each other.  A control command answers in ~9-150ms and a UPnP round trip in
# 300-550ms, so a Stop meant for the OLD track could land after the Play for
# the new one and kill it, and HQPlayer's AVTransport never saw a Stop at all:
# from the renderer's side the transport went straight from PLAYING into
# SetAVTransportURI while the XML Stop emptied the engine's playlist underneath
# it.  That is the shape of `clPlaylist::GetAlbumGain(): trackn > last`, the
# fatal that took hqplayerd down whenever an album was loaded over a playing
# one.  On one socket the reordering is not possible.
#
# Verified against the live daemon (engine 6.0.4) on 2026-08-28: this exact
# sequence run five times in rapid succession over a playing track swapped
# cleanly every time, with the right metadata, and the daemon survived.
#
# TRAP: `clear="1"` ON PlaylistAdd IS IGNORED.  It is in the documented
# attribute set and PlaylistAdd answers result="OK", but the item is APPENDED -
# a swap over a playing track left a two-item playlist with the engine still on
# item 1.  The explicit <PlaylistClear/> is what actually empties it, and it is
# safe during playback: HQPlayer keeps the currently playing item and drops the
# rest.  The attribute is still sent, because it is the documented spelling and
# costs nothing if a later engine starts honouring it.
#
# TRAP: <Stop/> IS REQUIRED FIRST.  PlaylistClear leaves the current track
# playing, so a following Play is a no-op on an already-playing engine and the
# new track never starts.
sub _queueTrack {
    my ( $self, $url, $song, $seek ) = @_;

    if ( !$self->hqControl ) {
        $log->error( $self->name . ': no control link - cannot start playback' );
        my $c = $self->controller;
        $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
        return;
    }

    my $e    = \&Plugins::HQPlayerBridge::Control::escape;
    my $meta = $self->_metadata($song);

    # The generation this load belongs to - see _newGeneration.
    my $gen = $self->hqGen || 0;

    # Clear the decks.  Both are fire-and-forget: they carry no information
    # back, and holding the chain up for their replies would only widen the
    # window in which a skip can arrive.  Ordering is guaranteed by the socket,
    # not by the callbacks.
    $self->_send('<Stop/>');
    $self->_send('<PlaylistClear/>');

    $self->_send(
        '<PlaylistAdd ' . $self->_addAttrs( $url, 0 ) . '>'
      . $meta
      . '</PlaylistAdd>',
        sub {
            # TRAP: Control::send's callback is ($attrs, $raw) - the SECOND
            # argument is the raw reply on success AND on failure, never an
            # error string.  Failure is the FIRST argument being undef.  Read
            # it the SimpleAsyncHTTP way, as ($res, $err), and every successful
            # PlaylistAdd is reported as a failure: 0.2.13 shipped with exactly
            # that and LMS raced the whole playlist, one PROBLEM_OPENING per
            # track, playing nothing.
            my ( $res, $raw ) = @_;

            return if $self->_superseded( $gen, 'PlaylistAdd' );

            if ( !$res ) {
                $log->error( $self->name . ': HQPlayer would not accept the track URI: '
                    . ( defined $raw ? $raw : 'no reply' ) );
                my $c = $self->controller;
                $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
                return;
            }

        $self->_send( '<Play/>', sub {
            # ($attrs, $raw) again - see the note on PlaylistAdd above.
            my ( $r2, $raw2 ) = @_;

            # A stop or a skip during the load window supersedes this track.
            # Without this the old track's completion still re-asserts
            # bufferReady, restarts polling and applies ITS seek offset to
            # whatever is playing now.
            return if $self->_superseded( $gen, 'Play' );

            if ( !$r2 ) {
                $log->error( $self->name . ': HQPlayer would not start the track: '
                    . ( defined $raw2 ? $raw2 : 'no reply' ) );
                my $c = $self->controller;
                $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
                return;
            }

            # Seek, but ONLY on tier 1.
            #
            # The tiers put the offset in three different places.  Tier 1 hands
            # HQPlayer a plain file URL, so LMS is not in the byte path at all
            # and HQPlayer has to do the seeking itself.  Tier 4 goes through
            # the plugin's own stream endpoint, and since we canDirectStream(0)
            # it is LMS that opens the source - so those bytes ALREADY start at
            # the offset, and seeking again would land at 2x it.  Tier 3 cannot
            # seek at all: a transcode has no known length, so LMS answers
            # Accept-Ranges: none and there is no offset to apply.
            #
            # Remember what we told HQPlayer to skip, because it reports an
            # absolute position and playingSongElapsed adds startOffset on top
            # - see songElapsedSeconds.
            # Tier 5 is in the same position as tier 1: LMS is not in the byte
            # path, so HQPlayer has to do the seeking itself.  Whether the
            # service's CDN honours a range request is UNTESTED - if it does
            # not, HQPlayer logs `clStreamReaderHTTP::Skip(): not seekable!`
            # and starts from zero, which is at least visible.
            my $seekTier = $self->hqTier || 0;

            if ( $seek && $seek > 0 && ( $seekTier == 1 || $seekTier == 5 ) ) {
                $self->_send( '<Seek position="' . int($seek) . '"/>' );
                $self->hqSeekOffset( int($seek) );
            }

            # HQPlayer has accepted Play for THIS track, so any PLAYING it
            # reports from here on is the new track rather than a push left
            # over from the previous one.  _onStatus will not latch a start
            # until this is set.
            $self->hqPlayAck( 1 );

            # TRAP: playerBufferReady alone is not enough.  It routes to
            # _WaitToSync -> _StartIfReady, which polls *every* player's
            # isBufferReady() - i.e. the client's own bufferReady flag, which
            # only Squeezebox's STAT handler ever sets.  Leave it at 0 and the
            # controller parks in WAITING_TO_SYNC forever, where Pause maps to
            # _NoOp and Started maps to _Invalid.  Set the flag first.
            $self->bufferReady( 1 );

            my $c = $self->controller;

            # ...but only report it while the controller still needs the
            # answer.  BufferReady in the PLAYING row of the state table is
            # _Invalid - a warning and a backtrace - and the controller is
            # already PLAYING when this load is the deferred hand-over of a
            # tier 4 track (see _handOver): the buffer question was settled by
            # the track that has just finished.
            $c->playerBufferReady($self) if $c && !$c->isPlaying(1);

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': buffer ready' . _ctlState( $self->controller ) );

            $self->_startPolling;
        } );
    } );

    return;
}

# hqWanted is the last transport state we asked HQPlayer for.  It is what makes
# the link two-way without a feedback loop: _onStatus compares HQPlayer's actual
# state against this, NOT against the controller's, so a change we caused reads
# as agreement and a change somebody else caused reads as a divergence to
# follow.  Keying off the controller instead would race - _Pause sets PAUSED
# about 300ms before it calls pause() on us (it fades the volume first), and a
# status push landing in that window would look like an external resume.
sub pause {
    my $self = shift;

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': pause' . _ctlState( $self->controller ) );

    # Already paused because HQPlayer is where the pause came from: sending
    # again would be at best redundant and at worst a toggle back to playing.
    $self->_send('<Pause/>') unless ( $self->hqWanted || '' ) eq 'pause';
    $self->hqWanted('pause');

    return 1;
}

sub resume {
    my $self = shift;

    $self->_send('<Play/>') unless ( $self->hqWanted || '' ) eq 'play';
    $self->hqWanted('play');

    return 1;
}

sub stop {
    my $self = shift;

    # Anything still loading belongs to a track we are no longer playing.
    $self->_newGeneration;

    # Mark this as our own stop so the poll does not read it as end-of-track
    # and advance the playlist underneath us.
    $self->hqExpectStop( 1 );
    $self->hqStarted( 0 );
    $self->hqPlayAck( 0 );
    $self->bufferReady( 0 );
    $self->hqWanted('stop');

    $self->_send('<Stop/>');
    $self->_stopPolling;

    return 1;
}

# Volume is shared, not owned.  HQPlayer holds the real level in dB and splits
# it between the endpoint's hardware attenuator and its own software gain; LMS
# holds an 0-100 slider.  We keep the two in step:
#
#   LMS -> HQPlayer   here, over the XML channel
#   HQPlayer -> LMS   in _onStatus, from the volume="" every <Status/> carries
#
# hqVolDb is where HQPlayer ACTUALLY is - the last level it reported, not the
# last one we sent - and it stops those two directions chasing each other:
# neither side moves the other over a difference smaller than one LMS step is
# worth.  See _volTol, which is the whole answer to the snapping.
#
# The XML channel, not UPnP.  Measured on the live daemon: a command on the
# open control socket answers in ~9ms, while HQPlayer's UPnP RenderingControl
# takes 300-550ms - which was the volume lag.  The command is plain
# <Volume value="-53"/>; SetVolume/SetVolumeDB/GetVolume do not exist.
#
# THE RANGE IS THE USER'S, NOT HQPLAYER'S.  HQPlayer's output range is a
# setting: it defaults to -60...0, this development instance is -100...0, and
# BOTH ends move - a user may cap the top at -20 as well as lift the floor.  So
# nothing here is a constant; the range is read from the renderer at connect
# (refreshVolumeRange), and these two are only the fallback until it answers.
use constant HQP_VOL_MIN_DB => -100;
use constant HQP_VOL_MAX_DB => 0;

sub _volMin  { my $v = $_[0]->hqVolMin; defined $v ? $v : HQP_VOL_MIN_DB }
sub _volMax  { my $v = $_[0]->hqVolMax; defined $v ? $v : HQP_VOL_MAX_DB }
sub _volSpan { my $s = $_[0]->_volMax - $_[0]->_volMin; $s > 0 ? $s : 0 }

# One LMS slider step, in dB.  This is the resolution the LMS side physically
# has: 101 positions across the range, whatever the range is.
sub _volStep { $_[0]->_volSpan / 100 }

# THE RULE THAT STOPS THE SLIDER SNAPPING.  Never move HQPlayer, and never move
# the slider, over a difference smaller than one LMS step is worth.
#
# LMS re-asserts its STORED volume at the start of every track that begins from
# stopped (Slim::Player::StreamingController, "Bug 10310"), and that is the
# whole mechanism behind "LMS changes the volume on the next track to align
# it".  A level set on the endpoint's own remote will not land on LMS's
# 101-step grid, so LMS rounds it to the nearest step - and without this
# tolerance the next track start drags the endpoint back onto that rounded
# value.  Both directions use the SAME tolerance, or they fight: whatever one
# side declines to follow, the other must decline to correct.
sub _volTol { $_[0]->_volStep / 2 }

# VERIFIED against hqplayerd 6.0.4: HQPlayer takes and reports FRACTIONAL dB.
# <Volume value="-39.25"/> comes back from <Status/> as volume="-39.25", and
# from UPnP GetVolumeDB as -10048 (= -39.25 x 256) exactly.  So the device is
# not the limit on resolution: every one of the 101 slider positions can have a
# level of its own, on any range.
#
# But it round-trips through a 32-bit float - -38.6 comes back as
# -38.599998474121094.  So quantise to a binary fraction of a dB, which
# survives both that and HQPlayer's own 1/256 dB units exactly.  The quantum is
# at most HALF an LMS step, which is what guarantees two consecutive steps can
# never land on the same level: no dead increments, on any range.
sub _volQuantum {
    my $step = $_[0]->_volStep;

    return 1 / 256 if $step <= 0;

    my $q = 1;
    $q /= 2 while $q > $step / 2 && $q > 1 / 256;

    return $q;
}

# Perl's int() truncates towards zero, so a bare int($v + 0.5) rounds negative
# values the wrong way - and every dB figure here is negative.
sub _round { my $v = shift; return $v < 0 ? -int( -$v + 0.5 ) : int( $v + 0.5 ) }

sub _quantise {
    my ( $self, $db ) = @_;

    my $q = $self->_volQuantum;

    return _round( $db / $q ) * $q;
}

# Linear in dB across the range, which IS a logarithmic taper on the signal -
# equal dB per step, the way a good analogue pot behaves.  It is also
# HQPlayer's OWN convention: its UPnP RenderingControl reported CurrentVolume
# 61 at -39 dB on this -100...0 instance, i.e. 100 x (1 - 39/100).  Matching it
# means the LMS slider and HQPlayer's own 0-100 scale read the same number, so
# LMS and the endpoint's display never disagree.
#
# A bent taper (a knee, or the sqrt curve denonavpcontrol uses) was considered
# and rejected: it makes a fixed skin increment - Material's volume step is 1,
# 3 or 5, and other skins differ - worth a different number of dB depending on
# where the slider happens to be, and it only pays off for a listener with one
# habitual level.
sub _lmsToDb {
    my ( $self, $v ) = @_;

    $v = 0 unless defined $v;
    $v = 0   if $v < 0;          # mute arrives as a persisted volume(0)
    $v = 100 if $v > 100;

    return $self->_quantise( $self->_volMax - $self->_volSpan * ( 100 - $v ) / 100 );
}

sub _dbToLms {
    my ( $self, $db ) = @_;

    my $span = $self->_volSpan or return 100;

    my $v = _round( 100 * ( $db - $self->_volMin ) / $span );

    $v = 0   if $v < 0;
    $v = 100 if $v > 100;

    return $v;
}

# HQPlayer parses the value as a float, so send the shortest exact text for it:
# "-53" stays "-53", and a quantised fraction keeps only its own digits.
sub _fmtDb {
    my $s = sprintf( '%.8f', shift );

    $s =~ s/0+$//;
    $s =~ s/\.$//;
    $s = '0' if $s eq '-0';

    return $s;
}

# LMS ramps the volume down and back up around every pause and resume, and
# fires the actual pause from the ramp's completion callback ~300ms later.
# Since those steps are temporary volumes we never forward (see volume()), the
# ramp is silent here - all it does is delay the pause by 300ms.  Skip it and
# call the callback straight away.
#
# TRAP: the DURATION still matters.  fade_volume is not only the pause ramp -
# the sleep timer calls it with the full fade-out time (fadeInSecs, up to a
# minute) and STOPS the player from the same completion callback.  Firing that
# immediately ends playback a whole fade early, which reads as the sleep timer
# firing at the wrong time.  So: run short ramps immediately, and give a long
# fade its time back before calling the caller.
#
# The audio does not actually fade.  A real ramp would have to move HQPlayer's
# own level, which is SHARED with LMS (see volume()) - the mirror in _onStatus
# would follow every step straight back into the slider, and a fade interrupted
# by a restart would leave the endpoint turned down for good.  Playing to the
# end of the fade at the set level and then stopping is the honest behaviour
# here; the timing, which is what the user set, is exact.
use constant FADE_IMMEDIATE => 1;   # seconds; at or under this, do not wait

sub fade_volume {
    my ( $self, $fade, $cb, $cbargs ) = @_;

    # _Resume parks a temporary volume of 0 before the fade-in, and
    # Client::volume reports a temporary level in preference to the real one -
    # so leaving it set would show the slider at zero after every resume.
    $self->_tempVolume(undef);

    # A fade already running is superseded by this one - a cancelled sleep
    # timer must not still stop the player when its fade would have ended.
    Slim::Utils::Timers::killTimers( $self, \&_fadeDone );

    return unless $cb;

    my $secs = abs( $fade || 0 );

    return $cb->( @{ $cbargs || [] } ) if $secs <= FADE_IMMEDIATE;

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . sprintf( ': %.0fs fade - deferring its completion', $secs ) );

    Slim::Utils::Timers::setTimer(
        $self, Time::HiRes::time() + $secs, \&_fadeDone, $cb, $cbargs );

    return;
}

sub _fadeDone {
    my ( $self, $cb, $cbargs ) = @_;

    $cb->( @{ $cbargs || [] } ) if $cb;

    return;
}

sub volume {
    my ( $self, $newvolume, $temp ) = @_;

    my $vol = $self->SUPER::volume( $newvolume, $temp );

    return $vol unless defined $newvolume;

    # TRAP: the second argument is $temp, not "force".  LMS fades the volume
    # around every pause and resume, and every step of that ramp comes through
    # here with $temp set - a temporary level that is never persisted.  Those
    # are LMS's own business: sending them on would flood HQPlayer, dip the
    # endpoint's volume on each pause, and race to land out of order.  Only a
    # real, persisted change is ours to forward.  (Mute goes through the
    # persisted path, so it still reaches HQPlayer.)
    return $vol if $temp;

    # HQPlayer is not attenuating - either it told us so, or the user set this
    # player to fixed volume in LMS's own audio settings.  Either way the level
    # is somebody else's to move.  See _setFixed.
    return $vol if $self->_volumeIsFixed;

    my $db = $self->_lmsToDb($newvolume);
    my $at = $self->hqVolDb;

    # The track-start re-assert lands here, with LMS's stored volume.  If
    # HQPlayer is already within one slider step of it - which is exactly the
    # case after the user has turned the endpoint's own knob to a level off
    # LMS's grid - then leave it alone.  This is the anti-snap rule.
    return $vol if defined $at && abs( $db - $at ) <= $self->_volTol;

    $self->hqVolDb($db);
    $self->hqVolSent($db);
    $self->hqVolSentAt( Time::HiRes::time() );

    $self->_send( '<Volume value="' . _fmtDb($db) . '"/>' );

    return $vol;
}

# ---------------------------------------------------------------------------
# Fixed volume.
#
# Plenty of HQPlayer setups do not attenuate at all - the DAC or the amplifier
# holds the volume - and for those the LMS slider must sit at 100 and stay
# there rather than pretend to control something.
#
# LMS already has this concept, and it is worth using rather than inventing:
# the per-player digitalVolumeControl pref, which the status query turns into
#
#     use_volume_control = (digitalVolumeControl || !hasDigitalOut) ? 1 : 0
#
# (Slim::Control::Queries).  Material and the other skins disable the slider on
# that.  LMS only allows the pref to go to 0 on a player whose hasDigitalOut is
# true, which this one is - and the same gate puts LMS's own "Volume Control:
# fixed / variable" radio on the player's Audio settings page, so the user gets
# a manual override for free.
#
# Which is why a manual 0 counts as fixed too, and is never written back to 1:
# only a 0 that WE set is ours to clear.
# ---------------------------------------------------------------------------
sub _volumeIsFixed {
    my $self = shift;

    return 1 if $self->hqVolFixed;

    my $dvc = $serverPrefs->client($self)->get('digitalVolumeControl');

    return ( defined $dvc && !$dvc ) ? 1 : 0;
}

sub _setFixed {
    my ( $self, $fixed ) = @_;

    $fixed = $fixed ? 1 : 0;

    return if ( $self->hqVolFixed || 0 ) == $fixed;

    $self->hqVolFixed($fixed);
    $self->hqVolMissed(0);

    $log->info( $self->name . ': HQPlayer volume is '
        . ( $fixed ? 'FIXED - locking the LMS slider' : 'variable again - unlocking the LMS slider' ) );

    if ($fixed) {
        # Only a 0 that WE set is ours to clear again - a user who has already
        # chosen fixed volume keeps that choice when HQPlayer changes its mind.
        my $dvc = $serverPrefs->client($self)->get('digitalVolumeControl');

        if ( !defined $dvc || $dvc ) {
            $self->hqVolForced(1);
            $serverPrefs->client($self)->set( 'digitalVolumeControl', 0 );
        }

        # Park the slider at the top: there is no attenuation to represent.
        $self->execute( [ 'mixer', 'volume', 100 ] );
    }
    elsif ( $self->hqVolForced ) {
        $self->hqVolForced(0);
        $serverPrefs->client($self)->set( 'digitalVolumeControl', 1 );
    }

    return;
}

# ---------------------------------------------------------------------------
# Learning the range.
#
# VERIFIED live: HQPlayer DOES implement UPnP GetVolumeDBRange, even though the
# XML control API answers "Unknown command" for it - the -100...0 instance
# returns MinValue -25600, MaxValue 0.  Those are the AV spec's 1/256 dB units,
# so divide; whole dB is accepted too, in case another build reports it that
# way.  One SOAP call per connect, well off the hot path, so its 300-550ms
# costs nothing.
# ---------------------------------------------------------------------------
sub refreshVolumeRange {
    my $self = shift;

    my $upnp = $self->hqUPnP or return;

    if ( !$upnp->ready ) {
        # Not described yet: describe now and probe from the callback rather
        # than leaving the range at its fallback for the session.
        $upnp->describe( sub { $self->refreshVolumeRange if $_[0] } );
        return;
    }

    $upnp->getVolumeDBRange( sub {
        my ( $min, $max ) = @_;

        return unless defined $min && defined $max;

        # A range with no width is HQPlayer saying it will not attenuate.
        if ( $max - $min <= 0 ) {
            $self->_setFixed(1);
            return;
        }

        $self->_setFixed(0);
        $self->_setRange( $min, $max );

        return;
    } );

    return;
}

sub _setRange {
    my ( $self, $min, $max ) = @_;

    return if defined $self->hqVolMin
           && defined $self->hqVolMax
           && $self->hqVolMin == $min
           && $self->hqVolMax == $max;

    $log->info( $self->name . ": HQPlayer volume range is ${min}dB to ${max}dB ("
        . sprintf( '%.2f', ( $max - $min ) / 100 ) . 'dB per LMS step)' );

    $self->hqVolMin($min);
    $self->hqVolMax($max);

    # The slider's meaning just changed under it.  Re-derive its position from
    # where HQPlayer actually is, or it would show the old range's number and
    # the next track start would act on it.
    my $at = $self->hqVolDb;

    $self->execute( [ 'mixer', 'volume', $self->_dbToLms($at) ] ) if defined $at;

    return;
}

# How long after our own send a status push is still read as an answer to it.
# The stream runs at ~1/s, so a couple of seconds covers the crossing case.
use constant CLAMP_WINDOW  => 3;
use constant MISS_DELAY    => 2;
use constant FIXED_STRIKES => 3;

# ---------------------------------------------------------------------------
# The inbound half of the sync: HQPlayer's own level, off every <Status/>.
# ---------------------------------------------------------------------------
sub _followVolume {
    my ( $self, $db ) = @_;

    my $was = $self->hqVolDb;

    # hqVolDb is where HQPlayer IS, so record it before anything else decides
    # what to do about it - including the mixer command at the end, which lands
    # back in our own volume() and must find the level already current.
    $self->hqVolDb($db);

    $self->_learnFromClamp( $db );
    $self->_watchForFixed( $was, $db );

    return if $self->_volumeIsFixed;

    # Compare against what the SLIDER means, not against the last value we
    # sent.  A level set on the endpoint's own remote will not land on LMS's
    # 101-step grid, and anything within half a step is the same slider
    # position as far as LMS can express it - so following it would only round
    # the user's own setting for them.  The outbound guard declines to correct
    # the same difference, which is what keeps the two from disagreeing.
    #
    # Read the PERSISTED volume rather than $self->volume: _Resume parks a
    # temporary 0 before its fade-in, and a push landing in that window would
    # otherwise read as "the endpoint just dropped to the floor".  A muted
    # player stores its level negated, and mutes to the floor.
    my $stored = $serverPrefs->client($self)->get('volume') || 0;
    my $ours   = $self->_lmsToDb( $stored > 0 ? $stored : 0 );

    return if abs( $db - $ours ) <= $self->_volTol;

    # FOLLOW IT, WHATEVER IT IS.  An earlier build refused an INCREASE in the
    # seconds after a link-up, because a re-registering endpoint announces its
    # own stored level and once jumped the output +21dB unasked.
    #
    # It was removed 2026-08-30 at Simon's call: the trigger it used
    # (`transport_serial`) turns over at EVERY TRACK BOUNDARY, not just on a
    # re-registration, so the guard was armed for ten seconds after every
    # track change and pulled back the user's OWN volume changes.  A control
    # that second-guesses the person holding the remote is worse than the
    # noise it was protecting against.
    #
    # If this is ever revisited, the trigger has to be something that means
    # "the endpoint re-registered" and nothing else - transport_serial is not
    # that signal.  See the note in refreshInfo.
    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ": volume changed outside LMS to ${db}dB - following" );

    # Go through the mixer command rather than the accessor: it is what
    # notifies Material and anything else watching the slider.
    $self->execute( [ 'mixer', 'volume', $self->_dbToLms($db) ] );

    return;
}

# The fallback for a range the renderer will not report, and the only route
# that survives the user reconfiguring HQPlayer without a reconnect: ask for a
# level beyond the limit and HQPlayer answers with the limit itself.  VERIFIED
# live - <Volume value="-120"/> on the -100 instance reports back
# volume="-100".
#
# Deliberately conservative: it only reads a reply as a clamp when we asked for
# the limit we already believe in, or beyond it.  Anything looser would let a
# knob turn on the endpoint that happened to land inside the window be mistaken
# for a limit, which would collapse the range.
sub _learnFromClamp {
    my ( $self, $db ) = @_;

    my $sent = $self->hqVolSent;

    return unless defined $sent;
    return if ( Time::HiRes::time() - ( $self->hqVolSentAt || 0 ) ) > CLAMP_WINDOW;

    my $tol = $self->_volTol;

    if ( $db > $sent + $tol && $sent <= $self->_volMin + $tol ) {
        $self->hqVolSent(undef);
        $self->_setRange( $db, $self->_volMax );
    }
    elsif ( $db < $sent - $tol && $sent >= $self->_volMax - $tol ) {
        $self->hqVolSent(undef);
        $self->_setRange( $self->_volMin, $db );
    }

    return;
}

# The other way an instance turns out not to attenuate: it takes the command
# and simply does not move.  One strike per send, cleared the moment any level
# change is seen, so the state can never stick.
sub _watchForFixed {
    my ( $self, $was, $db ) = @_;

    my $sent = $self->hqVolSent;

    return unless defined $sent;

    my $tol = $self->_volTol;

    # It went where we asked: definitely attenuating.
    if ( abs( $db - $sent ) <= $tol ) {
        $self->hqVolSent(undef);
        $self->hqVolMissed(0);
        $self->_setFixed(0);
        return;
    }

    # The send and the push that carries the old level cross in flight.
    return if ( Time::HiRes::time() - ( $self->hqVolSentAt || 0 ) ) < MISS_DELAY;

    $self->hqVolSent(undef);

    # It moved, just not to where we asked - a clamp, or somebody else's
    # change.  Either way the volume is live.
    if ( defined $was && abs( $db - $was ) > $tol ) {
        $self->hqVolMissed(0);
        return;
    }

    my $missed = ( $self->hqVolMissed || 0 ) + 1;

    $self->hqVolMissed($missed);
    $self->_setFixed(1) if $missed >= FIXED_STRIKES;

    return;
}

# ---------------------------------------------------------------------------
# Status polling - this is what drives the LMS side of the state machine.
# ---------------------------------------------------------------------------
sub _startPolling {
    my $self = shift;

    # One <Status/> subscribes; HQPlayer pushes the rest. Control.pm routes
    # every Status message here, asked for or not.
    $self->_send('<Status/>');

    $self->hqLastStatus( Time::HiRes::time() );

    Slim::Utils::Timers::killTimers( $self, \&_statusWatchdog );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + STATUS_WATCHDOG, \&_statusWatchdog );

    return;
}

sub _stopPolling {
    my $self = shift;

    Slim::Utils::Timers::killTimers( $self, \&_statusWatchdog );

    return;
}

# Safety net only. If the subscription lapses - or never took - this pokes it
# back into life without ever becoming a busy poll.
sub _statusWatchdog {
    my $self = shift;

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + STATUS_WATCHDOG, \&_statusWatchdog );

    my $ctl = $self->hqControl;
    return unless $ctl && $ctl->connected;

    my $quiet = Time::HiRes::time() - ( $self->hqLastStatus || 0 );
    return if $quiet < STATUS_WATCHDOG;

    main::DEBUGLOG && $log->is_debug && $log->debug(
        $self->name . sprintf( ': no status for %.0fs, re-subscribing', $quiet ) );

    $self->_send('<Status/>');

    return;
}

# LMS will not write player.source debug to log.txt, so report the controller's
# own state alongside ours.  pause() is a silent no-op unless playingState is
# PLAYING(3) or PAUSED(4) - BUFFERING(1) and WAITING_TO_SYNC(2) both still
# report mode="play" to a status query, which makes a stuck state invisible.
my @PLAYING_STATE = qw(STOPPED BUFFERING WAITING_TO_SYNC PLAYING PAUSED);
my @STREAM_STATE  = qw(IDLE STREAMING STREAMOUT TRACKWAIT);

sub _ctlState {
    my $c = shift or return '';

    my $p = $c->{'playingState'};
    my $s = $c->{'streamingState'};

    return sprintf( ' [playing=%s streaming=%s]',
        defined $p ? ( $PLAYING_STATE[$p] || $p ) : '?',
        defined $s ? ( $STREAM_STATE[$s]  || $s ) : '?' );
}

# Does this status push describe the track we have MOVED ON FROM?
#
# HQPlayer pushes status ~1/s, so a track change (stop, then set the next URI
# and play) always straddles one or two of them, and a push describing the old
# track can arrive after we have set up the new one.  Read as current, a stale
# PLAYING latches the start of a track HQPlayer has not begun, and the stop
# that follows it then reads as end-of-track - LMS advances, and the track it
# has just started is skipped.
#
# The test is deliberately one-sided: a push counts as stale only when its uri
# is EXACTLY the one we were playing before and is not the current one.
# Anything unrecognised - a uri HQPlayer has normalised, a missing metadata
# child, or a url HQPlayer never echoed back - is
# treated as current, so this can only ever suppress a push we can positively
# identify as belonging to the previous track.  It can never wedge playback.
use constant STALE_LIMIT => 5;

sub _isStale {
    my ( $self, $uri ) = @_;

    return 0 unless defined $uri && $uri ne '';

    my $prev = $self->hqPrevURL;

    if ( !( defined $prev && $prev ne '' && $uri eq $prev ) ) {
        $self->hqStaleRun( 0 );
        return 0;
    }

    my $cur = $self->hqURL;

    if ( defined $cur && $uri eq $cur ) {
        $self->hqStaleRun( 0 );
        return 0;
    }

    # THE SUPPRESSION IS BOUNDED, and it has to be.
    #
    # This test suppresses a push because our bookkeeping says it describes a
    # track we have moved on from.  If that bookkeeping is ever WRONG - and a
    # spurious hand-over made it wrong, live - then every push is suppressed,
    # the position freezes, LMS keeps showing a track HQPlayer is not playing,
    # and there is no path out of it short of restarting the player.
    #
    # A track change straddles one or two pushes, which is what this exists
    # for; it never legitimately straddles five.  Past that, HQPlayer's account
    # of what it is playing beats ours, so adopt it and carry on.  A few
    # seconds of wrong elapsed time is a far better failure than a player that
    # has to be restarted.
    my $run = ( $self->hqStaleRun || 0 ) + 1;
    $self->hqStaleRun( $run );

    if ( $run > STALE_LIMIT ) {
        $log->warn( $self->name
            . ": $run consecutive status pushes suppressed as stale - our idea of the"
            . " current track is wrong.  Adopting HQPlayer's: $uri" );

        $self->hqPrevURL( undef );
        $self->hqURL( $uri );
        $self->hqStaleRun( 0 );

        return 0;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug(
        $self->name . ": ignoring a status push for the previous track ($run)" );

    return 1;
}

# Has HQPlayer advanced into the track we pre-queued?
#
# THIS IS THE SIGNAL THAT REPLACES state 0 BETWEEN TRACKS.  With two items on
# HQPlayer's playlist it never stops at a track boundary - which is the point -
# so the transition has to be read out of the status stream some other way.
# Two attributes carry it, and either is enough:
#
#   * `track` is HQPlayer's own playlist index, numbered from 1, and it is on
#     every <Status/> next to `tracks_total`.  This is the primary signal and
#     it works whatever the uri looks like.
#   * the <metadata uri=""> child, which on tier 1 is unique per track.  Kept
#     as corroboration for an engine that does not report `track`.
#
# BOTH ARE ONE-SIDED.  This only runs while something has actually been
# pre-queued (`hqNext`, mode `queue`), so neither can misfire on ordinary
# single-track playback, and the uri test additionally has to match the exact
# url we queued.  The worst either can do is fail to notice an advance, which
# degrades to the pre-gapless behaviour: HQPlayer reaches the end of its
# playlist, reports state 0, and LMS loads the next track the slow way.
sub _handedOver {
    my ( $self, $track, $meta ) = @_;

    my $next = $self->hqNext;

    return 0 unless $next && $next->{mode} eq 'queue';

    # Not until HQPlayer has CONFIRMED it holds the track.  Before the ack
    # there is nothing to advance into, and an index that moves inside that
    # window is describing something else.
    return 0 unless $next->{acked};

    my $seen = $self->hqTrackNo;
    my $uri  = $meta ? $meta->{uri} : undef;
    my $want = $next->{url} || '';

    # THE URI IS A VETO, NOT A HINT.  This is the correction to the first cut,
    # which took "the playlist index changed" OR "the uri matches" and fired on
    # either.  Live, it declared the hand-over 0.2s after queueing the track -
    # while HQPlayer was still playing the previous one.
    #
    # A SPURIOUS ADVANCE IS THE WORST FAILURE IN THIS FILE, because it is not
    # self-correcting: it points hqURL at a track HQPlayer is not playing and
    # hqPrevURL at the one it IS, so _isStale then suppresses EVERY push from
    # then on as "the previous track".  Position freezes, LMS shows the wrong
    # track, and nothing recovers it.
    #
    # On tier 1 every track has its own url, so a push naming a url that is not
    # the one we queued is positive evidence the hand-over has NOT happened,
    # whatever the index says.  Require the match; never merely prefer it.
    # ...UNLESS THE TWO TRACKS SHARE A URL, in which case the uri cannot tell
    # them apart and "HQPlayer is playing $want" is true before the advance as
    # well as after.  That fires instantly: observed live with the same track
    # twice in a row, two advances 0.2s apart, and LMS skipped an entry.
    # A duplicate in the queue and repeat-one both produce it.
    # ...AND UNLESS HQPLAYER HAS STRIPPED THE PART THAT MADE THEM DIFFERENT.
    #
    # HQPlayer removes the QUERY STRING from every uri it reports - the same
    # display quirk that faked the old "it cannot fetch a `?` url" rule. On
    # tier 5 the whole identity of a track is in that query string, so every
    # Qobuz track comes back as the identical `.../file` and the uri carries
    # ZERO discriminating information:
    #
    #   uri =.../file                                  <- reported, every track
    #   want=.../file?uid=355122&eid=193171336&hmac=..  <- what we queued
    #
    # Treating that as a veto meant the hand-over could NEVER be detected on a
    # streaming service: LIVE 2026-08-30, `track` went 1 -> 2 (the advance
    # demonstrably happened, and it sounded gapless) while every check said
    # "not yet". LMS never advanced, the next track was never armed, and
    # HQPlayer ran out of playlist and stopped mid-album with time still on the
    # counter.
    #
    # So compare like for like, on the stripped form. When the two tracks are
    # indistinguishable once stripped, the uri cannot tell them apart and this
    # is exactly the ambiguous case already handled below - fall through to the
    # index. Local tiers have no query string, so nothing changes for them.
    my $strip = sub {
        my $u = shift;
        return '' unless defined $u;
        $u =~ s/\?.*\z//s;
        return $u;
    };

    my $wantBase = $strip->($want);
    my $prevBase = $strip->( $self->hqURL || '' );

    my $ambiguous = ( $wantBase ne '' && $wantBase eq $prevBase );

    my $moved;

    if ( !$ambiguous && defined $uri && $uri ne '' ) {
        # Both sides stripped: what HQPlayer reports never has a query string.
        $moved = ( $strip->($uri) eq $wantBase );
    }
    else {
        # Nothing to judge by but the index, so only an INCREASE counts:
        # HQPlayer reports track="0" whenever it is not playing, so "changed"
        # reads an ordinary stop as an advance.
        $moved = ( defined $track && defined $seen
                   && $track =~ /^\d+$/ && $seen =~ /^\d+$/
                   && $track > $seen );
    }

    main::DEBUGLOG && $log->is_debug && $log->debug( $self->name
        . sprintf( ': hand-over check - track=%s seen=%s uri=%s want=%s%s -> %s',
            defined $track ? $track : '?', defined $seen ? $seen : '?',
            defined $uri ? $uri : '(none)', $want,
            $ambiguous ? ' (same url - index only)' : '',
            $moved ? 'ADVANCED' : 'not yet' ) );

    return 0 unless $moved;

    my $controller = $self->controller or return 0;

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': HQPlayer advanced into the pre-queued track' . _ctlState($controller) );

    $self->hqNext( undef );

    # The pre-queued track is now the current one.  hqStarted and hqPlayAck
    # both stay set: HQPlayer never stopped, and the <Play/> that is running is
    # still the one we sent - which is exactly why there is no re-arming of
    # hqExpectStop here either.  A stop from now on is a real end of playlist.
    $self->hqPrevURL( $self->hqURL );
    $self->hqURL( $next->{url} );

    # Position is HQPlayer's own, and it restarts with the new track.  The seek
    # offset belonged to the track that has just finished; a hand-over is never
    # seeked (see _canHandOver), so the new one starts at zero.
    $self->hqPosition( 0 );
    $self->hqSeekOffset( 0 );
    $self->hqStartedAt( Time::HiRes::time() );

    # Started in the PLAYING row of the state table is _Playing: it retires the
    # song that finished and promotes the one that was streaming.  It is the
    # ONLY thing to report - there was no end of stream and no stop, and saying
    # otherwise would make LMS load the track it is already playing.
    $controller->playerTrackStarted($self);

    # And line up the one after it.
    $self->_armNextTrack;

    return 1;
}

sub _onStatus {
    my ( $self, $attrs, $raw ) = @_;

    $self->hqLastStatus( Time::HiRes::time() );

    my $controller = $self->controller or return;

    my $state = Plugins::HQPlayerBridge::Control::pick( $attrs, 'state' );
    return unless defined $state && $state =~ /^\d+$/;

    # Position: HQPlayer gives a plain seconds attribute, and also a min/sec
    # pair. Prefer the former, fall back to reassembling the latter.
    my $pos = Plugins::HQPlayerBridge::Control::pick( $attrs, 'position' );

    if ( !defined $pos || $pos !~ /^[\d.]+$/ ) {
        my $mn = Plugins::HQPlayerBridge::Control::pick( $attrs, 'min' );
        my $sc = Plugins::HQPlayerBridge::Control::pick( $attrs, 'sec' );
        $pos = ( $mn || 0 ) * 60 + ( $sc || 0 ) if defined $mn || defined $sc;
    }

    # The real stream format lives on a <metadata/> child of <Status/>, not on
    # the root element.  The same child carries the uri HQPlayer is playing,
    # which is the only per-track identity in the status stream.
    my $stale = 0;
    my $meta;

    if ( $raw && $raw =~ /<metadata\b/ ) {
        ($meta) = Plugins::HQPlayerBridge::Control::parseChildren( $raw, 'metadata' );

        if ($meta) {
            $stale = $self->_isStale( $meta->{uri} );

            if ( !$stale ) {
                $self->hqRate( $meta->{samplerate} );
                $self->hqBits( $meta->{bits} );
            }
        }
    }

    $self->hqRate( $self->hqRate || Plugins::HQPlayerBridge::Control::pick( $attrs, 'active_rate' ) );

    # Volume changed at HQPlayer, or on the endpoint's own remote: mirror it
    # into LMS so the two never diverge.  Every <Status/> carries it in dB, so
    # this costs nothing extra - the subscribe is already running.
    my $db = Plugins::HQPlayerBridge::Control::pick( $attrs, 'volume' );

    $self->_followVolume( $db + 0 )
        if defined $db && $db =~ /^-?[\d.]+$/;

    # Volume is a property of the instance, not of the track, so it is followed
    # even from a stale push.  Position and transport state are not: they
    # describe a track we have already moved on from.
    return if $stale;

    # Did HQPlayer advance into a track we handed it early?  This has to run
    # before the position below, because from this push on the position belongs
    # to the NEW track.
    my $track = Plugins::HQPlayerBridge::Control::pick( $attrs, 'track' );

    $self->_handedOver( $track, $meta ) if $self->hqNext;

    $self->hqTrackNo($track) if defined $track;

    if ( defined $pos && $pos =~ /^[\d.]+$/ ) {
        $self->hqPosition( $pos + 0 );
        # Store the stream-relative value, so anything reading the plain
        # accessor sees the same figure our override reports.
        my $rel = $pos - ( $self->hqSeekOffset || 0 );
        $self->SUPER::songElapsedSeconds( $rel > 0 ? $rel : 0 );
    }

    if ( $state == HQP_PLAYING ) {

        # Playing again, so any stop we were holding was a track boundary.
        $self->_cancelEndOfStream;

        # Only once HQPlayer has accepted Play for the CURRENT track is a
        # PLAYING push evidence that THIS track is running.  Before that it is
        # the previous one still winding down, and treating it as a start both
        # disarms the end-of-track guard and reports a track as started that
        # HQPlayer has not begun.
        my $ack = $self->hqPlayAck;

        $self->hqExpectStop( 0 ) if $ack;

        # Resumed at HQPlayer itself, or on the endpoint's own remote.
        if ( ( $self->hqWanted || '' ) eq 'pause' ) {

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': resumed outside LMS - following' . _ctlState($controller) );

            # Set this FIRST: the resume below calls back into our resume(),
            # which must not send <Play/> to something already playing.
            $self->hqWanted('play');

            # Resume in any other state is _Invalid and only logs an error.
            $controller->resume if $controller->isPaused;
        }

        if ( $ack && !$self->hqStarted ) {
            $self->hqStarted( 1 );
            $self->hqStartedAt( Time::HiRes::time() );

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': HQPlayer is playing' . _ctlState($controller) );

            # Started, and then - separately - ReadyToStream.
            #
            # ReadyToStream while a track is playing is the "I can take another
            # stream" signal, and LMS answers it by resolving the next song and
            # calling play() again.  That used to be fatal here, because every
            # play() ran the four-command load and clobbered the track that was
            # still playing.  It is now the FIRST HALF OF GAPLESS: play()
            # recognises the call and appends rather than replaces.  See
            # _armNextTrack, which also declines to ask on tier 4.
            $controller->playerTrackStarted($self);

            $self->_armNextTrack;
        }

        $controller->playerStatusHeartbeat($self);
    }
    elsif ( $state == HQP_PAUSED ) {

        # Paused at HQPlayer itself, or on the endpoint's own remote.
        if ( $self->hqStarted && ( $self->hqWanted || '' ) eq 'play' ) {

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': paused outside LMS - following' . _ctlState($controller) );

            $self->hqWanted('pause');

            # TRAP: the controller's pause() is a TOGGLE - the Pause event in
            # the PAUSED row of the state table is _Resume/_JumpOrResume.  Only
            # send it when the controller is not already paused.
            $controller->pause unless $controller->isPaused;
        }

        $controller->playerStatusHeartbeat($self);
    }
    elsif ( $state == HQP_STOPPED ) {

        if ( $self->hqStarted && !$self->hqExpectStop ) {

            # START-UP NOISE, NOT THE END.  HQPlayer reports PLAYING as soon as
            # it accepts the stream and can then drop back to STOPPED for a
            # moment while the first bytes arrive - measured at 0.33s live on a
            # tier 4 track, where LMS has to spin up a transcode.  Read as the
            # end it skipped the track outright, 0.33s in.
            #
            # hqExpectStop already covers the window before the new track is
            # confirmed; this covers the window just after it.
            my $age = Time::HiRes::time() - ( $self->hqStartedAt || 0 );

            if ( $age < START_GRACE ) {
                main::DEBUGLOG && $log->is_debug && $log->debug( $self->name
                    . sprintf( ': ignoring a stop %.2fs into the track - too early to be the end', $age ) );
                return;
            }

            # A track LMS handed over early that could NOT ride HQPlayer's own
            # playlist - tier 4, see _handOver.  Load it now, the ordinary way.
            # There is nothing to report to LMS: it has been streaming this
            # song since the hand-over, and the playerTrackStarted at the far
            # end of the load is what retires the one that just finished.
            #
            # This is the pre-gapless gap, and on tier 4 it is unavoidable -
            # but LMS resolved the track minutes ago, so the gap is now just
            # HQPlayer's own load.
            my $next = $self->hqNext;

            if ( $next && $next->{mode} eq 'load' ) {
                $self->hqNext( undef );

                main::INFOLOG && $log->is_info && $log->info(
                    $self->name . ': end of track - loading the tier 4 track LMS handed over early'
                        . _ctlState($controller) );

                $self->_startTrack( $next->{song}, $next->{seek} );

                return;
            }

            # A GAPLESS BOUNDARY LOOKS EXACTLY LIKE THE END OF THE PLAYLIST.
            #
            # Observed live 2026-08-28, 200ms after a correct hand-over into
            # the pre-queued track:
            #
            #   state="2" track="2/3" uri=".../437344.flac"   <- handed over
            #   state="0" track="0"   tracks_total="0"        <- 200ms later
            #   state="2" track="3/4" uri=".../437344.flac"   <- 2s later
            #
            # That middle push is byte-identical to the one a genuine end of
            # playlist produces - everything zeroed, no metadata child - so
            # there is nothing in it to tell the two apart.  Read as the end,
            # it reported EndOfStream/Stopped mid-album: LMS advanced an extra
            # track, stopped, and every later push arrived at a controller in
            # STOPPED/IDLE where TrackStarted is _Invalid.
            #
            # THE ONLY DISCRIMINATOR IS TIME, so the report is debounced - but
            # only in the one state where the transient is possible: a
            # hand-over we have queued and HQPlayer has acknowledged, which is
            # exactly when it has another item to move into.  Anything else
            # (nothing queued, or a held tier 4 track) is reported at once, as
            # before, because there is nothing for HQPlayer to move into and
            # the stop can only be real.
            #
            # A genuine stop is still reported, just END_GRACE later - which
            # matters for a stop made at HQPlayer's own UI while a hand-over
            # happens to be queued.
            if ( $next && $next->{mode} eq 'queue' && $next->{acked} ) {

                main::DEBUGLOG && $log->is_debug && $log->debug( $self->name
                    . ': stopped with a hand-over queued - waiting '
                    . END_GRACE . 's to see if this is a track boundary' );

                Slim::Utils::Timers::killTimers( $self, \&_endOfStream );
                Slim::Utils::Timers::setTimer(
                    $self, Time::HiRes::time() + END_GRACE, \&_endOfStream );

                return;
            }

            $self->_endOfStream;
        }
    }

    return;
}


# Cancel a pending end-of-stream: HQPlayer is playing again, so the stop that
# armed it was a track boundary after all.
sub _cancelEndOfStream {
    Slim::Utils::Timers::killTimers( $_[0], \&_endOfStream );
    return;
}

sub _endOfStream {
    my $self = shift;

    Slim::Utils::Timers::killTimers( $self, \&_endOfStream );

    my $controller = $self->controller or return;

    return unless $self->hqStarted;

    # HQPlayer ran off the end of its playlist under its own steam, so this is
    # end-of-stream: report it and let LMS advance.  Verified live: state goes
    # 2 -> 0 when the last track finishes.
    $self->hqStarted( 0 );

    # Whatever was queued belongs to the run that has just ended.  Leaving it
    # set let a hand-over fire AFTER the end of the playlist, against a
    # controller already in STOPPED/IDLE where TrackStarted is _Invalid -
    # observed live at the tail of a skip test.
    $self->hqNext( undef );
    $self->hqArmNext( 0 );

    main::INFOLOG && $log->is_info && $log->info(
        $self->name . ': end of playlist' . _ctlState($controller) );

    # Now, and only now, is it safe to say we can take another stream.
    $controller->playerEndOfStream($self);
    $controller->playerReadyToStream($self);
    $controller->playerStopped($self);

    $self->_stopPolling;

    return;
}

sub songElapsedSeconds {
    my $self = shift;

    return $self->SUPER::songElapsedSeconds(@_) if @_;

    my $p = $self->hqPosition;

    return $self->SUPER::songElapsedSeconds() unless defined $p;

    # TRAP: this must be elapsed WITHIN THE STREAM, not absolute position in
    # the track.  playingSongElapsed computes startOffset + songElapsedSeconds,
    # so if we hand back an absolute position after a seek the offset is
    # counted twice and LMS runs at double the real time.  Tier 1 seeks inside
    # HQPlayer, so subtract what we asked it to skip; tiers 3 and 4 never set
    # it - one cannot seek and the other has the offset applied by LMS.
    my $t = $p - ( $self->hqSeekOffset || 0 );

    return $t > 0 ? $t : 0;
}

# ---------------------------------------------------------------------------
# One-off queries used by the status page
# ---------------------------------------------------------------------------
# Stop HQPlayer walking off the end of its own playlist, because doing so
# KILLS THE DAEMON.
#
# VERIFIED 2026-08-28 from hqplayerd's own log: at the end of a track HQPlayer
# advances by itself (`Next (0)`), and this bridge keeps its playlist at
# exactly one entry, so that advance runs past the end.  With the album-gain
# option on - `playlist_album_gain="1"`, and it is HQPlayer's ONLY replaygain
# mode, so a user who wants replaygain has it on - the overrun throws
# `clPlaylist::GetAlbumGain(): trackn > last`, which is UNHANDLED in
# `clPlayerDaemon::Main()` and takes the process down:
#
#   End of track at 185.472/188/2.528
#   Next  (0)
#   ! NextNL(): clPlaylist::GetAlbumGain(): trackn > last
#   ! Main(): Stop(): clPlaylist::GetAlbumGain(): trackn > last
#   - Server stopping...
#
# It fires on a COMPLETE track, not just a truncated one, so it is not a
# streaming artifact - and from LMS's side it reads as the bridge racing
# through the playlist, because `state` 0 means both "the engine died" and
# "end of track".
#
# THAT GUARD WAS `<SetRepeat value="1"/>`, AND IT WAS WRONG.  Its own note
# above asked the right question - whether HQPlayer with repeat on still
# reports state 0 at the end of a track, or loops and stays at 2 - and shipped
# without answering it.  It loops.  So the playlist never ended, `state` never
# reached 0, `_onStatus` never reported end-of-track, and LMS never sent the
# next track: a full LMS queue played its FIRST TRACK on repeat forever.
#
# Repeat is asserted OFF instead.  LMS owns the playlist, and the END of that
# playlist has to be observable as state 0 or the bridge can never stop.
# Asserting it also stops a user's own HQPlayer repeat setting from silently
# breaking the advance.
#
# NOTE since gapless: HQPlayer's playlist now holds up to TWO items, so a
# track boundary is no longer an end of playlist and no longer reaches
# GetAlbumGain at all - the advance the note below describes only happens once
# per run rather than once per track.  Repeat is still asserted off, for the
# same reason and with more force: with it on the playlist would never end and
# _onStatus would never see the state 0 that stops the player.
#
# AND THE OVERRUN NO LONGER HAPPENS.  Verified live 2026-08-28 against engine
# 6.0.4, repeat off, a complete 13.5s track played to its natural end:
#
#   t=6s   state="2" position="11.6"
#   t=8s   state="0" position="0"     <- clean end, daemon ALIVE
#   t=10s  state="2" position="0"     <- LMS sent the next track by itself
#
# The daemon survived, and LMS advanced from its own queue. The crash needed
# the two-channel load: with Stop on the control socket racing a UPnP
# SetAVTransportURI, the engine's playlist was emptied underneath a renderer
# that still believed it was playing, and THAT is what walked `trackn` past
# `last`.  On one ordered socket the playlist and the engine never disagree.
#
# If `GetAlbumGain(): trackn > last` is ever seen again, the fallback is the
# user-side switch, not repeat: `playlist_album_gain="0"` in
# `~/.hqplayer/hqplayerd.xml`.  Do NOT bring repeat back - it trades a crash
# for a player that cannot advance.
sub assertRepeatOff {
    my $self = shift;

    $self->_send('<SetRepeat value="0"/>');

    return 1;
}

sub refreshInfo {
    my $self = shift;

    # The volume range does not come from here: GetInfo does not carry one, and
    # the XML control API answers "Unknown command" for GetVolumeDBRange.  It
    # is a UPnP action, and it works - see refreshVolumeRange.
    $self->refreshVolumeRange;

    $self->assertRepeatOff;

    $self->_send( '<GetInfo/>', sub {
        my $attrs = shift or return;

        $self->hqEngine( Plugins::HQPlayerBridge::Control::pick( $attrs, 'engine' ) );
        $self->hqProduct( Plugins::HQPlayerBridge::Control::pick( $attrs, 'product' ) );
    } );

    # GetTransport answers with a bare numeric id (e.g. value="240") and no
    # device name.  Verified 2026-08-26: the XML control API does not expose
    # the selected NAA's name at all - it appears only in hqplayerd's own log
    # ("NAA output endpoint 'name' : 'device'"), which is not reachable from
    # another host.  So report the id and be honest about it.
    $self->_send( '<GetTransport/>', sub {
        my $attrs = shift or return;

        $self->hqTransport( Plugins::HQPlayerBridge::Control::pick( $attrs, 'value' ) );
    } );

    return;
}

1;
