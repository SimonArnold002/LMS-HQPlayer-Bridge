use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Control;
my $C = 'Plugins::HQPlayerBridge::Control';
my $ex = \&Plugins::HQPlayerBridge::Control::_extractMessage;
my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }

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
my $realbuf = $real;
is(defined $ex->(\$realbuf) ? 'complete':'partial','complete','real Status frames as complete');

# min/sec fallback for position
my $ms = $C->can('parseAttrs')->('<Status state="2" min="2" sec="33"/>');
is(($ms->{min}*60)+$ms->{sec},'153','min/sec pair reassembles to seconds');

# unknown command reply must read as an error, and must frame cleanly
my $err = '<?xml version="1.0" encoding="utf-8"?><GetVolume result="Error">Unknown command</GetVolume>';
my $errbuf = $err;
is(defined $ex->(\$errbuf) ? 'complete':'partial','complete','error reply frames (close tag)');
is($C->can('parseAttrs')->($err)->{result},'Error','error reply result=Error');

my $gt = $C->can('parseAttrs')->('<?xml version="1.0" encoding="utf-8"?><GetTransport arg="" value="240"/>');
is($gt->{value},'240','GetTransport is a numeric id, not a device name');

# ---------------------------------------------------------------------------
# %BENIGN - the one error HQPlayer answers that is NOT a failure.
#
# With an empty playlist every <Volume> comes back result="Error" carrying
# `clPlaylist::GetAlbumGain(): trackn > last` - HQPlayer recomputing replaygain
# over a playlist with no tracks. The level IS applied (ledger 2026-08-27), so
# it is logged at debug rather than crying wolf.
#
# IT NEVER WORKED, AND NOTHING TESTED IT. `_dispatch` pulled the message with
# `/>([^<]*)</`, and because every reply carries the XML declaration that `*`
# matched the EMPTY string between `?>` and `<Volume`. $msg was "" for EVERY
# error on the wire, so the %BENIGN lookup could never match and the raw frame
# was printed in its place. Found live 2026-09-26, off a real reconnect.
print "-- a benign error is logged at debug, not warn --\n";
{
    my (@warned, @debugged);
    no warnings qw(redefine once);
    local *Slim::Utils::Log::Obj::warn  = sub { push @warned,    $_[1] };
    local *Slim::Utils::Log::Obj::debug = sub { push @debugged,  $_[1] };
    Slim::Utils::Timers::_reset();

    my $c = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $c->{connected} = 1;

    # THE EXACT FRAME OFF THE WIRE, declaration and all - including the `>`
    # inside the message text, which `[^<]` has to span.
    my $benign = '<?xml version="1.0" encoding="utf-8"?>'
               . '<Volume result="Error">clPlaylist::GetAlbumGain(): trackn > last</Volume>';

    $c->{inflight} = { verb => 'Volume', cmd => '<Volume value="-45"/>' };
    $c->_dispatch($benign);

    is(scalar @warned, 0, 'the empty-playlist <Volume> error does NOT warn');
    is(scalar @debugged >= 1 ? 1 : 0, 1, 'it is logged at debug instead');
    is(( grep { /trackn > last/ } @debugged ) ? 1 : 0, 1,
       'and the MESSAGE is logged, not the raw frame - `>` in the text survives');

    # CONTROL: a real failure on the same verb still warns.
    @warned = ();
    $c->{inflight} = { verb => 'Volume', cmd => '<Volume value="-45"/>' };
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?>'
                . '<Volume result="Error">Unknown command</Volume>');
    is(scalar @warned, 1, 'CONTROL: any OTHER <Volume> error still warns');

    # CONTROL: the benign text on a DIFFERENT verb is not excused - %BENIGN is
    # keyed on the verb, and only Volume is listed.
    @warned = ();
    $c->{inflight} = { verb => 'Play', cmd => '<Play/>' };
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?>'
                . '<Play result="Error">clPlaylist::GetAlbumGain(): trackn > last</Play>');
    is(scalar @warned, 1, 'CONTROL: the same text on <Play> is NOT downgraded');

    # CONTROL: an error with no message at all still reports the raw frame.
    @warned = ();
    $c->{inflight} = { verb => 'Play', cmd => '<Play/>' };
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?><Play result="Error"></Play>');
    is(scalar @warned, 1, 'CONTROL: an empty error message still warns');
    is(( grep { /result="Error"/ } @warned ) ? 1 : 0, 1,
       'and falls back to the raw frame, having no message to show');

    Slim::Utils::Timers::_reset();
}

print "-- _extractMessage (framing a pushed Status stream) --\n";
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

print "-- onProven: once per link, at HQPlayer's FIRST reply --\n";
{
    my $n = 0;
    my $c = Plugins::HQPlayerBridge::Control->new(
        ip => '10.0.0.5', name => 'T', onProven => sub { $n++ } );
    $c->{connected} = 1;    # the accept alone
    is($c->proven ? 1 : 0, 0, 'an accepted link is not proven');
    is($n, 0, 'and onProven has not fired');
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?><GetInfo name="T"/>');
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?><GetInfo name="T"/>');
    is($c->proven ? 1 : 0, 1, 'a reply proves it');
    is($n, 1, 'onProven fires exactly once for two replies');
    $c->{closing} = 1;
    $c->_dropLink('test');
    is($c->proven ? 1 : 0, 0, 'a dropped link is unproven again');
}

print "-- onState(0) says whether the dropped link had been PROVEN --\n";
{
    my @got;
    my $c = Plugins::HQPlayerBridge::Control->new(
        ip => '10.0.0.5', name => 'T', onState => sub { push @got, $_[2] ? 1 : 0 } );
    $c->{closing}   = 1;
    $c->{connected} = 1;
    $c->_dropLink('accept then drop');
    $c->{connected} = 1;
    $c->{proven}    = 1;
    $c->_dropLink('after a reply');
    is(join(',', @got), '0,1', 'an unanswered accept reports 0, a replied link reports 1');
}

print "-- send on a DOWN link fails the command and does NOT connect --\n";
{
    # It used to connect at once, skipping the reconnect backoff for every
    # command LMS sends a disconnected player, and from inside _dropLink when
    # a link-down listener sent something. The reconnect is already scheduled;
    # send must leave it to that.
    my @connects;
    no warnings qw(redefine once);
    local *Plugins::HQPlayerBridge::Control::connect = sub { push @connects, 1 };
    Slim::Utils::Timers::_reset();

    my @got;
    my $c = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $c->send( '<Stop/>', sub { push @got, [@_] } );
    is(scalar @connects, 0, 'a command on a down link starts no connect');
    is(scalar @{ $c->{queue} }, 0, 'and is not left queued for the next link');
    is(scalar @got, 0, 'its failure is not reported inside send()');
    Slim::Utils::Timers::_fireAll();
    is(scalar @got, 1, 'but on the next turn');
    is(defined $got[0][0] ? 'success' : 'failed', 'failed', 'as a failure, the dropped-link contract');

    # the case that mattered: a listener that sends as the link drops
    @connects = ();
    my $d = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T',
        onState => sub { $_[0]->send('<Stop/>') if !$_[1] } );
    $d->{connected} = 1;
    $d->_dropLink('test');
    is(scalar @connects, 0, 'a Stop sent from the link-down callback does not reconnect ahead of the backoff');
    is(scalar( grep { $_->{cb} == \&Plugins::HQPlayerBridge::Control::_reconnect } @{ Slim::Utils::Timers::_timers() } ), 1,
       'the backoff reconnect is still the one scheduled');

    # a link being closed for good: failed too, not left waiting for ever
    @got = ();
    my $e = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $e->{closing} = 1;
    $e->send( '<Stop/>', sub { push @got, [@_] } );
    Slim::Utils::Timers::_fireAll();
    is(scalar @got, 1, 'a command on a closed link is failed, not left without a callback');

    # CONTROL: a link still CONNECTING queues the command for when it is up
    @connects = ();
    my $f = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $f->{sock} = 'pending'; $f->{connecting} = 1;
    $f->send('<Stop/>');
    is(scalar @{ $f->{queue} }, 1, 'CONTROL: a connecting link still queues the command');
    is(scalar @connects, 0, 'and starts no second connect');
    Slim::Utils::Timers::_reset();
}

print "-- up(): will send() accept a command? --\n";
{
    # Player::_queueTrack asks this instead of "does an hqControl object exist",
    # which is true straight through a drop.  It has to answer EXACTLY what
    # send() accepts: read `connected` there instead and a load arriving while a
    # reconnect is in flight is refused, though send() would have queued and
    # carried it.
    my $d = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    is($d->up, '0', 'a link with no socket is not up');

    $d->{connecting} = 1;
    is($d->up, '1', 'a link still CONNECTING is up - send() queues on it');
    is($d->connected, '0', 'though `connected` is false there - why up() is not that');

    $d->{connecting} = 0;
    $d->{sock}       = 'pending';
    is($d->up, '1', 'and an established link is up');

    # CONTROL: what up() calls down, send() really does refuse.
    $d->{sock} = undef;
    $d->send('<Stop/>');
    is(scalar @{ $d->{queue} }, '0', 'CONTROL: send() queues nothing on a link up() calls down');
    Slim::Utils::Timers::_reset();
}

print "-- reconnectNow: discovery heard it, so try now --\n";
{
    my @connects;
    no warnings qw(redefine once);
    local *Plugins::HQPlayerBridge::Control::connect = sub { push @connects, 1 };
    Slim::Utils::Timers::_reset();

    my $c = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $c->{backoff} = 60;
    $c->_scheduleReconnect;                        # the backoff timer, as after a drop
    $c->reconnectNow;
    is(scalar @connects, 1, 'a down link connects now');
    is(scalar( grep { $_->{cb} == \&Plugins::HQPlayerBridge::Control::_reconnect } @{ Slim::Utils::Timers::_timers() } ), 0,
       'and the pending backoff retry is dropped, not left to connect again');
    is($c->{backoff}, 60, 'the backoff is left where it was, so a failure waits as long as before');

    @connects = ();
    $c->{sock} = 'up';
    $c->reconnectNow;
    is(scalar @connects, 0, 'CONTROL: a link that is up is left alone');

    my $d = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $d->{closing} = 1;
    $d->reconnectNow;
    is(scalar @connects, 0, 'and a link being closed is not reopened');
    Slim::Utils::Timers::_reset();
}

print "-- ONE warning per outage, not one per retry --\n";
{
    # 401 of the bridge's 414 log lines in 6.5 hours were one instance that
    # accepts and resets, warned on every retry. Now: the first failure, then
    # quiet until HQPlayer answers again.
    my @warned;
    no warnings qw(redefine once);
    local *Slim::Utils::Log::Obj::warn = sub { push @warned, $_[1] };
    Slim::Utils::Timers::_reset();

    my $c = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    for ( 1 .. 5 ) { $c->{connected} = 1; $c->_dropLink('read: Connection reset by peer') }
    is(scalar @warned, 1, 'five accept-then-reset retries warn ONCE');
    $c->_connectTimeout for 1 .. 3;
    is(scalar @warned, 1, 'and timeouts in the same outage add nothing');

    # it answers: the outage is over
    $c->{connected} = 1;
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?><GetInfo name="T"/>');
    $c->_dropLink('HQPlayer closed the link');
    is(scalar @warned, 2, 'a link that had been ANSWERING going down always warns');
    $c->{connected} = 1; $c->_dropLink('read: Connection reset by peer');
    $c->_connectTimeout;
    is(scalar @warned, 2, 'and the retries after it are quiet - that outage is already reported');

    # CONTROL: after another recovery, a fresh outage is reported again
    $c->{connected} = 1;
    $c->_dispatch('<?xml version="1.0" encoding="utf-8"?><GetInfo name="T"/>');
    $c->{proven} = 0;                              # as a new link would start
    $c->{connected} = 1; $c->_dropLink('read: Connection reset by peer');
    is(scalar @warned, 3, 'CONTROL: a new outage after a recovery warns again');

    # CONTROL: a first failure with nothing before it still warns
    my $d = Plugins::HQPlayerBridge::Control->new( ip => '127.0.0.1', name => 'T' );
    $d->_connectTimeout;
    is(scalar @warned, 4, 'CONTROL: the very first failure is reported');
    Slim::Utils::Timers::_reset();
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
