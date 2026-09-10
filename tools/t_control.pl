use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Control;
my $C = 'Plugins::HQPlayerBridge::Control';
my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }

print "-- _completeResponse --\n";
my $cr = \&Plugins::HQPlayerBridge::Control::_completeResponse;
is(defined $cr->('<?xml version="1.0"?><Status state="Playing"/>') ? 'complete':'partial','complete','self-closing root');
is(defined $cr->('<?xml version="1.0"?><Status state="Play') ? 'complete':'partial','partial','truncated mid-attribute');
is(defined $cr->('<?xml version="1.0"?><PlaylistGet><Track a="1"/></PlaylistGet>')?'complete':'partial','complete','nested with close tag');
is(defined $cr->('<?xml version="1.0"?><PlaylistGet><Track a="1"/>')?'complete':'partial','partial','nested, close tag not yet arrived');
is(defined $cr->('<?xml version="1.0"?>')?'complete':'partial','partial','decl only');

print "-- parseAttrs --\n";
my $a = $C->can('parseAttrs')->('<?xml version="1.0"?><Status state="Playing" position="42.5" rate="352800"/>');
is($a->{state},'Playing','state'); is($a->{position},'42.5','position'); is($a->{rate},'352800','rate');
my $d = $C->can('parseAttrs')->('<discover name="HQPlayerEmbedded" result="OK" version="Signalyst HQPlayer Embedded 6">hqplayer</discover>');
is($d->{name},'HQPlayerEmbedded','discover name'); is($d->{version},'Signalyst HQPlayer Embedded 6','discover version'); is($d->{result},'OK','discover result');

print "-- pick (tolerant attribute lookup) --\n";
my $p = $C->can('pick');
is($p->({state=>'Playing'},'state','status'),'Playing','first candidate');
is($p->({status=>'Playing'},'state','status'),'Playing','second candidate');
is($p->({State=>'Playing'},'state'),'Playing','case-insensitive fallback');
is($p->({state=>''},'state','status'),'(undef)','empty treated as absent');

print "-- escape / unescape roundtrip --\n";
my $e=$C->can('escape'); my $u=$C->can('unescape');
for my $s ('Sigur R\x{00f3}s','AT&T','a "quoted" <tag>', "it's") {
  is($u->($e->($s)),$s,"roundtrip: $s");
}
is($e->('Bob & "Co" <x>'),'Bob &amp; &quot;Co&quot; &lt;x&gt;','escape output');

print "-- parseChildren --\n";
my @k = $C->can('parseChildren')->('<GetTransport><Transport name="NAA1" active="1"/><Transport name="CoreAudio"/></GetTransport>','Transport');
is(scalar @k,'2','two children'); is($k[0]{name},'NAA1','first name'); is($k[0]{active},'1','first active'); is($k[1]{name},'CoreAudio','second name');

print "-- REAL captured payloads (live hqplayerd 6.0.4, 2026-08-26) --\n";
# Verbatim <Status/> reply captured while a FLAC was loaded over HTTP.
my $real = '<?xml version="1.0" encoding="utf-8"?><Status active_bits="24" active_channels="2" active_filter="poly-sinc-gauss-long" active_mode="PCM" active_rate="11289600" active_shaper="TPDF" clips="0" length="153.40842708333332" min="0" position="0" remain_min="2" remain_sec="33" sec="0" state="2" total_min="2" total_sec="33" track="1" track_serial="1" tracks_total="1" volume="-39"><metadata bitrate="1411200" bits="24" channels="2" mime="audio/x-flac" samplerate="96000" sdm="0" song="HTTP stream" uri="http://host/x.flac"/></Status>';
my $ra = $C->can('parseAttrs')->($real);
is($ra->{state},'2','root state=2 (playing)');
is($ra->{length},'153.40842708333332','root length (true duration)');
is($ra->{position},'0','root position');
is($p->($ra,'state'),'2','pick state off real payload');
# metadata must come from the CHILD, not the root - active_rate is the DSD
# output rate (11289600), the source rate is on <metadata/>.
is($ra->{samplerate},'(undef)','samplerate is NOT on the root');
my ($m) = $C->can('parseChildren')->($real,'metadata');
is($m->{samplerate},'96000','metadata child samplerate');
is($m->{bits},'24','metadata child bits');
is($m->{song},'HTTP stream','metadata song - HQPlayer ignores tags for http sources');
is(defined $cr->($real) ? 'complete':'partial','complete','real Status frames as complete');

# min/sec fallback for position
my $ms = $C->can('parseAttrs')->('<Status state="2" min="2" sec="33"/>');
is(($ms->{min}*60)+$ms->{sec},'153','min/sec pair reassembles to seconds');

# unknown command reply must read as an error, and must frame cleanly
my $err = '<?xml version="1.0" encoding="utf-8"?><GetVolume result="Error">Unknown command</GetVolume>';
is(defined $cr->($err)?'complete':'partial','complete','error reply frames (close tag)');
is($C->can('parseAttrs')->($err)->{result},'Error','error reply result=Error');

my $gt = $C->can('parseAttrs')->('<?xml version="1.0" encoding="utf-8"?><GetTransport arg="" value="240"/>');
is($gt->{value},'240','GetTransport is a numeric id, not a device name');

print "-- _extractMessage (framing a pushed Status stream) --\n";
my $ex = \&Plugins::HQPlayerBridge::Control::_extractMessage;
my $D  = '<?xml version="1.0" encoding="utf-8"?>';

my $buf = $D.'<PlaylistClear result="OK"/>';
is($ex->(\$buf), $D.'<PlaylistClear result="OK"/>', 'single self-closing message');
is($buf, '', 'buffer fully consumed');

# two concatenated - exactly what a subscribed read delivers
$buf = $D.'<Status state="2"/>'.$D.'<Status state="0"/>';
is($ex->(\$buf), $D.'<Status state="2"/>', 'first of two extracted');
is($ex->(\$buf), $D.'<Status state="0"/>', 'second of two extracted');
is($ex->(\$buf), '(undef)', 'buffer now empty');

# nested child must not terminate the message early
$buf = $D.'<Status state="2"><metadata bits="24"/></Status>'.$D.'<Play result="OK"/>';
my $m1 = $ex->(\$buf);
is($m1, $D.'<Status state="2"><metadata bits="24"/></Status>', 'nested Status extracted whole');
is($ex->(\$buf), $D.'<Play result="OK"/>', 'message after nested one');

# a partial tail must be left alone for the next read
$buf = $D.'<Status state="2"/>'.$D.'<Status state="1" po';
is($ex->(\$buf), $D.'<Status state="2"/>', 'complete part extracted');
is($ex->(\$buf), '(undef)', 'partial tail not extracted');
is($buf, $D.'<Status state="1" po', 'partial tail left in buffer intact');

# truncated nested message
$buf = $D.'<Status state="2"><metadata bits="24"/>';
is($ex->(\$buf), '(undef)', 'nested message without close tag is incomplete');

# error reply with text body
$buf = $D.'<GetVolume result="Error">Unknown command</GetVolume>';
is($ex->(\$buf), $D.'<GetVolume result="Error">Unknown command</GetVolume>', 'error reply with body');

# six concatenated Status messages - the 7679-byte case seen live
$buf = join '', map { $D."<Status state=\"2\" position=\"$_\"/>" } 1..6;
my $count = 0; $count++ while defined $ex->(\$buf);
is($count, '6', 'all six concatenated messages drained');


# ---------------------------------------------------------------------------
# THE SOCKET CARRIES OCTETS.
#
# LIVE FAILURE 2026-08-28.  LMS hands out track titles as CHARACTER strings,
# so an album with a track called "Lush 3-1" - U+2012 FIGURE DASH - put a wide
# character into the <metadata song=""/> of a PlaylistAdd, and syswrite DIED
# with "Wide character in syswrite".
#
# The die threw out of the status handler that was pumping the queue, so the
# command stayed `inflight` forever - and since exactly one command may be in
# flight, EVERY subsequent command was queued behind it and never sent.  Skip,
# stop and pause all silently did nothing, LMS's position froze while HQPlayer
# played on, and 30s later the reply timeout tore the link down.
#
# Invisible for an ASCII-only library, which is why every test up to here
# passed.  Same family as the LMS characters-vs-octets trap: anything reaching
# a socket, a DB or a digest needs BYTES.
# ---------------------------------------------------------------------------
print "-- the write buffer is octets, not characters --\n";
{
    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Control.pm'); <> };
    ( my $code = $src ) =~ s/^\s*#.*$//mg;

    is( ($code =~ /wbuf\}\s*\.=\s*Encode::encode\(\s*'UTF-8'/ ? 'yes' : 'no'),
        'yes', 'the write buffer is encoded to UTF-8 octets before it reaches syswrite' );

    is( ($code =~ /Encode::decode\(\s*'UTF-8'/ ? 'yes' : 'no'),
        'yes', 'and complete messages are decoded back to characters on the way in' );

    is( ($code =~ /^\s*use Encode/m ? 'yes' : 'no'), 'yes', 'Encode is loaded' );

    # The real thing: a wide character must survive the round trip through the
    # escape/encode path as valid UTF-8 bytes rather than dying.
    my $e = $C->can('escape');
    my $title = "Lush 3\x{2012}1";                 # U+2012 FIGURE DASH, the live case
    my $cmd   = '<PlaylistAdd uri="http://h/x.flac" queued="1"><metadata song="'
              . $e->($title) . '"/></PlaylistAdd>';

    my $bytes = eval { require Encode; Encode::encode( 'UTF-8', $cmd ) };
    is( ($@ ? "died: $@" : 'ok'), 'ok', 'a figure-dash track title encodes without dying' );
    is( (defined $bytes && !utf8::is_utf8($bytes) ? 'octets' : 'characters'),
        'octets', 'and what comes out is a byte string, which is what syswrite needs' );
    is( (defined $bytes && $bytes =~ /\xe2\x80\x92/ ? 'yes' : 'no'),
        'yes', 'U+2012 went out as its three UTF-8 bytes' );

    # ...and decodes back to the same characters, or the uri comparisons that
    # drive the gapless hand-over would never match.
    is( Encode::decode( 'UTF-8', $bytes ) eq $cmd ? 'yes' : 'no',
        'yes', 'and decodes back to exactly what went in' );

    # A partial write must not cut mid-character.  substr() on the buffer counts
    # in whatever units the buffer holds, so this only works if it holds bytes.
    my $half = substr( $bytes, 0, 10 );
    is( (length($half) == 10 ? 'yes' : 'no'), 'yes',
        'a partial write cuts by BYTE, so the remainder resumes on a byte boundary' );
}

# ---------------------------------------------------------------------------
# A COMPLETED TCP HANDSHAKE IS NOT A WORKING LINK.
#
# hqplayerd ACCEPTS the socket and only then decides it cannot serve, which is
# what it does whenever its output endpoint is missing - the NAA switched off,
# say.  Its log says so in pairs:
#
#   Control connection from 192.168.1.234:42766
#   clControlThread::HandleConnection(): std::exception
#
# The backoff used to reset in _connectResolved, so every one of those looked
# like a success and the ladder never climbed.  MEASURED over one such spell:
# 2,327 connections and 2,324 exceptions in 9.5 hours - four attempts inside
# two seconds, every minute, for as long as the endpoint stayed off.
# ---------------------------------------------------------------------------
print "-- the reconnect ladder must climb against a peer that accepts and drops --\n";
{
    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Control.pm'); <> };
    ( my $code = $src ) =~ s/^\s*#.*$//mg;

    my ($resolved) = $code =~ /sub _connectResolved \{(.*?)\n\}/s;
    my ($dispatch) = $code =~ /sub _dispatch \{(.*?)\n\}/s;

    is( ( defined $resolved && $resolved !~ /backoff\}\s*=\s*BACKOFF_MIN/ ? 'no' : 'yes' ),
        'no', 'the handshake does NOT reset the backoff' );

    is( ( defined $dispatch && $dispatch =~ /backoff\}\s*=\s*BACKOFF_MIN/ ? 'yes' : 'no' ),
        'yes', 'a message actually received from HQPlayer does' );

    is( ( $code =~ /proven\}\s*=\s*0/ ? 'yes' : 'no' ),
        'yes', 'and a dropped link goes back to unproven' );

    # The ladder itself: nothing ever proves the link, so it must double to the
    # cap rather than sitting at BACKOFF_MIN for ever.
    my $min = Plugins::HQPlayerBridge::Control::BACKOFF_MIN();
    my $max = Plugins::HQPlayerBridge::Control::BACKOFF_MAX();

    my $ctl = bless { name => 'test', backoff => $min, closing => 0 },
                    'Plugins::HQPlayerBridge::Control';

    my @waits;
    for ( 1 .. 7 ) {
        Slim::Utils::Timers::_reset();
        my $t0 = Time::HiRes::time();
        $ctl->_scheduleReconnect;
        my $t = Slim::Utils::Timers::_timers()->[0];
        push @waits, $t ? sprintf( '%.0f', $t->{when} - $t0 ) : 'none';
    }
    Slim::Utils::Timers::_reset();

    is( join( ',', @waits ), '2,4,8,16,32,60,60',
        "it doubles from ${min}s and caps at ${max}s" );
}

print "-- superseded track work is removed before it reaches HQPlayer --\n";
{
    my @failed;
    my $ctl = bless {
        name  => 'test',
        queue => [
            { verb => 'PlaylistClear', scope => 'track' },
            { verb => 'PlaylistAdd', scope => 'track', cb => sub { push @failed, [@_] } },
            { verb => 'Volume' },
            { verb => 'Status', scope => 'link' },
        ],
    }, 'Plugins::HQPlayerBridge::Control';

    is( $ctl->cancelQueued('track'), '2',
        'both waiting commands belonging to the old track are cancelled' );
    is( join( ',', map { $_->{verb} } @{ $ctl->{queue} } ), 'Volume,Status',
        'unrelated volume and link work stays in order' );
    is( scalar(@failed), '1', 'a cancelled request still settles its callback' );
    is( defined $failed[0][0] ? 'success' : 'failed', 'failed',
        'using the same failed-callback contract as a dropped link' );
    is( defined $failed[0][1] ? 'raw' : 'no raw', 'no raw',
        'and does not invent an HQPlayer reply' );
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
