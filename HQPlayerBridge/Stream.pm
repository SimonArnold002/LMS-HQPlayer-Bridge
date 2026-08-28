package Plugins::HQPlayerBridge::Stream;

# TIER 4 - a path-only audio endpoint, so that streaming services play.
#
# WHY THIS EXISTS
#
# LMS serves a player's audio on `/stream.mp3?player=<mac>`, and HQPlayer
# CANNOT FETCH A URL CONTAINING A QUERY STRING.  Isolated live 2026-08-28
# against engine 6.0.4, the same file each time:
#
#   /music/458773/download.flac             -> plays  (state 2, proc 3.27)
#   /music/458773/download.flac?x=1         -> silent (state 0)
#   /stream.mp3?player=02:ab:88:42:4c:69    -> silent (state 0)
#
# `PlaylistAdd` answers result="OK" in every case and then simply never fetches
# it, which is why this read as a transcoding problem and then a single-
# consumer-stream problem for the whole of development: every command succeeds,
# and the only evidence is the HEAD that never arrives.
#
# A redirect does not rescue it either.  Pointed at a server answering 302, the
# HEAD arrived and NO GET EVER CAME - HQPlayer does not follow redirects.  So
# the URL handed over has to be fetchable exactly as it is, and the fix has to
# be on our side: a path with no `?` in it.
#
# WHAT IT DOES
#
#   http://<server>/hqp/<token>/<seq>.<ext>
#
# `token` is the player id with `:` replaced by `-` (no state to keep, and it
# survives a server restart).  `seq` makes every track's url unique, which is
# what stops HQPlayer treating a repeat of the same url as the item it is
# already holding.  `ext` is cosmetic - HQPlayer picks its decoder by HTTP
# Content-Type, never by filename - but a truthful one keeps the logs readable.
#
# There is no proxying and no second HTTP request.  The handler hands the
# socket to LMS's own player-streaming machinery, which is exactly what
# /stream.mp3 does: set %peerclient, write the headers, and let
# addStreamingResponse take it from there.  From that point the bytes come off
# `$client->nextChunk` like any other player's.
#
# WHY TIER 4 IS NOT PRE-QUEUED FOR GAPLESS
#
# A client has ONE `streamingsocket`.  Arming a hand-over would have LMS open
# the next song's source - and swap songStreamController - while HQPlayer is
# still pulling the current one down the socket, so the rest of the playing
# track would arrive as the beginning of the next.  A real Squeezebox gets away
# with this because it buffers a whole track ahead; HQPlayer pulls
# progressively.  So a tier 4 next track is HELD and loaded when the current
# one ends, exactly as _armNextTrack already arranges.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Music::Info;
use Slim::Player::Client;
use Slim::Web::Pages;
use Slim::Web::HTTP;

my $log = logger('plugin.hqplayerbridge');

use constant PATH_PREFIX => '/hqp/';

# HTTP wants CRLF regardless of what the platform thinks a newline is.
use constant CRLF => "\015\012";

# Last resort only.  The real type comes from the song LMS is streaming.
use constant FALLBACK_TYPE => 'audio/x-flac';

# One counter per player, so every track gets a url of its own.
my %SEQ;

sub init {
    Slim::Web::Pages->addRawFunction( qr{^/hqp/}, \&_handler );

    main::INFOLOG && $log->is_info && $log->info( 'tier 4 stream endpoint registered at ' . PATH_PREFIX );

    return;
}

# ---------------------------------------------------------------------------
# Minting the url
# ---------------------------------------------------------------------------

# The player id with the colons taken out.  A colon is legal in a path segment
# and HQPlayer does accept one, but it reads as a port separator to enough
# other things that it is not worth the argument.
sub tokenFor {
    my ( $class, $id ) = @_;

    return '' unless defined $id;

    $id =~ s/:/-/g;

    return $id;
}

sub urlFor {
    my ( $class, $client, $base, $song ) = @_;

    my $token = $class->tokenFor( $client->id );
    my $seq   = ++$SEQ{ $client->id };

    return $base . PATH_PREFIX . $token . '/' . $seq . '.' . _extFor($song);
}

# Cosmetic - see the header.  `flac` is the right default: formats() puts flc
# first and initBitrateLimit clears the cap that used to silently make every
# stream an MP3.
sub _extFor {
    my $song = shift;

    my %EXT = ( flc => 'flac', mp3 => 'mp3', aif => 'aiff', pcm => 'wav', wav => 'wav', ogg => 'ogg' );

    my $fmt = eval { $song && $song->streamformat } || '';

    return $EXT{$fmt} || 'flac';
}

# ---------------------------------------------------------------------------
# Serving it
# ---------------------------------------------------------------------------

# A raw function is called as ($httpClient, $response) from the very top of
# Slim::Web::HTTP::processHTTP, BEFORE processURL - so nothing has guessed at a
# client for us and nothing will run after we return.  Whatever this does with
# the socket is the whole of the response.
sub _handler {
    my ( $httpClient, $response ) = @_;

    return unless $httpClient && $httpClient->connected;

    my $request = $response->request;
    my $path    = eval { $request->uri->path } || '';
    my $method  = $request->method || 'GET';

    my ($token) = $path =~ m{^/hqp/([^/]+)/};

    my $client = $token ? _clientFor($token) : undef;

    if ( !$client ) {
        $log->warn("no player for stream request $path");
        return _fail( $httpClient, $response, 404, 'no such player' );
    }

    my $type = _contentType($client);

    main::INFOLOG && $log->is_info && $log->info(
        $client->id . ": $method $path -> $type" );

    $response->code(200);
    $response->content_type($type);

    # There is no length to seek within and no way to satisfy a Range, so say
    # so rather than letting HQPlayer discover it by asking.
    $response->header( 'Accept-Ranges' => 'none' );
    $response->header( 'Cache-Control' => 'no-cache, no-store' );
    $response->header( Connection      => 'close' );

    # HQPlayer HEADs before it GETs.  Answer the HEAD as an ordinary response -
    # addHTTPResponse drops the body for us - and DO NOT hand over the socket:
    # attaching the player's stream to a HEAD would pour the track into a
    # connection that is about to be closed and leave the real GET with
    # nothing.
    if ( $method eq 'HEAD' ) {
        my $empty = '';
        Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$empty );
        return;
    }

    if ( $method ne 'GET' ) {
        return _fail( $httpClient, $response, 405, 'method not allowed' );
    }

    # ONE CONNECTION AT A TIME, AND NOBODY ELSE WILL ENFORCE IT.
    #
    # LMS drops a player's previous streaming socket in two places, and both
    # are gated on Slim::Player::Squeezebox - which this player deliberately is
    # not (see Player::closeStream).  So on a re-load - a seek, a skip, the
    # load at the end of a held track - the OLD connection is still in LMS's
    # write-select list pulling $client->nextChunk when the new one arrives.
    # Two consumers drawing on one chunk queue each get half the bytes, and
    # what reaches HQPlayer is not a FLAC stream: LIVE 2026-08-28 a seek played
    # on for a moment and then stopped dead with an empty HQPlayer playlist and
    # LMS still reporting `play` at a frozen position.
    #
    # The arrival of a new connection is the clearest signal there is that the
    # old one is finished with, and tier 4 is never pre-queued, so there is
    # never a second one we still want.
    if ( my $old = $client->streamingsocket ) {
        if ( $old != $httpClient ) {
            main::INFOLOG && $log->is_info && $log->info(
                $client->id . ': closing the previous stream connection' );

            Slim::Web::HTTP::closeStreamingSocket($old);
        }
    }

    # AND FLUSH THE CHUNK QUEUE, OR THE NEW CONNECTION INHERITS THE OLD ONE'S
    # END-OF-STREAM MARKER.
    #
    # Slim::Player::Source::_readNextChunk signals end of stream by pushing a
    # reference to an EMPTY STRING onto $client->chunks.  Slim::Web::HTTP's
    # sendStreamingResponse reads that as "the stream is over", calls
    # forgetClient and drops the connection - having sent ZERO bytes, and
    # without logging an error, because from LMS's point of view nothing failed.
    #
    # On a seek, LMS closes the old source and opens a new one, and the old
    # source's EOF lands on the queue AFTER _stopClient has flushed it.  The
    # marker is then still sitting there when HQPlayer's new connection makes
    # its first read, so the track it has just been told to play ends before it
    # starts.  LIVE 2026-08-28, hqplayerd's own log said it exactly:
    #
    #   Playlist add URI: .../10.flac
    #   Play (-1/0)
    #   Stream buffer 262144/0      <- 256K buffer, filled ZERO
    #   Playback engine running
    #   Stop request (tail)         <- immediate end of stream
    #
    # LMS's source was healthy throughout - reading the player stream directly
    # at that moment returned 49MB in four seconds.  Nothing was wrong with the
    # audio; the new connection was simply handed the previous one's full stop.
    #
    # Flushing here is safe: nothing has read a chunk for the new song yet, so
    # anything on the queue belongs to the stream this connection replaces.
    @{ $client->chunks } = ();

    # This is the whole handover, and it is what /stream.mp3 does internally.
    # %peerclient is how addStreamingResponse finds the player to attach the
    # socket to; without it the connection is adopted as an orphan and closed
    # on the first pass through sendStreamingResponse.
    $Slim::Web::HTTP::peerclient{$httpClient} = $client->id;

    # An audio stream is not a keep-alive candidate: it ends when the track
    # does.  Leaving the timer armed would close the socket mid-track.
    delete $Slim::Web::HTTP::keepAlives{$httpClient};
    Slim::Utils::Timers::killTimers( $httpClient, \&Slim::Web::HTTP::closeHTTPSocket );

    # A SEEKED FLAC STREAM ARRIVES WITH NO CONTAINER HEADER.  Put one back.
    my $prelude = _flacPrelude($client);

    my $headers = Slim::Web::HTTP::_stringifyHeaders($response) . CRLF . $prelude;

    # Shoutcast metadata is off (no icy-metaint header went out), but
    # sendStreamingResponse still counts bytes against this, and it counts the
    # headers too - hence the negative start. Same as the /stream.mp3 path.
    $Slim::Web::HTTP::metaDataBytes{$httpClient} = -length($headers);

    Slim::Web::HTTP::addStreamingResponse( $httpClient, $headers );

    return;
}

# A SEEKED FLAC STREAM HAS NO `fLaC` HEADER, AND HQPLAYER CANNOT PLAY WHAT IT
# CANNOT IDENTIFY.
#
# On a seek LMS re-opens the source at a byte offset, so the stream starts in
# the middle of the FLAC container: no `fLaC` marker, no STREAMINFO.  A real
# Squeezebox does not care - it is told the format out of band, in the strm
# command, and its decoder syncs to the next frame header.  HQPlayer has no
# such channel: it sniffs the stream, and headerless FLAC is unidentifiable.
#
# VERIFIED LIVE 2026-08-28.  With nothing else reading the stream, a seeked
# Qobuz track began `b1 37 88 a8` with no `fLaC` anywhere in the first 64K.
# hqplayerd's own log shows the consequence, next to a healthy start:
#
#   good start:  Stream buffer 2880000/393216   <- format known, prefill sized
#   after seek:  Stream buffer  262144/0        <- default buffer, nothing
#                Stop request (tail)
#
# LMS DOES have a mechanism for this - Song::initialAudioBlock - but
# Protocols::HTTP::request only builds it when the track has a `processor` for
# the wanted format.  A straight FLAC passthrough has none, so LMS sets
# initialAudioBlock('') and sends the frames bare.  Nothing upstream is going
# to hand us a header, so synthesise one.
#
# The values that matter are the sample rate, channel count and bit depth,
# which LMS knows from the track.  Total samples 0 means "streaming, length not
# known" and a zero MD5 means "do not verify", both legal and both accepted.
#
# THE BLOCK SIZE IS NOT OPTIONAL, AND MIN MUST EQUAL MAX.  It reads like a hint
# - every frame carries its own block size - but a decoder sizes its buffers
# from the maximum, and the "unknown" encoding of 16/65535 is REFUSED.  Proven
# offline against a real FLAC, decoding 3MB of audio taken from the MIDDLE of
# the file, which is exactly what a seek delivers:
#
#   no header at all         -> refused        (this is the bug)
#   min 16    max 65535      -> refused
#   min 4096  max 16384      -> refused        (min != max is not accepted)
#   min 4096  max 4096       -> DECODES        4.8MB of PCM out
#
# So declare a fixed 4096, which is the reference encoder's default and what
# the sample files here actually use.  A stream that genuinely used another
# size still decodes: the per-frame headers carry the real value and libFLAC
# grows its buffer if it has to.
#
# A partial first frame is fine - the decoder resyncs on the next frame header.
use constant FLAC_BLOCK_SIZE => 4096;
sub _flacPrelude {
    my $client = shift;

    my $song = eval { $client->controller->songStreamController->song } or return '';

    return '' unless ( eval { $song->streamformat } || '' ) eq 'flc';

    # Only on a seek.  A stream that starts at the beginning already carries a
    # real header, and a second one would be read as corrupt audio.
    my $seek = eval { $song->seekdata };
    return '' unless $seek && ( $seek->{timeOffset} || $seek->{sourceStreamOffset} );

    my $track = eval { $song->currentTrack };

    my $rate = ( eval { $track->samplerate } ) || 44100;
    my $ch   = ( eval { $track->channels }   ) || 2;
    my $bits = ( eval { $track->samplesize } ) || 16;

    # STREAMINFO packs four fields across 8 bytes with no byte alignment:
    # 20 bits rate, 3 bits channels-1, 5 bits depth-1, then 36 bits of total
    # samples.  Split over two 32-bit words to stay off 64-bit integers.
    my $hi = ( $rate << 12 ) | ( ( $ch - 1 ) << 9 ) | ( ( $bits - 1 ) << 4 );

    my $streaminfo =
          pack( 'n', FLAC_BLOCK_SIZE )   # min block size - must equal the max
        . pack( 'n', FLAC_BLOCK_SIZE )   # max block size - decoders size buffers from this
        . "\0\0\0"                       # min frame size - unknown
        . "\0\0\0"                       # max frame size - unknown
        . pack( 'N2', $hi, 0 )           # rate / channels / depth, total samples 0
        . ( "\0" x 16 );                 # MD5 of the unencoded audio - unknown

    main::INFOLOG && $log->is_info && $log->info( $client->id
        . ": seeked stream - prepending a FLAC header (${rate}Hz ${bits}bit ${ch}ch)" );

    # 'fLaC', then a metadata block header: 0x80 = last block, type 0
    # (STREAMINFO), followed by its 24-bit length.
    return 'fLaC' . pack( 'C', 0x80 ) . pack( 'C3', 0, 0, 34 ) . $streaminfo;
}

# Reverse of tokenFor.  Scanning the client list rather than keeping a map
# means there is no registry to get out of step with the players that exist.
sub _clientFor {
    my $token = shift;

    for my $client ( Slim::Player::Client::clients() ) {
        return $client if __PACKAGE__->tokenFor( $client->id ) eq $token;
    }

    return undef;
}

# What LMS has actually decided to stream, which is not necessarily what
# formats() asked for: the source format, the transcode table and the bitrate
# cap all get a say. Reading it here rather than at mint time means the header
# is right even if that decision changed after the url was handed over.
sub _contentType {
    my $client = shift;

    my $type = eval {
        my $sc   = $client->controller->songStreamController or return;
        my $song = $sc->song                                 or return;
        my $fmt  = $song->streamformat                       or return;

        return $Slim::Music::Info::types{$fmt};
    };

    if ( !$type ) {
        main::INFOLOG && $log->is_info && $log->info(
            $client->id . ': no stream format yet, falling back to ' . FALLBACK_TYPE );

        return FALLBACK_TYPE;
    }

    return $type;
}

sub _fail {
    my ( $httpClient, $response, $code, $text ) = @_;

    $response->code($code);
    $response->content_type('text/plain');
    $response->header( Connection => 'close' );

    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$text );

    return;
}

1;
