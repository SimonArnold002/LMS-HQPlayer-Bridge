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
use Slim::Utils::Network;
use Time::HiRes ();

use Plugins::HQPlayerBridge::Control;
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
    hqWanted hqVolDb
) );

my $log        = logger('plugin.hqplayerbridge');
my $serverPrefs = preferences('server');

# <Status/> is a SUBSCRIBE, not a poll: one is enough, after which HQPlayer
# streams status at roughly 1/s on its own.  So we never poll - we only keep a
# slow watchdog to re-subscribe if the stream ever dries up.
use constant STATUS_WATCHDOG => 10;

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
# else has to go through LMS's transcoder on tier 2.  Keyed by LMS content_type.
my %HQP_PLAYS = map { $_ => 1 } qw(
    flc flac wav aif aiff dsf dff wvp wv mp3 mp2 ogg ogf
);

# LMS's internal content-type codes are not all valid filename extensions.  The
# extension still matters to LMS itself: downloadMusicFile only transcodes when
# the resolved type differs from the track's own, so a truthful extension keeps
# it a byte-for-byte passthrough.
# HQPlayer decides by Content-Type, but the DIDL <res protocolInfo> should
# still be truthful.
my %MIME_FOR_TYPE = (
    flc => 'audio/x-flac',  flac => 'audio/x-flac',
    wav => 'audio/x-wav',   aif  => 'audio/x-aiff',  aiff => 'audio/x-aiff',
    dsf => 'audio/x-dsf',   dff  => 'audio/x-dff',
    wvp => 'audio/x-wv',    wv   => 'audio/x-wv',
    mp3 => 'audio/mpeg',    mp2  => 'audio/mpeg',
    ogg => 'audio/ogg',     ogf  => 'audio/ogg',
);

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
    );

    return $client;
}

sub model     { 'hqplayer' }
sub modelName { 'HQPlayer' }
sub formats   { qw(flc pcm aif mp3) }   # order is LMS's preference order

sub maxSupportedSamplerate { 768000 }

sub isPlayer          { 1 }
# Volume is shared with HQPlayer rather than owned by either side - see the
# volume() block below for the mapping and for both directions of the sync.
sub hasVolumeControl  { 1 }
sub hasDigitalOut     { 1 }
sub canDirectStream   { 0 }
sub canDoReplayGain   { 0 }
sub needsWeightedPlayPoint { 0 }
sub connected         { $_[0]->tcpsock ? 1 : 0 }
sub opened            { undef }
sub signalStrength    { 100 }

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
sub flush         { 1 }

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

        if ( $id && !$HQP_PLAYS{$ct} ) {
            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ": '$ct' is not in HQPlayer's mime table - using tier 2 so LMS transcodes" );
        }

        if ( $id && $HQP_PLAYS{$ct} ) {
            my $ext = $EXT_FOR_TYPE{$ct} || $ct;

            # Tier 1 - original file bytes straight from LMS, tags and embedded
            # artwork intact, range-seekable, native DSD included.  The
            # extension resolves back to the track's own type, so LMS compares
            # equal and streams it through without transcoding.
            $self->hqTier( 1 );

            my $url = $base . '/music/' . $id . '/download' . ( $ext ? ".$ext" : '' );

            main::INFOLOG && $log->is_info && $log->info( $self->name . ": tier 1 (native passthrough) $url" );

            return $url;
        }
    }

    # Tier 2 - anything remote (Qobuz, Tidal, radio) comes back through LMS's
    # own player stream, transcoded per formats() above.
    $self->hqTier( 2 );

    my $url = $base . '/stream.mp3?player=' . $self->id;

    main::INFOLOG && $log->is_info && $log->info( $self->name . ": tier 2 (LMS stream) $url" );

    return $url;
}

# Build the DIDL-Lite that rides along with SetAVTransportURI.
#
# This is the ONLY way metadata reaches HQPlayer.  Over the XML control API it
# labels any http source "HTTP stream" and ignores title/artist/album/song
# attributes outright; via UPnP it honours all of them, and it re-serves
# <upnp:albumArtURI> from its own web server at /cover/current - which is where
# an endpoint's display picks the cover up.  That is what the squeeze2upnp
# bridge was doing, and why artwork appeared there and not here.
sub _didl {
    my ( $self, $song, $url, $mime ) = @_;

    my $track = eval { $song->currentTrack() } or return '';
    my $e = \&Plugins::HQPlayerBridge::Control::escape;

    my $title  = eval { $track->title }      || '';
    my $artist = eval { $track->artistName } || '';
    my $album  = eval { $track->albumname }  || '';
    my $art    = $self->_coverURL($track);
    my $secs   = eval { $track->secs };

    my $didl =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
      . ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
      . ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      . '<item id="1" parentID="0" restricted="1">'
      . '<dc:title>' . $e->($title) . '</dc:title>';

    $didl .= '<upnp:artist>' . $e->($artist) . '</upnp:artist>'
           . '<dc:creator>'  . $e->($artist) . '</dc:creator>' if $artist ne '';
    $didl .= '<upnp:album>'  . $e->($album)  . '</upnp:album>'  if $album  ne '';
    $didl .= '<upnp:albumArtURI>' . $e->($art) . '</upnp:albumArtURI>' if $art;

    $didl .= '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
           . '<res protocolInfo="http-get:*:' . ( $mime || '*' ) . ':*"'
           . ( $secs ? ' duration="' . sprintf( '%d:%02d:%02d', int($secs/3600), int($secs/60)%60, int($secs)%60 ) . '"' : '' )
           . '>' . $e->($url) . '</res>'
           . '</item></DIDL-Lite>';

    return $didl;
}

sub _coverURL {
    my ( $self, $track ) = @_;

    my $url = eval { $track->url } || '';

    # Remote tracks (Qobuz, Tidal, radio...) have a NEGATIVE track id and no
    # coverid, so /music/<id>/cover.jpg cannot resolve them - it returns the
    # "no artwork" placeholder.  Their artwork comes from the protocol handler,
    # and it is usually already an /imageproxy/ path, which is exactly what the
    # image proxy is for.
    if ( $url && Slim::Music::Info::isRemoteURL($url) ) {

        my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

        if ( $handler && $handler->can('getMetadataFor') ) {
            my $meta = eval { $handler->getMetadataFor( $self, $url ) } || {};
            my $art  = $meta->{cover} || $meta->{coverart} || $meta->{icon} || $meta->{artwork_url};

            if ($art) {
                return $art if $art =~ m{^https?://};
                return $self->_serverBase . ( $art =~ m{^/} ? $art : "/$art" );
            }
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
sub play {
    my ( $self, $params ) = @_;

    my $controller = $params->{controller};
    my $song       = eval { $controller->song } or do {
        $log->error( $self->name . ': play() with no song' );
        return 0;
    };

    my $url = $self->_resolveURL($song);

    $self->hqStarted( 0 );
    $self->hqExpectStop( 0 );
    $self->hqPosition( 0 );
    $self->hqSeekOffset( 0 );
    $self->hqWanted( 'play' );

    # HQPlayer owns the buffer, so LMS can never learn about it from a STAT.
    # We assert it ourselves once HQPlayer has the URI and is playing - see
    # _queueTrack.  Until then it must read false, or a stale 1 from the
    # previous track would let the controller start before HQPlayer has the
    # new one.
    $self->bufferReady( 0 );

    my $seek = $params->{seekdata} ? $params->{seekdata}->{timeOffset} : undef;

    $self->_queueTrack( $url, $song, $seek );

    # The controller counts the player as started from here; actual playback
    # is confirmed by the status poll below.
    return 1;
}

sub _queueTrack {
    my ( $self, $url, $song, $seek ) = @_;

    my $upnp = $self->hqUPnP;

    if ( !$upnp || !$upnp->ready ) {
        $log->error( $self->name . ': UPnP renderer not ready - cannot start playback' );
        my $c = $self->controller;
        $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
        return;
    }

    my $track = eval { $song->currentTrack() };
    my $ct    = $track ? ( eval { $track->content_type } || '' ) : '';
    my $mime  = ( $self->hqTier || 0 ) == 1 ? $MIME_FOR_TYPE{$ct} : undef;

    my $didl = $self->_didl( $song, $url, $mime );

    $upnp->setURI( $url, $didl, sub {
        my ( $res, $err ) = @_;

        if ($err) {
            $log->error( $self->name . ": HQPlayer would not accept the track URI: $err" );
            my $c = $self->controller;
            $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
            return;
        }

        # Play, with retries: HQPlayer needs a moment to fetch and probe the
        # media after accepting the URI - see playWhenReady in UPnP.pm.
        $upnp->playWhenReady( sub {
            my ( $r2, $e2 ) = @_;

            if ($e2) {
                my $c = $self->controller;
                $c->playerStreamingFailed( $self, 'PROBLEM_OPENING' ) if $c;
                return;
            }

            # Seek, but ONLY on tier 1.
            #
            # The two tiers put the offset in different places.  Tier 1 hands
            # HQPlayer a plain file URL, so LMS is not in the byte path at all
            # and HQPlayer has to do the seeking itself.  Tier 2 goes through
            # /stream.mp3, and since we canDirectStream(0) it is LMS that opens
            # the source - so those bytes ALREADY start at the offset.  Seeking
            # again there would skip a second time and land at 2x the offset.
            #
            # Remember what we told HQPlayer to skip, because it reports an
            # absolute position and playingSongElapsed adds startOffset on top
            # - see songElapsedSeconds.
            if ( $seek && $seek > 0 && ( $self->hqTier || 0 ) == 1 ) {
                $self->_send( '<Seek position="' . int($seek) . '"/>' );
                $self->hqSeekOffset( int($seek) );
            }

            # TRAP: playerBufferReady alone is not enough.  It routes to
            # _WaitToSync -> _StartIfReady, which polls *every* player's
            # isBufferReady() - i.e. the client's own bufferReady flag, which
            # only Squeezebox's STAT handler ever sets.  Leave it at 0 and the
            # controller parks in WAITING_TO_SYNC forever, where Pause maps to
            # _NoOp and Started maps to _Invalid.  Set the flag first.
            $self->bufferReady( 1 );

            my $c = $self->controller;
            $c->playerBufferReady($self) if $c;

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

    # Mark this as our own stop so the poll does not read it as end-of-track
    # and advance the playlist underneath us.
    $self->hqExpectStop( 1 );
    $self->hqStarted( 0 );
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
# hqVolDb is the last level we know HQPlayer is at, and it stops those two
# directions chasing each other: neither side re-sends a value that already
# matches it.
#
# The XML channel, not UPnP.  Measured on the live daemon: a command on the
# open control socket answers in ~9ms, while HQPlayer's UPnP RenderingControl
# takes 300-550ms - which was the volume lag.  The command is plain
# <Volume value="-53"/>; SetVolume/SetVolumeDB/GetVolume do not exist.
#
# dB = LMS - 100, so LMS 100 is 0dB and one LMS step is 1dB.  That is exactly
# what HQPlayer's UPnP endpoint was doing with the 0-100 it got, so the feel of
# the slider is unchanged - it just responds now.
use constant HQP_VOL_MIN_DB => -100;
use constant HQP_VOL_MAX_DB => 0;

# Perl's int() truncates towards zero, so a bare int($v + 0.5) rounds negative
# values the wrong way - and every dB figure here is negative.
sub _round { my $v = shift; return $v < 0 ? -int( -$v + 0.5 ) : int( $v + 0.5 ) }

sub _lmsToDb { my $v = _round( $_[0] ) + HQP_VOL_MIN_DB;
               $v = HQP_VOL_MIN_DB if $v < HQP_VOL_MIN_DB;
               $v = HQP_VOL_MAX_DB if $v > HQP_VOL_MAX_DB; return $v }

sub _dbToLms { my $v = _round( $_[0] ) - HQP_VOL_MIN_DB;
               $v = 0   if $v < 0;
               $v = 100 if $v > 100; return $v }

# LMS ramps the volume down and back up around every pause and resume, and
# fires the actual pause from the ramp's completion callback ~300ms later.
# Since those steps are temporary volumes we never forward (see volume()), the
# ramp is silent here - all it does is delay the pause by 300ms.  Skip it and
# call the callback straight away.
sub fade_volume {
    my ( $self, $fade, $cb, $cbargs ) = @_;

    # _Resume parks a temporary volume of 0 before the fade-in, and
    # Client::volume reports a temporary level in preference to the real one -
    # so leaving it set would show the slider at zero after every resume.
    $self->_tempVolume(undef);

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

    my $db = _lmsToDb($newvolume);

    if ( !defined $self->hqVolDb || $self->hqVolDb != $db ) {
        $self->hqVolDb($db);
        $self->_send( '<Volume value="' . $db . '"/>' );
    }

    return $vol;
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
    # the root element.
    if ( $raw && $raw =~ /<metadata\b/ ) {
        my ($m) = Plugins::HQPlayerBridge::Control::parseChildren( $raw, 'metadata' );

        if ($m) {
            $self->hqRate( $m->{samplerate} );
            $self->hqBits( $m->{bits} );
        }
    }

    $self->hqRate( $self->hqRate || Plugins::HQPlayerBridge::Control::pick( $attrs, 'active_rate' ) );

    # Volume changed at HQPlayer, or on the endpoint's own remote: mirror it
    # into LMS so the two never diverge.  Every <Status/> carries it in dB, so
    # this costs nothing extra - the subscribe is already running.
    my $db = Plugins::HQPlayerBridge::Control::pick( $attrs, 'volume' );

    if ( defined $db && $db =~ /^-?[\d.]+$/ ) {
        $db = _round($db);

        if ( !defined $self->hqVolDb || $self->hqVolDb != $db ) {

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ": volume changed outside LMS to ${db}dB - following" );

            # Set this FIRST so the mixer command below, which lands back in
            # our own volume(), sees the level as already current and does not
            # send it straight back out.
            $self->hqVolDb($db);

            # Go through the mixer command rather than the accessor: it is what
            # notifies Material and anything else watching the slider.
            $self->execute( [ 'mixer', 'volume', _dbToLms($db) ] );
        }
    }

    if ( defined $pos && $pos =~ /^[\d.]+$/ ) {
        $self->hqPosition( $pos + 0 );
        # Store the stream-relative value, so anything reading the plain
        # accessor sees the same figure our override reports.
        my $rel = $pos - ( $self->hqSeekOffset || 0 );
        $self->SUPER::songElapsedSeconds( $rel > 0 ? $rel : 0 );
    }

    if ( $state == HQP_PLAYING ) {

        $self->hqExpectStop( 0 );

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

        if ( !$self->hqStarted ) {
            $self->hqStarted( 1 );

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': HQPlayer is playing' . _ctlState($controller) );

            # ONLY Started here.
            #
            # ReadyToStream must NOT be sent while a track is playing: it is
            # the "I can accept another stream" signal, and LMS answers it by
            # streaming the NEXT song and calling play() again - which for this
            # player means SetAVTransportURI + Play, clobbering the track that
            # is still playing.  We are not gapless, so ReadyToStream belongs
            # at end-of-track, below.
            $controller->playerTrackStarted($self);
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
            # HQPlayer ran off the end of the track under its own steam, so
            # this is end-of-stream: report it and let LMS advance.  Verified
            # live: state goes 2 -> 0 when a track finishes.
            $self->hqStarted( 0 );

            main::INFOLOG && $log->is_info && $log->info(
                $self->name . ': end of track' . _ctlState($controller) );

            # Now, and only now, is it safe to say we can take another stream.
            $controller->playerEndOfStream($self);
            $controller->playerReadyToStream($self);
            $controller->playerStopped($self);

            $self->_stopPolling;
        }
    }

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
    # HQPlayer, so subtract what we asked it to skip; tier 2 never sets it.
    my $t = $p - ( $self->hqSeekOffset || 0 );

    return $t > 0 ? $t : 0;
}

# ---------------------------------------------------------------------------
# One-off queries used by the status page
# ---------------------------------------------------------------------------
sub refreshInfo {
    my $self = shift;

    # GetInfo carries engine/product/platform, but NOT a volume range - there
    # is no GetVolumeDBRange in the XML control API (it exists as a UPnP action
    # only, and returns "Unknown command" here).  HQPlayer clamps to its own
    # configured range anyway, so the defaults above are safe.
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
