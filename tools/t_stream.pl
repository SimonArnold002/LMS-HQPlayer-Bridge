# Regression tests for the tier 4 audio endpoint.
#
# The route maps a unique URL to the one player stream LMS owns. Keep the
# generated URL canonical and path-only even though HQPlayer supports query
# strings: this endpoint needs no parameters and its path is its identity.
#
# The rest guards the socket handover, which reaches into Slim::Web::HTTP's
# package variables. Those are `our` in LMS 9.1 and that is what makes this
# possible at all; the stub reproduces the same names so a rename shows up as a
# failure here rather than as silence on the endpoint.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Stream;
use Slim::Player::Client;
use Slim::Web::HTTP;
use Slim::Web::Pages;

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# see the note on ok() in t_player.pl - a failed match returns the EMPTY LIST
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

my $S = 'Plugins::HQPlayerBridge::Stream';

# ---------------------------------------------------------------------------
# Fakes: enough of a socket and an HTTP::Response to drive the handler.
# ---------------------------------------------------------------------------
{
    package FakeSocket;
    sub new { bless { up => 1 }, shift }
    sub connected { $_[0]->{up} }

    package FakeRequest;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub method { $_[0]->{method} }
    sub path   { $_[0]->{path} }

    # uri() is both a getter (returning something with ->path) and a setter -
    # the tier 3 handler rewrites it to the canonical /music/<id>/download.<ext>
    sub uri { my $s = shift; if (@_) { $s->{path} = shift } return $s }

    # The whole of the tier 3 fix turns on this: downloadMusicFile chunks for
    # HTTP/1.1 and does not for anything else.  Defaults to 1.1, which is what
    # HQPlayer actually asks with.
    sub protocol { my $s = shift; $s->{protocol} = shift if @_; $s->{protocol} // 'HTTP/1.1' }

    package FakeResponse;
    sub new { my ($c,$req)=@_; bless { req=>$req, h=>{} }, $c }
    sub request      { $_[0]->{req} }
    sub code         { my $s=shift; $s->{code}=shift if @_; $s->{code} }
    sub content_type { my $s=shift; $s->{ct}=shift if @_; $s->{ct} }
    sub header       { my ($s,$k,$v)=@_; $s->{h}{$k}=$v if defined $v; $s->{h}{$k} }
    sub headers_as_string {
        my ($s,$eol)=@_; $eol //= "\015\012";
        return join '', map { "$_: $s->{h}{$_}$eol" } sort keys %{$s->{h}};
    }

    # A song whose stream format is under test control - undef stands for LMS
    # not having decided yet, which is a real state early in a load.
    package FakeSong;
    sub new { bless { fmt => $_[1] }, $_[0] }
    sub streamformat { $_[0]->{fmt} }

    package FakeStreamController;
    sub new { bless { song => $_[1] }, $_[0] }
    sub song { $_[0]->{song} }

    package FakeController;
    sub new { bless { sc => $_[1] }, $_[0] }
    sub songStreamController { $_[0]->{sc} }
}

sub call {
    my ( $method, $path ) = @_;
    Slim::Web::HTTP::_reset();
    my $sock = FakeSocket->new;
    my $res  = FakeResponse->new( FakeRequest->new( method => $method, path => $path ) );
    # Dispatch the way LMS's two registered raw functions do, on the path.
    if ( $path =~ m{^/hqp3/} ) {
        Plugins::HQPlayerBridge::Stream::_downloadHandler( $sock, $res );
    }
    else {
        Plugins::HQPlayerBridge::Stream::_handler( $sock, $res );
    }
    return ( $sock, $res );
}

Slim::Player::Client::_resetRegistry();

my $client = Slim::Player::Client->new('02:ab:88:42:4c:69');
$client->controller( FakeController->new( FakeStreamController->new( FakeSong->new('flc') ) ) );

# ---------------------------------------------------------------------------
print "-- registration --\n";
# ---------------------------------------------------------------------------
Slim::Web::Pages::_reset();
$S->init;

ok( Slim::Web::Pages->getRawFunction('/hqp/02-ab-88-42-4c-69/1.flac'),
    'the endpoint claims its own paths' );
ok( !Slim::Web::Pages->getRawFunction('/stream.mp3'),
    'and does not claim the LMS player stream' );
ok( !Slim::Web::Pages->getRawFunction('/music/458773/download.flac'),
    'nor the download route tiers 1 and 3 use' );

# ---------------------------------------------------------------------------
print "-- minting a url --\n";
# ---------------------------------------------------------------------------
my $base = 'http://lms:9000';
my $u1 = $S->urlFor( $client, $base, FakeSong->new('flc') );
my $u2 = $S->urlFor( $client, $base, FakeSong->new('flc') );

# No parameters are needed: the player and sequence both live in the path.
ok( index( $u1, '?' ) == -1, 'the url is canonical and path-only' );
ok( index( $u1, '&' ) == -1, 'and no stray separator either' );
ok( scalar( $u1 =~ m{^\Qhttp://lms:9000/hqp/\E} ), 'it is under the endpoint prefix' );
ok( $u1 ne $u2, 'every track gets a url of its own, so HQPlayer cannot mistake it for the one it holds' );
ok( scalar( $u1 =~ m{/02-ab-88-42-4c-69/} ), 'the player id rides in the path with the colons taken out' );
is( $S->tokenFor('02:ab:88:42:4c:69'), '02-ab-88-42-4c-69', 'tokenFor mangles colons' );

is( ( $S->urlFor( $client, $base, FakeSong->new('mp3') ) =~ m{\.(\w+)$} )[0], 'mp3',
    'the extension follows the stream format' );
is( ( $S->urlFor( $client, $base, FakeSong->new(undef) ) =~ m{\.(\w+)$} )[0], 'flac',
    'and falls back to flac when LMS has not decided yet' );

# ---------------------------------------------------------------------------
print "-- HEAD: answered, but NOT handed to the streaming machinery --\n";
# ---------------------------------------------------------------------------
# HQPlayer HEADs before it GETs. Attaching the player's stream to the HEAD
# would pour the track into a connection about to be closed and leave the real
# GET with nothing.
my ( $sock, $res ) = call( 'HEAD', '/hqp/02-ab-88-42-4c-69/1.flac' );

is( scalar @Slim::Web::HTTP::SENT, '1', 'the HEAD gets an ordinary response' );
is( scalar @Slim::Web::HTTP::STREAMS, '0', 'and the socket is NOT handed over' );
is( $Slim::Web::HTTP::SENT[0]{code}, '200', 'answered 200' );
is( $Slim::Web::HTTP::SENT[0]{type}, 'audio/x-flac', 'with the type LMS is actually streaming' );
is( $Slim::Web::HTTP::SENT[0]{body}, '', 'and no body' );
is( $Slim::Web::HTTP::SENT[0]{head}->header('Accept-Ranges'), 'none',
    'range support is declined rather than left to be discovered' );

# ---------------------------------------------------------------------------
print "-- GET: the handover --\n";
# ---------------------------------------------------------------------------
( $sock, $res ) = call( 'GET', '/hqp/02-ab-88-42-4c-69/1.flac' );

is( scalar @Slim::Web::HTTP::STREAMS, '1', 'the socket goes to the streaming machinery' );
is( scalar @Slim::Web::HTTP::SENT, '0', 'and not out as an ordinary response' );

# Without this addStreamingResponse cannot find the player, adopts the
# connection as an orphan, and closes it on the first pass.
is( $Slim::Web::HTTP::peerclient{$sock}, '02:ab:88:42:4c:69',
    'the socket is mapped to the player - the whole handover turns on this' );

ok( !exists $Slim::Web::HTTP::keepAlives{$sock},
    'keep-alive is dropped - the timer would close the socket mid-track' );

ok( ( $Slim::Web::HTTP::metaDataBytes{$sock} || 0 ) < 0,
    'the metadata byte count starts negative, covering the headers' );

ok( scalar( $Slim::Web::HTTP::STREAMS[0]{headers} =~ /^HTTP\/1\.1 200/ ),
    'the headers are written ahead of the audio' );
ok( scalar( $Slim::Web::HTTP::STREAMS[0]{headers} =~ /\015\012\015\012\z/ ),
    'and terminated with a blank line, or HQPlayer reads the first frame as a header' );

# ---------------------------------------------------------------------------
print "-- a re-load must not leave two connections on one chunk queue --\n";
# ---------------------------------------------------------------------------
# LMS drops a player's previous streaming socket in two places and BOTH are
# gated on Slim::Player::Squeezebox, which this player is deliberately not. So
# on a seek or a skip the old connection stays in the write-select list pulling
# nextChunk, both sockets get half the bytes, and HQPlayer is handed something
# that is not a FLAC stream. Live symptom: plays for a moment, then a dead stop
# with an empty HQPlayer playlist and LMS still reporting `play`.
Slim::Web::HTTP::_reset();
my $first = FakeSocket->new;
$Slim::Web::HTTP::peerclient{$first} = $client->id;
Slim::Web::HTTP::addStreamingResponse( $first, '' );
is( "".$client->streamingsocket, "".$first, 'the first connection is attached to the player' );

my ( $second ) = call( 'GET', '/hqp/02-ab-88-42-4c-69/2.flac' );

is( scalar @Slim::Web::HTTP::CLOSED, '1', 'the previous connection is closed when a new one arrives' );
is( "".$Slim::Web::HTTP::CLOSED[0], "".$first, 'and it is the OLD socket that goes, not the new one' );
is( "".$client->streamingsocket, "".$second, 'the player ends up on the new connection' );

# THE STALE END-OF-STREAM MARKER. This is the one that cost an afternoon.
#
# Slim::Player::Source::_readNextChunk signals end of stream by pushing a ref
# to an EMPTY STRING onto $client->chunks, and sendStreamingResponse reads that
# as "stream over": forgetClient, connection dropped, ZERO bytes sent, and no
# error logged because from LMS's side nothing failed. On a seek the old
# source's EOF lands on the queue AFTER _stopClient has flushed it, so the new
# connection inherits the previous one's full stop and the track ends before it
# starts. hqplayerd's log said `Stream buffer 262144/0` then `Stop request
# (tail)` while LMS's source was healthily serving 49MB in four seconds.
Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
my $marker = '';
@{ $client->chunks } = ( \$marker, \'left over audio' );

call( 'GET', '/hqp/02-ab-88-42-4c-69/9.flac' );

is( scalar @{ $client->chunks }, '0',
    'the chunk queue is flushed, so the new connection cannot inherit an end-of-stream marker' );

# ...and with no previous connection there is nothing to close
Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
my ( $only ) = call( 'GET', '/hqp/02-ab-88-42-4c-69/3.flac' );
is( scalar @Slim::Web::HTTP::CLOSED, '0', 'nothing is closed when there was no previous connection' );

# ---------------------------------------------------------------------------
print "-- content type follows LMS, not the filename --\n";
# ---------------------------------------------------------------------------
# HQPlayer picks its decoder by Content-Type and ignores the extension, so this
# has to be right even when the two disagree.
$client->controller( FakeController->new( FakeStreamController->new( FakeSong->new('mp3') ) ) );
call( 'HEAD', '/hqp/02-ab-88-42-4c-69/7.flac' );
is( $Slim::Web::HTTP::SENT[0]{type}, 'audio/mpeg',
    'a .flac path still reports mpeg when that is what LMS is sending' );

$client->controller( FakeController->new(undef) );
call( 'HEAD', '/hqp/02-ab-88-42-4c-69/8.flac' );
is( $Slim::Web::HTTP::SENT[0]{type}, 'audio/x-flac',
    'no source open yet falls back to flac rather than answering nothing' );

$client->controller( FakeController->new( FakeStreamController->new( FakeSong->new('flc') ) ) );

# ---------------------------------------------------------------------------
print "-- a seeked FLAC stream gets its container header back --\n";
# ---------------------------------------------------------------------------
# A seek re-opens the source at a byte offset, so the stream starts mid-FLAC
# with no `fLaC` marker. A Squeezebox is told the format out of band and does
# not care; HQPlayer sniffs the stream and cannot identify headerless FLAC, so
# it sizes a default buffer, fills nothing and stops. These numbers were all
# derived by decoding real audio taken from the middle of a real file - see
# _flacPrelude - so do not "tidy" them.
{
    package SeekSong;
    sub new { my ($c,%a)=@_; bless {%a}, $c }
    sub streamformat { $_[0]->{fmt} }
    sub seekdata     { $_[0]->{seek} }
    sub currentTrack { $_[0] }
    sub samplerate   { $_[0]->{rate} }
    sub channels     { $_[0]->{ch} }
    sub samplesize   { $_[0]->{bits} }
}

# A PASSTHROUGH seek sets BOTH offsets - Protocols::HTTP::getSeekData computes
# `sourceStreamOffset => $offset + audio_offset` alongside the time - and the
# byte one is what re-opens the source mid-container, losing the header.
my $seeked = SeekSong->new( fmt=>'flc', rate=>96000, ch=>2, bits=>24,
                            seek=>{ timeOffset=>90, sourceStreamOffset=>123456 } );
$client->controller( FakeController->new( FakeStreamController->new($seeked) ) );

Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
call( 'GET', '/hqp/02-ab-88-42-4c-69/11.flac' );

my $q = $Slim::Web::HTTP::STREAMS[0]{headers};
my ($body) = $q =~ /\015\012\015\012(.*)\z/s;

is( length($body), '42', 'a 42-byte FLAC header is written ahead of the audio' );
is( substr($body,0,4), 'fLaC', 'it starts with the stream marker' );
is( unpack('C', substr($body,4,1)), '128', 'STREAMINFO is flagged as the last metadata block' );
is( unpack('N', "\0" . substr($body,5,3)), '34', 'and declared as 34 bytes' );

my ($minb, $maxb) = unpack('nn', substr($body,8,4));
is( $minb, '4096', 'min block size is 4096' );
# min != max is REFUSED by a real decoder, as is the 16/65535 "unknown" form
is( $maxb, $minb, 'and max block size EQUALS it - a decoder refuses the stream otherwise' );

my ($hi, $lo) = unpack('NN', substr($body,18,8));
is( $hi >> 12, '96000', 'the sample rate is carried through from the track' );
is( ( ($hi >> 9) & 7 ) + 1, '2', 'the channel count too' );
is( ( ($hi >> 4) & 0x1f ) + 1, '24', 'and the bit depth' );
is( ( ( $hi & 0xF ) << 32 ) | $lo, '0', 'total samples 0 - the length is not known on a stream' );

# ...but ONLY on a seek. A stream that starts at the beginning already carries
# a real header, and a second one is read as corrupt audio.
$client->controller( FakeController->new( FakeStreamController->new(
    SeekSong->new( fmt=>'flc', seek=>undef, rate=>96000, ch=>2, bits=>24 ) ) ) );
Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
call( 'GET', '/hqp/02-ab-88-42-4c-69/12.flac' );
ok( scalar( $Slim::Web::HTTP::STREAMS[0]{headers} !~ /fLaC/ ),
    'an unseeked stream is left alone - it has a real header already' );

# AND NOT ON A TIME-ONLY SEEK, WHICH IS THE OTHER HALF OF "seeked".
# `timeOffset` alone means a transcoder or a protocol handler started at that
# time and encoded the audio FRESH - so it arrives as a complete container and a
# second header is read as corrupt audio. BBC Sounds is exactly this: its
# getSeekData answers `{ timeOffset => $newtime }` and nothing else, and LMS
# opens a live station at the live edge, so this fired on every ordinary play.
$client->controller( FakeController->new( FakeStreamController->new(
    SeekSong->new( fmt=>'flc', seek=>{ timeOffset=>10281 }, rate=>48000, ch=>2, bits=>16 ) ) ) );
Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
call( 'GET', '/hqp/02-ab-88-42-4c-69/14.flac' );
ok( scalar( $Slim::Web::HTTP::STREAMS[0]{headers} !~ /fLaC/ ),
    'a TIME-only seek gets nothing - the audio was encoded fresh and has its own header' );

# nor on a format that does not need one
$client->controller( FakeController->new( FakeStreamController->new(
    SeekSong->new( fmt=>'mp3', seek=>{ timeOffset=>90 }, rate=>44100, ch=>2, bits=>16 ) ) ) );
Slim::Web::HTTP::_reset();
$client->streamingsocket(undef);
call( 'GET', '/hqp/02-ab-88-42-4c-69/13.flac' );
ok( scalar( $Slim::Web::HTTP::STREAMS[0]{headers} !~ /fLaC/ ),
    'a seeked MP3 gets nothing - MP3 frames are self-describing' );

$client->controller( FakeController->new( FakeStreamController->new( FakeSong->new('flc') ) ) );

# ---------------------------------------------------------------------------
print "-- requests that are not ours --\n";
# ---------------------------------------------------------------------------
call( 'GET', '/hqp/de-ad-be-ef-00-01/1.flac' );
is( $Slim::Web::HTTP::SENT[0]{code}, '404', 'an unknown player is a 404' );
is( scalar @Slim::Web::HTTP::STREAMS, '0', 'and nothing is attached to a player' );

call( 'POST', '/hqp/02-ab-88-42-4c-69/1.flac' );
is( $Slim::Web::HTTP::SENT[0]{code}, '405', 'a method that is not GET or HEAD is refused' );
is( scalar @Slim::Web::HTTP::STREAMS, '0', 'and does not take the socket' );

Slim::Web::HTTP::_reset();
my $dead = FakeSocket->new; $dead->{up} = 0;
Plugins::HQPlayerBridge::Stream::_handler( $dead, FakeResponse->new( FakeRequest->new( method=>'GET', path=>'/hqp/02-ab-88-42-4c-69/1.flac' ) ) );
is( scalar @Slim::Web::HTTP::STREAMS, '0', 'a socket that has already gone is left alone' );
is( scalar @Slim::Web::HTTP::SENT, '0', 'and not written to' );

# ---------------------------------------------------------------------------
print "-- tier 3: the unchunked download route --\n";
# ---------------------------------------------------------------------------
# A local file HQPlayer cannot decode has to be transcoded, and LMS already
# does that correctly at /music/<id>/download.<ext>.  The ONLY thing wrong with
# it is the framing: downloadMusicFile chunks for an HTTP/1.1 client, and
# HQPlayer does not de-chunk.  So say HTTP/1.0 on the request's behalf and let
# LMS do the rest.
is( Plugins::HQPlayerBridge::Stream->downloadUrlFor( 'http://s:9000', 303, 'flac' ),
    'http://s:9000/hqp3/303/download.flac', 'the tier 3 url is path-only and carries download.<ext>' );

ok( scalar( Plugins::HQPlayerBridge::Stream->downloadUrlFor( 'http://s:9000', 303, 'flac' ) !~ /\?/ ),
    'and needs no query string' );

is( Plugins::HQPlayerBridge::Stream->downloadUrlFor( 'http://s:9000', 303 ),
    'http://s:9000/hqp3/303/download.flac', 'the extension defaults to flac' );

Slim::Web::HTTP::_reset();
call( 'GET', '/hqp3/303/download.flac' );
is( scalar @Slim::Web::HTTP::DOWNLOADS, '1', 'a tier 3 request is delegated to downloadMusicFile' );
is( $Slim::Web::HTTP::DOWNLOADS[0]{id}, '303', 'with the track id out of the path' );
is( $Slim::Web::HTTP::DOWNLOADS[0]{protocol}, 'HTTP/1.0',
    'AND THE REQUEST DECLARED HTTP/1.0 - this is the whole fix, it stops LMS chunking' );
is( $Slim::Web::HTTP::DOWNLOADS[0]{uri}, '/music/303/download.flac',
    'the uri is rewritten to the canonical route downloadMusicFile parses' );
is( scalar @Slim::Web::HTTP::STREAMS, '0',
    'and NOTHING is attached to the player stream - that is what makes it pre-queueable' );

# THE STATUS CODE, AND WHY THIS ASSERTION EXISTS.
#
# A raw function is handed an "almost unmodified" response object - LMS's own
# dispatcher comment is "$rawFunc shall call addHTTPResponse", and it means all
# of it, the code included. downloadMusicFile sets one only on its ERROR paths
# (406, 400), so a SUCCESSFUL tier 3 download went out as:
#
#   HTTP/1.1        <- sprintf("%s %s %s", protocol, code, message), code empty
#
# HQPlayer parses the code out of that and gets an empty string:
#
#   clPlaylist::AddURI(".../hqp3/470893/download.flac"):
#     clStreamReaderHTTP::clStreamReaderHTTP(): clString::ToUInt(): not an integer ''
#
# So EVERY m4a/ALAC/AAC track failed to play from 0.2.32 until 2026-08-30. It
# went unnoticed because _handler and _fail both set a code - tier 4 and the
# 404s worked - and because this suite stubs downloadMusicFile and never sees a
# socket, so nothing here was looking at the response object itself.
{
    my ( undef, $res ) = call( 'GET', '/hqp3/303/download.flac' );
    is( $res->code, '200',
        'the tier 3 download sets a status code itself - LMS does not do it for a raw function' );
}

# a HEAD is HQPlayer's first request for every item, and downloadMusicFile
# handles it itself
Slim::Web::HTTP::_reset();
call( 'HEAD', '/hqp3/303/download.flac' );
is( scalar @Slim::Web::HTTP::DOWNLOADS, '1', 'a HEAD is delegated too - HQPlayer HEADs before it GETs' );

Slim::Web::HTTP::_reset();
call( 'GET', '/hqp3/notanumber/download.flac' );
is( $Slim::Web::HTTP::SENT[0]{code}, '404', 'a malformed tier 3 path is a 404' );
is( scalar @Slim::Web::HTTP::DOWNLOADS, '0', 'and is not delegated' );

Slim::Web::HTTP::_reset();
$Slim::Web::HTTP::NOT_LOCAL{999} = 1;
call( 'GET', '/hqp3/999/download.flac' );
is( $Slim::Web::HTTP::SENT[0]{code}, '404',
    'a track downloadMusicFile will not serve still gets a response - it writes nothing on a false return' );
delete $Slim::Web::HTTP::NOT_LOCAL{999};

printf "\n%d passed, %d failed\n", $pass, $fail;
exit( $fail ? 1 : 0 );
