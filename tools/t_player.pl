# Regression tests for the player object itself.
#
# These exist because of a real bug: Slim::Player::Client objects are BLESSED
# ARRAYS (Slim::Utils::Accessor slots), so $client->{field} = ... is a fatal
# "Not a HASH reference".  Player.pm did exactly that in new(), which killed
# player creation on a live server - and because it ran inside a timer callback
# the only symptom was "Timer ..._roundDone failed" with the cause swallowed.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Player;

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# TRAP: ok($src =~ /re/, 'name') evaluates the match in LIST context, where a
# FAILED match returns the empty list - so @_ collapses to just the name, the
# name lands in $c as a true value, and a broken assertion prints "ok" with a
# blank label and counts as a pass.  Two assertions in this file had been dead
# that way.  Take the name off the END and treat everything left as the
# condition, so an empty list reads as false.
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

print "-- player construction --\n";
my $c = eval { Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:69', 'paddr', 1.0, undef, 12, undef) };
ok($c && !$@, "new() does not die".($@ ? " ($@)" : ""));
is(ref($c), 'Plugins::HQPlayerBridge::Player', 'correct class');
ok(ref($c) && UNIVERSAL::isa($c,'ARRAY'), 'object is a blessed ARRAY, not a hash');

print "-- accessor defaults set in new() --\n";
is($c->hqStarted, '0', 'hqStarted initialised to 0');
is($c->hqExpectStop, '0', 'hqExpectStop initialised to 0');
is($c->hqPosition, '(undef)', 'hqPosition initialised to undef');
is($c->hqLastStatus, '0', 'hqLastStatus initialised to 0');

print "-- accessors store falsy values correctly --\n";
$c->hqStarted(1); is($c->hqStarted,'1','set to 1');
$c->hqStarted(0); is($c->hqStarted,'0','set back to 0 (not swallowed as a get)');
$c->hqPosition(0); is($c->hqPosition,'0','position 0 stores');
$c->hqTier(undef); is($c->hqTier,'(undef)','undef stores');
$c->hqRate('96000'); is($c->hqRate,'96000','rate stores');

print "-- accessors do not collide across the ISA chain --\n";
$c->id('02:ab:88:42:4c:69');
$c->hqStarted(7);
is($c->id,'02:ab:88:42:4c:69','base-class slot survives subclass writes');
is($c->hqStarted,'7','subclass slot survives base-class writes');

print "-- the original bug must stay fixed --\n";
my $died = !eval { $c->{someField} = 1; 1 };
ok($died, 'writing a hash key on the client dies (as it does on a real server)');
ok(!grep({ /->\{_hqp/ } do { open my $fh,'<','../HQPlayerBridge/Player.pm'; <$fh> }),
   'Player.pm contains no $self->{_hqp...} hash-slot access');

print "-- Socket context trap must stay fixed --\n";
# sockaddr_in() switches on wantarray: in a function-call argument list it is in
# LIST context, treats its two args as a request to UNPACK one, and croaks.
# That killed player creation on a live server. Only the explicit pack_/unpack_
# forms are allowed in this codebase.
for my $f (qw(Plugin Player Control Discovery Settings)) {
    open my $fh, '<', "../HQPlayerBridge/$f.pm" or next;
    my @bad = grep { /(?<![_\w])sockaddr_in\s*\(/ && !/^\s*#/ } <$fh>;
    ok(!@bad, "$f.pm uses only pack_/unpack_sockaddr_in".(@bad ? " (found: ".join('',@bad).")" : ""));
}

print "-- DIDL-Lite metadata (the only channel that reaches HQPlayer) --\n";
{
    package FakeTrack;
    sub new { bless {%{$_[1]}}, $_[0] }
    sub title      { $_[0]->{title} }
    sub artistName { $_[0]->{artist} }
    sub albumname  { $_[0]->{album} }
    sub coverid    { $_[0]->{coverid} }
    sub id         { $_[0]->{id} }
    sub secs       { $_[0]->{secs} }
    sub content_type { $_[0]->{ct} }
    sub url        { $_[0]->{url} }
    package FakeSong;
    sub new { bless { t => $_[1] }, $_[0] }
    sub currentTrack { $_[0]->{t} }
}
my $tr = FakeTrack->new({ title=>'Colony & "Collapse"', artist=>'Johanna <Warren>',
    album=>'Gemini I', coverid=>'abc123', id=>447812, secs=>107, ct=>'flc' });
my $meta = $c->_metadata( FakeSong->new($tr) );

ok(scalar($meta =~ /^<metadata\b/) && scalar($meta =~ m{/>$}), 'metadata is a complete element');
ok(scalar($meta =~ m{\bsong="Colony &amp; &quot;Collapse&quot;"}), 'song is XML-escaped');
ok(scalar($meta =~ m{\bartist="Johanna &lt;Warren&gt;"}), 'artist is XML-escaped');
ok(scalar($meta =~ m{\balbum="Gemini I"}), 'album present');
ok(scalar($meta =~ m{\bcover="[^"]*/music/abc123/cover\.jpg"}),
   'cover points at the LMS cover - this is what lights up the endpoint');

# THE regression guard for 2026-08-28.  HQPlayer base64-encodes the cover URL
# into the playlist item's `picture` field ITSELF; handing it base64 gets that
# base64 encoded a second time and the endpoint shows nothing.  Verified live
# against engine 6.0.4: a plain URL in `cover` reproduces the DIDL path
# byte-for-byte.
ok(scalar($meta =~ m{\bcover="https?://}), 'cover is a PLAIN url - never pre-encoded');

# The field is `cover`.  picture=/albumArtURI=/art= and a <picture> child were
# all tested against the live daemon and are silently ignored.
ok(scalar($meta !~ m{\bpicture=}) && scalar($meta !~ m{albumArtURI}),
   'artwork goes in cover=, not the fields HQPlayer ignores');

# proxiedImage on a LOCAL path returns the "no artwork" placeholder, not the
# cover. That produced a blank icon on the endpoint; it must never come back.
ok(scalar($meta !~ m{/imageproxy/}), 'local cover URL is direct, NOT wrapped in the image proxy');

print "-- remote tracks (Qobuz/Tidal) take their artwork from the handler --\n";
{
    package FakeHandler;
    sub can { my ($s,$m)=@_; return $m eq 'getMetadataFor' ? sub {} : undef }
    sub getMetadataFor { return { cover => '/imageproxy/https%3A%2F%2Fstatic.qobuz.com%2Fx.jpg/image.jpg' } }
    package FakeHandlerAbs;
    sub can { my ($s,$m)=@_; return $m eq 'getMetadataFor' ? sub {} : undef }
    sub getMetadataFor { return { icon => 'https://static.qobuz.com/direct.jpg' } }
}
{
    no warnings 'redefine';
    *Slim::Music::Info::isRemoteURL = sub { $_[0] && $_[0] =~ m{^qobuz://} };
}
# a remote track has a NEGATIVE id and no coverid - the local route would build
# /music/-9454.../cover.jpg and get the placeholder back.
my $remote = FakeTrack->new({ title=>'For Life', artist=>'Jorja Smith',
    id=>-94543041325440, url=>'qobuz://445307221.flac', ct=>'flc' });

Slim::Player::ProtocolHandlers->_setTestHandler('FakeHandler');
my $rart = $c->_coverURL($remote);
ok(defined $rart && $rart =~ m{/imageproxy/}, 'remote cover comes from the protocol handler');
ok($rart !~ m{/music/-}, 'remote cover does NOT use the negative track id');

Slim::Player::ProtocolHandlers->_setTestHandler('FakeHandlerAbs');
is($c->_coverURL($remote), 'https://static.qobuz.com/direct.jpg', 'an absolute handler URL is passed through unchanged');

Slim::Player::ProtocolHandlers->_setTestHandler(undef);
is($c->_coverURL($remote), '(undef)', 'no handler artwork -> no cover attribute rather than a bad one');

# a track with nothing set must still yield a valid element, not broken XML
my $bare = FakeTrack->new({ title=>'X', id=>1, ct=>'flc' });
my $m2 = $c->_metadata( FakeSong->new($bare) );
ok(scalar($m2 =~ m{^<metadata\b}) && scalar($m2 =~ m{/>$}), 'bare track still yields a complete element');
ok(scalar($m2 !~ /\bartist=/) && scalar($m2 !~ /\balbum=/), 'absent fields are omitted, not emitted empty');
ok(scalar($m2 !~ /\bcover=""/), 'a missing cover is omitted rather than sent empty');

# HQPlayer does NOT probe an http:// item for its duration, so a bridge-added
# track showed length="0" in HQPlayer's UI - the old UPnP path only filled it in
# because DIDL carries <res duration="">.  Verified live 2026-08-28 that
# <metadata length="12.7"/> is accepted and reads back on the playlist item.
my $withLen = $c->_metadata( FakeSong->new(
    FakeTrack->new({ title=>'T', id=>7, ct=>'flc', secs=>247 }) ) );
ok(scalar($withLen =~ /\blength="247"/),
   'the metadata carries the track duration, or HQPlayer shows no length at all');

my $noLen = $c->_metadata( FakeSong->new(
    FakeTrack->new({ title=>'T', id=>7, ct=>'flc', secs=>0 }) ) );
ok(scalar($noLen !~ /\blength=/),
   'a zero duration is omitted rather than sent as length="0" - which is the bug it fixes');


# ---------------------------------------------------------------------------
# The controller state machine.  playerBufferReady routes to _WaitToSync ->
# _StartIfReady, which asks every player isBufferReady() - i.e. the client's
# own bufferReady flag, set on real hardware only by the Squeezebox STAT
# handler.  Leave it at 0 and the controller parks in WAITING_TO_SYNC, where
# Pause is _NoOp and Started is _Invalid: playback works but the transport is
# dead.  A virtual player MUST assert the flag itself.
# ---------------------------------------------------------------------------
print "-- controller handshake --\n";
my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Player.pm'); <> };
# strip comments - they name these very calls, and would match the regexes below
$src =~ s/^\s*#.*$//mg;

ok($src =~ /bufferReady\(\s*1\s*\)[^;]*;.*?playerBufferReady/s,
   'bufferReady(1) is set BEFORE playerBufferReady is signalled');
ok($src !~ /playerBufferReady.*?bufferReady\(\s*1\s*\)/s,
   'and never the other way round');

# play() splits two jobs now - start THIS track, or take the next one for a
# gapless hand-over - and the four-command load moved to _startTrack with it.
my ($playSub) = $src =~ /\nsub play \{(.*?)\n\}/s;
ok($playSub && $playSub =~ /_startTrack/,
   'play() routes an ordinary call to the full load');
ok($playSub && $playSub =~ /hqArmNext\(\s*0\s*\)/,
   'and consumes the hand-over flag on EVERY call, so a stale one cannot swallow a later play()');

my ($startSub) = $src =~ /\nsub _startTrack \{(.*?)\n\}/s;
ok($startSub && $startSub =~ /bufferReady\(\s*0\s*\)/,
   '_startTrack clears bufferReady so a stale 1 cannot start the next track early');
my ($stopSub) = $src =~ /\nsub stop \{(.*?)\n\}/s;
ok($stopSub && $stopSub =~ /bufferReady\(\s*0\s*\)/, 'stop() clears bufferReady');

# ReadyToStream in PLAYING/STREAMING is _NextIfMore: LMS answers it by
# resolving the NEXT song and calling play() again.  That was fatal while every
# play() replaced the playing track, so it used to be sent at end-of-track
# only.  It is now the first half of gapless - but it must still go through
# _armNextTrack, which is where the tier and one-at-a-time guards live.
my ($handedSub) = $src =~ /\nsub _handedOver \{(.*?)\n\}/s;
ok($handedSub && $handedSub !~ /playerEndOfStream|playerStopped/,
   'a hand-over reports Started ONLY - an end-of-stream there would reload the track being played');

my ($armSub) = $src =~ /\nsub _armNextTrack \{(.*?)\n\}/s;
ok($armSub && $armSub =~ /\$tier == 1 \|\| \$tier == 3/,
   '_armNextTrack pre-queues tiers 1 and 3 - both give each track its own url - but never tier 2');
ok($armSub && $armSub =~ /hqArmNext\(\s*1\s*\).*?playerReadyToStream/s,
   'and arms the flag BEFORE the call - LMS re-enters play() synchronously for a local track');

my ($appendSub) = $src =~ /\nsub _appendTrack \{(.*?)\n\}/s;
ok($appendSub && $appendSub !~ /<Stop\/>|<PlaylistClear\/>/,
   'the hand-over never sends Stop or PlaylistClear - either would kill the playing track');

# <PlayNextURI> is the command that LOOKS like the right primitive for this -
# it exists for exactly this and nothing else, and Signalyst's own client has
# it.  Sent over a playing playlist item on engine 6.0.4 it answered
# result="OK" and then TOOK HQPLAYERD DOWN: both 4321 and 8019 stopped
# listening and it did not restart itself.  It stays in Control.pm's %KNOWN so
# tools/probe_gapless.py can re-test it on a future engine, and it must never
# be reachable from the player.
ok($src !~ /PlayNextURI/,
   'Player.pm never sends <PlayNextURI> - it answers OK and then kills the daemon');

# Volume used to go over UPnP RenderingControl, which took 300-550ms per call,
# so it needed a debounce timer (_flushVolume) to survive LMS's 6-step pause
# ramp.  It goes over the XML control link now - ~9ms - and the ramp steps are
# dropped at source instead, so there is no debounce left to test.  These two
# assertions still named _flushVolume, and passed anyway: see the note on ok().
print "-- volume channel --\n";
my ($volSub) = $src =~ /\nsub volume \{(.*?)\n\}/s;
ok($volSub, 'volume() is overridden');
ok($volSub && $volSub !~ /setVolume/,
   'volume() does not push to UPnP - the XML channel answers in ~9ms, UPnP in 300-550ms');
ok($volSub && $volSub =~ /return \$vol if \$temp/,
   'volume() drops LMS temporary levels rather than forwarding the pause ramp');
ok($volSub && $volSub =~ /hqVolDb/,
   'volume() checks the level HQPlayer is already at, so the two directions cannot chase each other');


# ---------------------------------------------------------------------------
# The paused-buffer trap.  _CheckPaused (reached from our own
# playerStatusHeartbeat while PAUSED) stops the source stream outright when a
# paused REMOTE track sits on a buffer over 98% full - LMS bug 10645, meant to
# release a connection LMS no longer needs.  HQPlayer keeps pulling from us the
# whole time it is paused, so a full-buffer claim made pause tear the stream
# down: HQPlayer got <Stop/>, the NAA dropped, and resume came back as a
# re-stream with a seek instead of a resume.
# ---------------------------------------------------------------------------
print "-- buffer reporting --\n";
my $fullness = Plugins::HQPlayerBridge::Player::bufferFullness();
my $bufsize  = Plugins::HQPlayerBridge::Player::bufferSize();
ok($bufsize > 0, 'bufferSize is non-zero');
ok($fullness / $bufsize <= 0.98,
   sprintf('usage() is %.2f - at or below the 0.98 _CheckPaused threshold', $fullness/$bufsize));
ok($fullness > 0, 'but not zero either - a starved buffer has its own consequences');

# ---------------------------------------------------------------------------
# Seek accounting.  playingSongElapsed computes startOffset + songElapsedSeconds,
# so songElapsedSeconds must be elapsed WITHIN THE STREAM.  Tier 1 hands
# HQPlayer a file URL and seeks inside HQPlayer, so its position is absolute
# and the offset has to come back off.  Tier 2 goes through /stream.mp3, which
# LMS already opens at the offset - seeking there would skip twice.
# ---------------------------------------------------------------------------
print "-- seek accounting --\n";
is($c->hqSeekOffset, '0', 'hqSeekOffset initialised to 0');

$c->hqPosition(42); $c->hqSeekOffset(0);
is($c->songElapsedSeconds, '42', 'no seek: position passes through');

$c->hqPosition(52); $c->hqSeekOffset(10);
is($c->songElapsedSeconds, '42', 'after a tier-1 seek the offset is subtracted, not added twice');

$c->hqPosition(3); $c->hqSeekOffset(10);
is($c->songElapsedSeconds, '0', 'a position behind the seek point clamps at zero, never negative');

my ($queueSub) = $src =~ /\nsub _queueTrack \{(.*?)\n\}/s;
ok($queueSub && $queueSub =~ /hqTier[^;]*==\s*1[^;]*\{[^}]*Seek/s,
   'Seek is sent on tier 1 only - tier 2 bytes already start at the offset');
ok($queueSub && $queueSub =~ /hqSeekOffset\(/,
   'and the offset we asked HQPlayer to skip is recorded');


# ---------------------------------------------------------------------------
# Two-way transport.  Pausing at HQPlayer or on the endpoint's own remote has
# to pull LMS with it, without the follow-up echoing back out as a command.
#
# The comparison is against hqWanted - the last state WE asked HQPlayer for -
# never against the controller's state.  _Pause sets PAUSED about 300ms before
# it calls pause() on us (it fades the volume first), so a status push landing
# in that window would read as an external resume and un-pause the player.
# ---------------------------------------------------------------------------
print "-- two-way transport --\n";
{
    package FakeController;
    sub new { bless { paused => 0, calls => [] }, shift }
    sub isPaused { $_[0]->{paused} }
    sub pause    { push @{$_[0]->{calls}}, 'pause';  $_[0]->{paused} = 1 }
    sub resume   { push @{$_[0]->{calls}}, 'resume'; $_[0]->{paused} = 0 }
    sub playerStatusHeartbeat {}
    sub playerTrackStarted    {}
    sub playerEndOfStream     {}
    sub playerReadyToStream   {}
    sub playerStopped         {}
}

my @sent;
# Loading a track is now two commands on the control socket, each with a
# callback, so the mock has to hold the callbacks for the test to answer -
# @sentCb is the reply the daemon has not sent yet.
my @sentCb;
# TRAP THIS MOCK ONCE HID: Control::send's callback contract is ($attrs, $raw).
# $raw is the RAW REPLY on success as well as on failure - it is never an error
# string - and failure is $attrs being undef.  This mock used to pass '' as the
# second argument, so a callback that read it as ($res, $err) and tested $err
# passed every test here and then reported every SUCCESSFUL PlaylistAdd as
# "HQPlayer would not accept the track URI" on the live daemon, one
# PROBLEM_OPENING per track, playing nothing.  Answer the way Control.pm does.
sub _answer {           # answer the oldest outstanding command, OK unless told
    my $ok = @_ ? shift : 1;
    my $cb = shift @sentCb or return 0;
    my $raw = '<?xml version="1.0" encoding="utf-8"?><PlaylistAdd result="'
            . ( $ok ? 'OK' : 'Error' ) . '"/>';
    $cb->( $ok ? { result => 'OK' } : undef, $raw );
    return 1;
}
{
    no warnings 'redefine';
    *Plugins::HQPlayerBridge::Player::_send      = sub {
        push @sent, $_[1];
        push @sentCb, $_[2] if $_[2];
        return;
    };
    *Plugins::HQPlayerBridge::Player::_startPolling = sub {};
    *Plugins::HQPlayerBridge::Player::_stopPolling  = sub {};
}

my $ctl = FakeController->new;
$c->controller($ctl);
$c->hqStarted(1);
$c->hqWanted('play');

# HQPlayer reports paused, and we did not ask for it -> follow it into LMS
@sent = ();
$c->_onStatus({ state => 1, position => 30 }, '');
is(join(',', @{$ctl->{calls}}), 'pause', 'a pause at HQPlayer pauses LMS');
is($c->hqWanted, 'pause', 'and is recorded as the state we now want');

# LMS answers that by calling pause() on us ~300ms later - it must not go back out
$c->pause;
is(scalar(@sent), '0', 'the follow-up pause() is not echoed back to HQPlayer');

# same in reverse
$ctl->{calls} = [];
$c->_onStatus({ state => 2, position => 30 }, '');
is(join(',', @{$ctl->{calls}}), 'resume', 'a resume at HQPlayer resumes LMS');
is($c->hqWanted, 'play', 'and is recorded');
$c->resume;
is(scalar(@sent), '0', 'the follow-up resume() is not echoed back either');

# a pause that DID start in LMS still reaches HQPlayer, exactly once
$ctl->{calls} = [];
@sent = ();
$c->hqWanted('play');
$c->pause;
is(join(',', @sent), '<Pause/>', 'a pause from LMS is sent on');
$c->pause;
is(scalar(@sent), '1', 'but never sent twice - <Pause/> could toggle');

# and HQPlayer confirming that pause must not bounce back as a command
$ctl->{calls} = [];
$c->_onStatus({ state => 1, position => 31 }, '');
is(scalar(@{$ctl->{calls}}), '0', 'HQPlayer confirming our own pause is not treated as external');

# the race: controller already PAUSED, HQPlayer still reporting PLAYING because
# our <Pause/> has not gone out yet.  Must not read as an external resume.
$ctl->{paused} = 1;
$ctl->{calls}  = [];
$c->hqWanted('pause');
$c->_onStatus({ state => 2, position => 31 }, '');
is(join(',', @{$ctl->{calls}}), 'resume', 'a genuine external resume is followed');
$ctl->{paused} = 1;
$ctl->{calls}  = [];
$c->hqWanted('play');
$c->_onStatus({ state => 2, position => 31 }, '');
is(scalar(@{$ctl->{calls}}), '0',
   'but a PLAYING push during our own 300ms pause fade does NOT un-pause LMS');


# ---------------------------------------------------------------------------
# Volume is SHARED, not owned.  HQPlayer holds the real level in dB and splits
# it between the endpoint's attenuator and its own software gain; LMS holds an
# 0-100 slider.  hqVolDb is the last level we know HQPlayer is at, and it is
# what stops the two directions chasing each other round.
# ---------------------------------------------------------------------------
print "-- volume mapping --\n";
is($c->_lmsToDb(100), '0',    'LMS 100 is 0dB');
is($c->_lmsToDb(50),  '-50',  'on a -100..0 instance one LMS step is 1dB');
is($c->_lmsToDb(0),   '-100', 'LMS 0 is the floor');
is($c->_lmsToDb(150), '0',    'over-range clamps to the ceiling');
is($c->_lmsToDb(-47), '-100', 'mute arrives as a negative level and goes to the floor');
is($c->_dbToLms(-53), '47',   'and back again');
# int() truncates towards zero, and every dB figure here is negative
is($c->_dbToLms(-53.4), '47',  'a fractional dB rounds towards the nearer step, not towards zero');
is($c->_dbToLms(-999),'0',    'under-range clamps to 0');

# THE RANGE IS A SETTING, NOT A CONSTANT.  HQPlayer defaults to -60..0, this
# instance is -100..0, and a user may cap the top as well as the floor.
print "-- volume mapping on other ranges --\n";
$c->hqVolMin(-60); $c->hqVolMax(0);
is($c->_lmsToDb(100), '0',   'a -60..0 instance still tops out at 0dB');
is($c->_lmsToDb(0),   '-60', 'and bottoms out at ITS floor, not at -100');
is($c->_lmsToDb(50),  '-30', 'the slider spans the whole range');
is($c->_dbToLms(-30), '50',  'and inverts');

$c->hqVolMin(-60); $c->hqVolMax(-20);
is($c->_lmsToDb(100), '-20', 'a -60..-20 instance tops out at -20dB');
is($c->_lmsToDb(0),   '-60', 'and bottoms out at -60dB');
is($c->_lmsToDb(50),  '-40', 'mid-slider is mid-range');
is($c->_dbToLms(-40), '50',  'and inverts');

# NO DEAD INCREMENTS.  HQPlayer takes fractional dB (verified live: -39.25 is
# reported back verbatim), so every one of the 101 positions gets a level of
# its own - on any range, however narrow.
for my $range ([-100,0], [-60,0], [-60,-20], [-30,-20]) {
    $c->hqVolMin($range->[0]); $c->hqVolMax($range->[1]);
    my ($mono, $prev) = (1, undef);
    for my $v (0..100) {
        my $db = $c->_lmsToDb($v);
        $mono = 0 if defined $prev && $db <= $prev;
        $prev = $db;
    }
    ok($mono, "every slider step changes the level on a $range->[0]..$range->[1] instance");
}

# It round-trips through a 32-bit float on the wire, so stay on a binary grid.
$c->hqVolMin(-60); $c->hqVolMax(0);
is(Plugins::HQPlayerBridge::Player::_fmtDb($c->_lmsToDb(37)), '-37.75',
   'a fractional level is quantised to a binary fraction of a dB');
$c->hqVolMin(-100); $c->hqVolMax(0);
is(Plugins::HQPlayerBridge::Player::_fmtDb($c->_lmsToDb(47)), '-53',
   'and a whole dB is still sent as a whole number');

print "-- volume both ways --\n";
my @ex;
{
    no warnings 'redefine';
    *Slim::Player::Client::execute = sub { push @ex, join(' ', @{$_[1]}) };
}

@sent = ();
$c->hqVolDb(undef);
$c->volume(47);
is(join(',', @sent), '<Volume value="-53"/>', 'an LMS change is sent on in dB');
$c->volume(47);
is(scalar(@sent), '1', 'the same level again is not re-sent');

# TRAP: the second arg is $temp, not "force".  Every step of LMS's pause/resume
# volume ramp arrives with it set, and none of them are ours to forward.
@sent = ();
$c->volume(30, 1); $c->volume(20, 1); $c->volume(0, 1);
is(scalar(@sent), '0', 'temporary volumes (the pause fade) are never forwarded');

# HQPlayer's own UI, or the endpoint's remote, moved it.  Note the temporary 0
# still parked by the ramp above: the inbound guard has to read the PERSISTED
# level, or a push landing inside _Resume's fade window reads as "the endpoint
# just dropped to the floor".
@sent = (); @ex = ();
$c->_onStatus({ state => 2, position => 5, volume => -40 }, '');
is(join(',', @ex), 'mixer volume 60', 'a change at HQPlayer is mirrored into LMS');
is(scalar(@sent), '0', 'and is NOT sent straight back out');
is($c->hqVolDb, '-40', 'hqVolDb tracks where HQPlayer actually is');
$c->volume(60);
is(scalar(@sent), '0', 'the mixer command it triggers does not echo either');

@ex = ();
$c->_onStatus({ state => 2, position => 6, volume => -40 }, '');
is(scalar(@ex), '0', 'an unchanged volume in the status stream does nothing');

# THE SNAP.  LMS re-asserts its STORED volume at the start of every track that
# begins from stopped (StreamingController, "Bug 10310").  A level set on the
# endpoint's own knob will not land on LMS's 101-step grid, so without a
# tolerance that re-assert drags the endpoint back onto the rounded value -
# which is exactly the reported "LMS changes the volume on the next track".
print "-- a level set on the endpoint survives a track change --\n";
@sent = (); @ex = ();
$c->_onStatus({ state => 2, position => 7, volume => -39.6 }, '');
is(scalar(@ex), '0', 'an off-grid level within half a step does not move the slider');
is($c->hqVolDb, '-39.6', 'but it is recorded as where HQPlayer actually is');
$c->volume(60);   # the track-start re-assert, with LMS's stored 60
is(scalar(@sent), '0', 'and the track-start re-assert does not drag it back');

@sent = ();
$c->volume(58);
is(join(',', @sent), '<Volume value="-42"/>', 'a real slider move is still sent');

# Some HQPlayer setups do not attenuate at all - the DAC or the amp holds the
# volume - and the LMS slider must sit at the top rather than pretend.
print "-- fixed volume --\n";
my $sp = Slim::Utils::Prefs::preferences('server');
@sent = (); @ex = ();
$c->_setFixed(1);
is($c->hqVolFixed, '1', 'a zero-width range locks the volume');
is(join(',', @ex), 'mixer volume 100', 'and parks the LMS slider at the top');
is($sp->client($c)->get('digitalVolumeControl'), '0',
   'via the pref LMS turns into use_volume_control:0, which the skins disable the slider on');
@sent = ();
$c->volume(40);
is(scalar(@sent), '0', 'nothing is sent to HQPlayer while it is not attenuating');
$c->_setFixed(0);
is($sp->client($c)->get('digitalVolumeControl'), '1', 'and it unlocks again');

# LMS's own "Volume Control: fixed" radio means the same thing, and is the
# user's, not ours: honour it, and never write it back to variable.
$sp->client($c)->set('digitalVolumeControl', 0);
@sent = ();
$c->volume(35);
is(scalar(@sent), '0', "a user's own fixed-volume setting stops us sending too");
$c->_setFixed(1); $c->_setFixed(0);
is($sp->client($c)->get('digitalVolumeControl'), '0',
   'and a 0 we did not set is never written back to 1');
$sp->client($c)->set('digitalVolumeControl', 1);

# The range is READ, not assumed.  VERIFIED live: HQPlayer does implement UPnP
# GetVolumeDBRange even though the XML control API calls it an unknown command.
print "-- learning the range --\n";
@ex = ();
$c->hqVolDb(-30);
$c->_setRange(-60, 0);
is($c->_volStep, '0.6', 'the size of a slider step follows the range');
is(join(',', @ex), 'mixer volume 50',
   'and the slider is re-derived from where HQPlayer is, not left reading the old scale');

# The fallback, and the only route that survives a mid-session reconfigure:
# ask for a level below the floor and HQPlayer answers with the floor itself.
@sent = (); @ex = ();
$c->hqVolMin(-100); $c->hqVolMax(0);
$c->volume(0);                                   # asks for the floor we believe in
$c->_onStatus({ state => 0, position => 0, volume => -60 }, '');
is($c->hqVolMin, '-60', 'a clamped reply teaches us the real floor');
is($c->hqVolMax, '0',   'and leaves the ceiling alone');

# The other fixed-volume tell: it accepts the command and does not move.
$c->hqVolMin(-100); $c->hqVolMax(0);
$c->hqVolDb(-50); $c->hqVolMissed(0); $c->hqVolFixed(0);
for ( 1 .. 3 ) {
    $c->hqVolSent(-70);
    $c->hqVolSentAt( Time::HiRes::time() - 5 );
    $c->_followVolume(-50);
}
is($c->hqVolFixed, '1', 'three sends that change nothing mark the volume fixed');
$c->_setFixed(0);
$sp->client($c)->set('digitalVolumeControl', 1);
$c->hqVolDb(undef);

print "-- fade_volume --\n";
my $fired = 0;
$c->_tempVolume(0);
$c->fade_volume(-0.3125, sub { $fired++ });
is($fired, '1', 'the callback fires immediately - it is what actually pauses');
is($c->_tempVolume, '(undef)',
   'and the ramp temporary volume is cleared, or the slider reads zero after a resume');


# ---------------------------------------------------------------------------
# Track changes.  Loading a track is several async round trips, and HQPlayer
# pushes status ~1/s throughout, so a track change always straddles a push or
# two.  Two ways that used to go wrong, both of which skip a track:
#
#   * play() cleared hqExpectStop immediately, so the stop WE sent to end the
#     previous track arrived as an unexplained stop - i.e. end-of-track - and
#     LMS advanced past the track it had just started.
#   * the load's completion callback was never cancelled, so a stop or a skip
#     during the load window still re-asserted bufferReady and applied the OLD
#     track's seek offset to the new one.
# ---------------------------------------------------------------------------
print "-- track changes --\n";
{
    package LoadUPnP;
    sub new   { bless { ready => 1, cancels => 0, uris => [] }, shift }
    sub ready { $_[0]->{ready} }
    sub cancelPlay { $_[0]->{cancels}++ }
    sub setURI {
        my ( $s, $url, $didl, $cb ) = @_;
        push @{ $s->{uris} }, $url;
        $s->{didl}  = $didl;
        $s->{uriCb} = $cb;
    }
    sub playWhenReady { $_[1] and $_[0]->{playCb} = $_[1] }
    # the daemon answering, whenever the test says it does
    sub finishURI  { my $cb = delete $_[0]->{uriCb};  $cb->( 'ok', undef ) if $cb }
    sub finishPlay { my $cb = delete $_[0]->{playCb}; $cb->( 'ok', undef ) if $cb }

    package LoadController;
    sub new { bless { song => $_[1], calls => [] }, $_[0] }
    sub song { $_[0]->{song} }
    sub isPaused { 0 }
    # Declared rather than AUTOLOADed: these are QUERIES, and letting them fall
    # through would record them in {calls} alongside the notifications the
    # tests assert on.  isPlaying(1) is the controller's own "playingState is
    # PLAYING", which _queueTrack uses to skip a BufferReady the state table
    # would answer with _Invalid.
    sub isPlaying { $_[0]->{playing} ? 1 : 0 }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://;
        return if $m eq 'DESTROY';
        push @{ $_[0]->{calls} }, $m;
        return;
    }
}

my $up  = LoadUPnP->new;
my $one = FakeSong->new( FakeTrack->new({ title=>'One', id=>101, ct=>'flc', secs=>200, url=>'file:///one.flac' }) );
my $two = FakeSong->new( FakeTrack->new({ title=>'Two', id=>202, ct=>'flc', secs=>200, url=>'file:///two.flac' }) );

my $p = Plugins::HQPlayerBridge::Player->new('02:11:22:33:44:55', 'paddr', 1.0, undef, 12, undef);
$p->hqUPnP($up);
# _queueTrack refuses to load without a control link now that the load runs on
# it.  _send itself is mocked above, so this only has to be present and true.
$p->hqControl( bless {}, 'FakeCtl' );
my $lc = LoadController->new($one);
$p->controller($lc);

# Pretend the track has been playing a while.  HQPlayer reports PLAYING as soon
# as it accepts a stream and can drop back to STOPPED for a moment while the
# first bytes arrive, so a stop inside START_GRACE of the start is start-up
# noise rather than the end - see the HQP_STOPPED branch.  A test that fires a
# stop microseconds after the start is exercising that guard, not end-of-track,
# so age the player first wherever a REAL end is meant.
sub aged { $_[0]->hqStartedAt( Time::HiRes::time() - 30 ); return }

# helper: one pushed <Status/>, with the metadata child HQPlayer really sends.
# $track is HQPlayer's own playlist index (it reports track="n" tracks_total="n"
# on every push), which is what a gapless hand-over is observed by.
sub status {
    my ( $player, $state, $uri, $pos, $track ) = @_;
    my %a = ( state => $state, position => $pos // 0 );
    $a{track} = $track if defined $track;
    my $raw = qq{<Status state="$state" position="} . ( $pos // 0 ) . q{"}
            . ( defined $track ? qq{ track="$track" tracks_total="$track"} : '' )
            . q{>}
            . ( $uri ? qq{<metadata bits="24" samplerate="96000" uri="$uri"/>} : '' )
            . q{</Status>};
    $player->_onStatus( \%a, $raw );
    return;
}

@sent = (); @sentCb = ();
$p->play({ controller => $lc });

my ($addCmd) = grep { /^<PlaylistAdd\b/ } @sent;
my ($url1)   = $addCmd ? $addCmd =~ m{\buri="([^"]+)"} : ();

ok($url1 && $url1 =~ m{/music/101/download\.flac}, 'play() hands HQPlayer the tier-1 URL');

# THE ORDER IS THE FIX.  Splitting the load across two channels - <Stop/> on
# the control socket, SetAVTransportURI/Play over UPnP - meant a Stop for the
# OLD track could land after the Play for the new one, because a control
# command answers in ~9-150ms and a UPnP round trip in 300-550ms.  HQPlayer's
# AVTransport never saw a Stop at all, so the engine's playlist was emptied
# underneath a renderer that still thought it was playing: that is
# clPlaylist::GetAlbumGain(): trackn > last, the fatal that killed hqplayerd
# whenever an album was loaded over a playing one.  One socket, one order.
is(join(',', grep { !/^<Seek/ } @sent),
   '<Stop/>,<PlaylistClear/>,' . $addCmd,
   'the load opens with three ordered commands on the control socket');

# <Play/> is deliberately NOT sent yet: it is chained off PlaylistAdd's reply,
# so HQPlayer can never be told to play a queue it has not confirmed loading.
ok(scalar(!grep { $_ eq '<Play/>' } @sent), 'and Play waits for PlaylistAdd to be acknowledged');

# TRAP: clear="1" is IGNORED by engine 6.0.4 - PlaylistAdd answers OK and
# APPENDS anyway, which is why the explicit <PlaylistClear/> above is load
# bearing.  The attribute is still sent as the documented spelling.
ok(scalar($addCmd =~ m{\bclear="1"}), 'PlaylistAdd still carries the documented clear="1"');

# The artwork lever.  cover= takes a PLAIN url and HQPlayer base64-encodes it
# into the item's `picture` itself - verified byte-identical to the DIDL path
# against engine 6.0.4 on 2026-08-28.  picture=/albumArtURI=/art= and a
# <picture> child are all silently ignored.
ok(scalar($addCmd =~ m{<metadata\b[^>]*\bcover="https?://[^"]*/cover\.jpg"}),
   'the load carries <metadata cover="..."> - this is what sets the picture field');
is($p->hqExpectStop, '1',
   'play() leaves the stop guard ARMED - the stop that ended the previous track is still in flight');
is($p->hqPlayAck, '0', 'and the track is not acknowledged until HQPlayer accepts Play');

# a push describing the PREVIOUS track, arriving after play() has set up this one
$p->hqPrevURL('http://127.0.0.1:9000/music/999/download.flac');
status($p, 2, 'http://127.0.0.1:9000/music/999/download.flac', 197);
is($p->hqStarted, '0', 'a PLAYING push for the previous track does not start this one');
is($p->hqPosition, '0',
   "and its position (197s into the previous track) is not adopted as ours");
$p->hqPrevURL(undef);

# ... and even with no way to tell the tracks apart (tier 2 - every track comes
# off the same /stream.mp3 URL), an unacknowledged PLAYING is not a start
status($p, 2, undef, 0);
is($p->hqStarted, '0', 'an unacknowledged PLAYING push is never taken as a start');

# the stop we sent to end the previous track finally lands
$lc->{calls} = [];
status($p, 0, undef, 0);
is(scalar(@{$lc->{calls}}), '0',
   'our own stop, arriving during the load, is NOT reported as end-of-track');

# HQPlayer accepts the track and starts playing it: PlaylistAdd answers, which
# sends <Play/>, and then Play answers.
$lc->{calls} = [];
_answer();      # PlaylistAdd -> OK
ok(scalar(grep { $_ eq '<Play/>' } @sent), 'PlaylistAdd acknowledged -> Play follows, in order');

# A SUCCESSFUL reply must never be read as a failure.  0.2.13 shipped reading
# the callback's second argument as an error - it is the raw reply, present on
# success too - so every load reported PROBLEM_OPENING, LMS skipped to the next
# track, and the player raced the whole playlist without playing anything.
ok(scalar(!grep { $_ eq 'playerStreamingFailed' } @{$lc->{calls}}),
   'an OK PlaylistAdd is NOT reported as a failed load');

_answer();      # Play        -> OK
is($p->hqPlayAck, '1', 'Play accepted -> the track is acknowledged');
ok(scalar(!grep { $_ eq 'playerStreamingFailed' } @{$lc->{calls}}),
   'nor is an OK Play');
is($p->bufferReady, '1', 'and the buffer is asserted for the controller');

$lc->{calls} = [];
status($p, 2, $url1, 1);
is($p->hqStarted, '1', 'now a PLAYING push starts the track');
is(join(',', @{$lc->{calls}}), 'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
   'and Started is signalled, exactly once, ahead of the heartbeat');
# ReadyToStream rides along with it now: that is the request for the next
# track, and it is what makes the hand-over possible at all.  It must come
# AFTER Started, or LMS is asked for a second song before the first is playing.
is($p->hqArmNext, '1', 'and the next track is asked for, once the first is playing');
is($p->hqExpectStop, '0', 'the stop guard is disarmed only now');

# genuine end of playlist - LMS had no next track to hand over
$lc->{calls} = [];
$p->hqArmNext(0);
aged($p);
status($p, 0, $url1, 200);
is(join(',', @{$lc->{calls}}), 'playerEndOfStream,playerReadyToStream,playerStopped',
   'HQPlayer stopping on its own IS end-of-track');

print "-- a load that genuinely fails --\n";
{
    # The other half of the contract: $attrs undef IS the failure, and it must
    # still reach the controller.  Without this the guard above could simply be
    # inverted and both would pass.
    my $fp = Plugins::HQPlayerBridge::Player->new('02:99:88:77:66:55', 'paddr', 1.0, undef, 12, undef);
    $fp->hqUPnP( LoadUPnP->new );
    $fp->hqControl( bless {}, 'FakeCtl' );
    my $fc = LoadController->new($one);
    $fp->controller($fc);

    @sent = (); @sentCb = ();
    $fp->play({ controller => $fc });
    $fc->{calls} = [];
    _answer(0);     # PlaylistAdd -> Error
    ok(scalar(grep { $_ eq 'playerStreamingFailed' } @{$fc->{calls}}),
       'a rejected PlaylistAdd IS reported as a failed load');
    ok(scalar(!grep { $_ eq '<Play/>' } @sent),
       'and Play is never sent for a track HQPlayer refused');
}

print "-- a load superseded mid-flight --\n";
# skip: play track two, then stop before HQPlayer has answered
$p->play({ controller => LoadController->new($two) });
my $gen = $p->hqGen;
$p->stop;
ok($p->hqGen != $gen, 'stop() supersedes the load that was in flight');
is($up->{cancels}, '3', 'and the UPnP Play retry loop is cancelled each time');

$p->bufferReady(0);
$lc->{calls} = [];
$up->finishURI;
$up->finishPlay;
is($p->bufferReady, '0',
   'the superseded load does not re-assert bufferReady after the stop');
is($p->hqPlayAck, '0', 'nor acknowledge a track that is no longer wanted');

# skip mid-load: the old track's seek must not be applied to the new one
@sent = ();
$p->play({ controller => LoadController->new($one), seekdata => { timeOffset => 90 } });
$p->play({ controller => LoadController->new($two) });   # skipped before it loaded
$up->finishURI;
$up->finishPlay;
is(join(',', grep { /Seek/ } @sent), '',
   "the skipped track's seek is not sent to the track that replaced it");
is($p->hqSeekOffset, '0', 'and no phantom seek offset is left on the elapsed time');


# ---------------------------------------------------------------------------
# GAPLESS.  The bridge used to feed HQPlayer exactly one item at a time, so
# every track end was an end of playlist and the next track only started after
# LMS had seen the stop and run a fresh four-command load - and that round trip
# IS the gap.  HQPlayer is gapless between the items of its own playlist, so
# the fix is to put the next track there before it is needed.
#
# The two halves are asserted separately, because they fail differently:
#
#   * play() must APPEND for a hand-over.  A Stop or a PlaylistClear there
#     kills the track that is playing.
#   * _onStatus must recognise the advance WITHOUT a state 0, because with two
#     items on the playlist HQPlayer never stops between them.  Missing it is
#     not fatal (it degrades to the old behaviour at the end of the playlist)
#     but reporting an end-of-stream for it would reload the track playing.
# ---------------------------------------------------------------------------
print "-- gapless hand-over --\n";
{
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:ee', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer();      # PlaylistAdd
    _answer();      # Play

    # track one starts, and the request for track two rides along with it
    $gc->{calls} = [];
    status( $gp, 2, $u1, 1, 1 );
    is( $gp->hqArmNext, '1', 'a track starting arms the request for the next one' );
    ok( scalar( grep { $_ eq 'playerReadyToStream' } @{ $gc->{calls} } ),
        'and ReadyToStream is what asks LMS for it' );

    # LMS answers with track two WHILE track one is still playing
    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;      # the controller is PLAYING track one
    $gp->play({ controller => $gc });

    is( $gp->hqArmNext, '0', 'the hand-over consumes the flag' );
    is( scalar(@sent), '1', 'a hand-over is ONE command - no Stop, no PlaylistClear, no Play' );
    ok( scalar( $sent[0] =~ /^<PlaylistAdd\b/ ), 'and that command is the append' );
    # queued="0", NOT queued="1".  Isolated live 2026-08-28: appending
    # mid-playback with queued="1" leaves HQPlayer's track index inconsistent,
    # and at the end of the LAST item the engine walks past it -
    # clPlaylist::GetAlbumGain(): trackn > last, and the DAEMON EXITS.  Four
    # controlled runs: queued="0" survived twice, queued="1" died twice, and
    # trimming the playlist back to one item first did not save it.  queued="0"
    # appends just the same and advances just the same.
    ok( scalar( $sent[0] =~ /\bqueued="0"/ ),
        'the append uses queued="0" - queued="1" corrupts the index and kills hqplayerd' );
    ok( scalar( $sent[0] !~ /\bqueued="1"/ ), 'and queued="1" appears nowhere in it' );
    ok( scalar( $sent[0] =~ m{<metadata\b[^>]*\bcover="} ),
        'the pre-queued item carries its own artwork - HQPlayer forwards it at the transition' );

    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};
    ok( $u2 && $u2 =~ m{/music/202/download\.flac}, 'and it is track two, not track one again' );
    is( $gp->hqURL, $u1, 'hqURL still names the track that is PLAYING, not the queued one' );
    is( $gp->hqStarted, '1', 'and the playing track is untouched' );

    _answer();      # the append is accepted
    is( $gp->hqNext && $gp->hqNext->{acked}, '1', 'HQPlayer confirms it holds the next track' );

    # HQPlayer advances by itself.  NO state 0 - it never stops - so the
    # playlist index moving from 1 to 2 is the only signal there is.
    $gc->{calls} = [];
    status( $gp, 2, $u2, 0, 2 );

    is( join( ',', @{ $gc->{calls} } ),
        'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
        'the advance reports Started - and immediately asks for the track after it' );
    is( $gp->hqURL, $u2, 'the pre-queued track is now the current one' );
    is( $gp->hqPrevURL, $u1, 'and the one it replaced is remembered, so its late pushes read as stale' );
    is( $gp->hqStarted, '1', 'the player never stopped' );
    is( $gp->hqNext, '(undef)', 'and nothing is queued any more' );
    is( $gp->hqTrackNo, '2', "HQPlayer's own playlist index is followed" );

    # end of the LAST item is still a real end of playlist
    $gc->{calls} = [];
    $gp->hqArmNext(0);
    aged($gp);
    status( $gp, 0, $u2, 200, 2 );
    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'state 0 now means end of PLAYLIST, and is still reported as end-of-stream' );
}

print "-- gapless: the spurious advance that froze LMS --\n";
{
    # LIVE FAILURE 2026-08-28.  The first cut fired on "the playlist index
    # changed OR the uri matches", and declared the hand-over 0.2s after
    # queueing the track, while HQPlayer was still playing the previous one.
    #
    # That failure is NOT self-correcting: hqURL then names a track HQPlayer
    # is not playing and hqPrevURL names the one it IS, so _isStale suppresses
    # every subsequent push as "the previous track".  Position freezes, LMS
    # shows the wrong track, nothing recovers.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f3', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};

    # not acknowledged yet - nothing may be read as an advance, whatever the
    # index does
    $gc->{calls} = [];
    status( $gp, 2, $u1, 2, 9 );
    is( $gp->hqURL, $u1, 'an index jump BEFORE the append is acknowledged is not an advance' );

    _answer();      # now HQPlayer confirms it holds the track

    # THE URI IS A VETO.  HQPlayer says it is still playing track one, so the
    # index moving cannot mean the hand-over happened.
    $gc->{calls} = [];
    status( $gp, 2, $u1, 3, 7 );
    is( $gp->hqURL, $u1,
        'an index jump while HQPlayer still names track one is NOT an advance' );
    is( join( ',', @{ $gc->{calls} } ), 'playerStatusHeartbeat',
        'and nothing is reported to LMS' );

    # THE SAME TRACK TWICE.  A duplicate in the queue - or repeat-one - makes
    # the queued url identical to the playing one, so "HQPlayer is playing what
    # we queued" is true BEFORE the advance as well as after.  Live, that fired
    # two advances 0.2s apart and LMS skipped a playlist entry.  With the urls
    # ambiguous the index is the only thing left that can tell them apart.
    {
        my $dp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f8', 'paddr', 1.0, undef, 12, undef);
        $dp->hqUPnP( LoadUPnP->new );
        $dp->hqControl( bless {}, 'FakeCtl' );
        my $dc = LoadController->new($one);
        $dp->controller($dc);

        @sent = (); @sentCb = ();
        $dp->play({ controller => $dc });
        my ($d1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
        _answer(); _answer();
        status( $dp, 2, $d1, 1, 1 );

        # LMS hands over the SAME track again
        @sent = (); @sentCb = ();
        $dc->{song} = $one;
        $dc->{playing} = 1;
        $dp->play({ controller => $dc });
        _answer();

        $dc->{calls} = [];
        status( $dp, 2, $d1, 3, 1 );
        is( join( ',', @{ $dc->{calls} } ), 'playerStatusHeartbeat',
            'the same url queued twice does NOT advance on the uri alone' );

        $dc->{calls} = [];
        status( $dp, 2, $d1, 0, 2 );
        ok( scalar( grep { $_ eq 'playerTrackStarted' } @{ $dc->{calls} } ),
            'it advances when the playlist INDEX moves on, which is all that can tell them apart' );
    }

    # a stop is not an advance either - HQPlayer reports track="0" when idle,
    # so "the index changed" would read every stop as a hand-over
    $gp->hqTrackNo(1);
    status( $gp, 2, undef, 4, 0 );
    is( $gp->hqURL, $u1, 'track going to 0 with no uri is not an advance - only an INCREASE is' );

    # the real thing: HQPlayer names the track we queued
    $gc->{calls} = [];
    status( $gp, 2, $u2, 0, 2 );
    is( $gp->hqURL, $u2, 'HQPlayer naming the queued url IS the advance' );
    is( join( ',', @{ $gc->{calls} } ),
        'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
        'and only then is Started reported' );
}

print "-- a gapless boundary must not be read as the end of the playlist --\n";
{
    # LIVE FAILURE 2026-08-28.  200ms after a correct hand-over, HQPlayer
    # pushes a TRANSIENT state 0 with everything zeroed and no metadata child -
    # byte-identical to the push a real end of playlist produces:
    #
    #   state="2" track="2/3" uri=".../437344.flac"   <- handed over
    #   state="0" track="0"   tracks_total="0"        <- 200ms later
    #   state="2" track="3/4" uri=".../437344.flac"   <- 2s later
    #
    # Read as the end it reported EndOfStream/Stopped mid-album: LMS advanced
    # an extra track, stopped, and every push after that arrived at a
    # controller in STOPPED/IDLE where TrackStarted is _Invalid.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f5', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    # LMS hands over track two, HQPlayer acknowledges it
    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};
    _answer();

    Slim::Utils::Timers::_reset();

    # the transient: stopped, everything zeroed, nothing to distinguish it
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, undef, 0, 0 );

    is( join( ',', @{ $gc->{calls} } ), '',
        'a stop with a hand-over queued is NOT reported straight away' );
    is( $gp->hqStarted, '1', 'and the track is still considered playing' );
    is( Slim::Utils::Timers::_pending(), '1', 'it is held on a timer instead' );

    # ...and HQPlayer comes back, so it was a boundary after all
    status( $gp, 2, $u2, 0, 2 );
    is( Slim::Utils::Timers::_pending(), '0',
        'HQPlayer playing again cancels the pending end-of-playlist' );
    is( $gp->hqURL, $u2, 'and the hand-over completes normally' );
}

{
    # The other half: a stop that is REAL must still be reported, just
    # END_GRACE later.  Without this the debounce would swallow a stop made at
    # HQPlayer's own UI whenever a hand-over happened to be queued.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f6', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song} = $two; $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    _answer();

    Slim::Utils::Timers::_reset();
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, undef, 0, 0 );
    Slim::Utils::Timers::_fireAll();          # nothing came back in time

    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'a stop that stays stopped IS reported, once the grace period expires' );
    is( $gp->hqStarted, '0', 'and the track is no longer considered playing' );
    is( $gp->hqNext, '(undef)',
        'and anything still queued is dropped - it belongs to the run that ended' );
    is( $gp->hqArmNext, '0', 'as does the arm flag' );
}

{
    # With nothing queued there is nothing for HQPlayer to move into, so a stop
    # can only be real - report it at once, exactly as before gapless.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f7', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );
    $gp->hqArmNext(0);

    Slim::Utils::Timers::_reset();
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, $u1, 200, 1 );
    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'with nothing queued the stop is reported immediately - no added delay' );
    is( Slim::Utils::Timers::_pending(), '0', 'and nothing is left on a timer' );
}

print "-- a stop right after a track starts is start-up noise --\n";
{
    # LIVE FAILURE 2026-08-28, tier 2.  HQPlayer reports PLAYING as soon as it
    # accepts the stream, then drops back to STOPPED for a moment while LMS is
    # still spinning up the transcode - measured at 0.33s.  Read as the end, it
    # skipped the track 0.33s in and jumped to the next one.
    #
    # hqExpectStop covers the window BEFORE the new track is confirmed; this
    # covers the window just after it.
    my $np = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f9', 'paddr', 1.0, undef, 12, undef);
    $np->hqUPnP( LoadUPnP->new );
    $np->hqControl( bless {}, 'FakeCtl' );
    my $nc = LoadController->new($one);
    $np->controller($nc);

    @sent = (); @sentCb = ();
    $np->play({ controller => $nc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $np, 2, $u1, 0, 1 );          # confirmed playing, stamps the clock

    Slim::Utils::Timers::_reset();
    $nc->{calls} = [];
    $np->hqArmNext(0);

    # the transient, a fraction of a second in
    status( $np, 0, $u1, 0, 1 );
    is( join( ',', @{ $nc->{calls} } ), '',
        'a stop a fraction of a second into the track is NOT the end' );
    is( $np->hqStarted, '1', 'the track is still considered playing' );
    is( Slim::Utils::Timers::_pending(), '0',
        'and it is discarded outright, not merely deferred' );

    # the same push, once the track has actually been running
    aged($np);
    $nc->{calls} = [];
    status( $np, 0, $u1, 200, 1 );
    is( join( ',', @{ $nc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'the same stop later in the track IS the end' );
}

print "-- the stale suppression is bounded --\n";
{
    # The other half of the same failure.  Even with the advance logic right,
    # a wrong hqURL/hqPrevURL pair must not be able to suppress the status
    # stream forever - that is a player that can only be fixed by restarting.
    my $sp2 = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f4', 'paddr', 1.0, undef, 12, undef);
    $sp2->hqUPnP( LoadUPnP->new );
    $sp2->hqControl( bless {}, 'FakeCtl' );
    my $sc = LoadController->new($one);
    $sp2->controller($sc);

    @sent = (); @sentCb = ();
    $sp2->play({ controller => $sc });
    _answer(); _answer();

    # wedge it by hand: HQPlayer is playing A, we think we moved to B
    my $a = 'http://h/a.flac';
    my $b = 'http://h/b.flac';
    $sp2->hqPrevURL($a);
    $sp2->hqURL($b);
    $sp2->hqStarted(1);

    for my $i ( 1 .. 5 ) {
        $sc->{calls} = [];
        status( $sp2, 2, $a, 10 + $i, 1 );
        is( $sp2->hqURL, $b, "push $i is suppressed as stale, as designed" );
    }

    $sc->{calls} = [];
    status( $sp2, 2, $a, 20, 1 );
    is( $sp2->hqURL, $a,
        "past the limit HQPlayer's account wins - the player un-wedges itself" );
    is( $sp2->hqPrevURL, '(undef)', 'and the bad previous-track marker is cleared' );
    ok( scalar( grep { $_ eq 'playerStatusHeartbeat' } @{ $sc->{calls} } ),
        'the status stream reaches the controller again' );
}

print "-- tier 3: a local file HQPlayer cannot decode --\n";
{
    # HQPlayer CANNOT FETCH A URL WITH A QUERY STRING.  Isolated live
    # 2026-08-28: /music/458773/download.flac plays, the same url with ?x=1
    # does not, and neither does /stream.mp3?player=...  PlaylistAdd answers
    # result="OK" either way and then never fetches it.
    #
    # So a local file in a format HQPlayer cannot decode must NOT go to tier 2.
    # `download` transcodes whenever the requested extension differs from the
    # track's own, and that url is path-only.
    my $alac = FakeSong->new( FakeTrack->new(
        { title=>'Lossless', id=>303, ct=>'alc', secs=>200, url=>'file:///x.m4a' } ) );

    my $u = $c->_resolveURL($alac);
    is( $u, 'http://127.0.0.1:9000/music/303/download.flac',
        'a local file HQPlayer cannot decode is asked for AS FLAC, path-only' );
    is( $c->hqTier, '3', 'and is tier 3' );
    ok( scalar( $u !~ /\?/ ),
        'the url carries NO query string - HQPlayer silently refuses those' );

    # a format it CAN decode is still an untouched passthrough
    my $flac = FakeSong->new( FakeTrack->new(
        { title=>'Native', id=>404, ct=>'flc', secs=>200, url=>'file:///x.flac' } ) );
    is( $c->_resolveURL($flac), 'http://127.0.0.1:9000/music/404/download.flac',
        'a native FLAC is unchanged' );
    is( $c->hqTier, '1', 'and stays tier 1 - it is a byte-for-byte passthrough, and seekable' );

    # only something genuinely remote falls through to the broken tier
    my $rem = FakeSong->new( FakeTrack->new(
        { title=>'Streamed', id=>-9454304, ct=>'flc', secs=>200,
          url=>'qobuz://445307221.flac' } ) );
    ok( scalar( $c->_resolveURL($rem) =~ m{/stream\.mp3\?player=} ),
        'only a remote track reaches tier 2, which is the one with no file to serve' );
    is( $c->hqTier, '2', 'and is tier 2' );
}

print "-- gapless: the guards --\n";
{
    # TIER 2 CANNOT RIDE HQPLAYER'S PLAYLIST.  Every tier 2 track is the same
    # /stream.mp3?player= URL, that endpoint serves one consumer at a time, and
    # it is fed by LMS's own songStreamController - which _Stream closes as
    # soon as it opens the next one.  Two items pointing at it would tear the
    # track that is playing, so the track is HELD and loaded the ordinary way.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:ef', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    # A LOCAL file of any format is tier 3 now (LMS transcodes it on a
    # path-only url), so only a genuinely REMOTE track reaches tier 2 - it is
    # the one case with no file to serve.
    my $remote = FakeSong->new( FakeTrack->new(
        { title=>'Streamed', id=>-94543041325440, ct=>'flc', secs=>200,
          url=>'qobuz://445307221.flac' } ) );

    @sent = (); @sentCb = ();
    $gc->{song}    = $remote;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });

    is( scalar(@sent), '0', 'a tier 2 next track is NOT pre-queued - nothing is sent' );
    is( $gp->hqNext && $gp->hqNext->{mode}, 'load', 'it is held for a normal load instead' );
    is( $gp->hqTier, '1', "and the PLAYING track's tier is left alone" );

    # ...and it is loaded when the current track actually ends
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, $u1, 200, 1 );
    ok( scalar( grep { /^<PlaylistAdd\b/ } @sent ), 'the held track is loaded at end of track' );
    ok( scalar( grep { $_ eq '<PlaylistClear/>' } @sent ),
        'the ordinary way - a full four-command load' );
    ok( scalar( !grep { $_ eq 'playerEndOfStream' } @{ $gc->{calls} } ),
        'and that stop is NOT reported as end-of-stream - LMS is already streaming it' );
    ok( scalar( !grep { $_ eq 'playerBufferReady' } @{ $gc->{calls} } ),
        'nor BufferReady, which in the PLAYING row of the state table is _Invalid' );
}

{
    # A REFUSED pre-queue must not interrupt anything.  Reporting
    # StreamingFailed here leads to _SyncStopNext -> _getNextTrack -> play(),
    # and THAT play() is a full load - it would stop the track still playing
    # perfectly well.  The track is demoted to a normal load instead, which
    # runs at end of track and reports the failure properly if it is real.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f2', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });

    $gc->{calls} = [];
    @sent = ();
    _answer(0);     # the append -> Error

    ok( scalar( !grep { $_ eq 'playerStreamingFailed' } @{ $gc->{calls} } ),
        'a refused pre-queue is NOT reported as a failed load' );
    is( $gp->hqStarted, '1', 'and the track that is playing keeps playing' );
    is( $gp->hqNext && $gp->hqNext->{mode}, 'load',
        'it is demoted to a normal load at end of track instead' );
}

{
    # A hand-over cannot carry a seek: <Seek> acts on what is playing now, not
    # on a queued item.  The full load can, so it takes that call.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f0', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    @sent = (); @sentCb = ();
    $gc->{song} = $two;
    $gp->play({ controller => $gc, seekdata => { timeOffset => 30 } });
    ok( scalar( grep { $_ eq '<PlaylistClear/>' } @sent ),
        'an armed play() carrying a seek falls back to the full load' );
}

{
    # LMS discarding the track it handed us early - the playlist was edited, or
    # the user jumped.  <PlaylistClear/> keeps the item that is PLAYING and
    # drops the rest, which is exactly a flush here.  It was a no-op stub while
    # the playlist only ever held one item.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f1', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song} = $two;
    $gp->play({ controller => $gc });
    _answer();

    @sent = ();
    $gp->flush;
    is( join( ',', @sent ), '<PlaylistClear/>',
        'flush drops the pre-queued track from HQPlayer, keeping the one playing' );
    is( $gp->hqNext, '(undef)', 'and forgets it on our side too' );

    # LIVE FAILURE 2026-08-28.  _FlushGetNext drops the streaming song, calls
    # flush(), then immediately asks for a REPLACEMENT - so the next play() is
    # another hand-over.  Clearing the flag made that play() run the full load
    # over a track that was still playing: deleting the pre-queued track six
    # seconds into a twelve-second one cut it off and jumped forward.
    is( $gp->hqArmNext, '1',
        'flush RE-ARMS - the replacement LMS sends next is a hand-over, not a play-now' );

    @sent = (); @sentCb = ();
    $gc->{song} = $one;
    $gp->play({ controller => $gc });
    ok( scalar( !grep { $_ eq '<Stop/>' } @sent ),
        'so the replacement never stops the track that is playing' );
    ok( scalar( grep { /^<PlaylistAdd\b/ } @sent ), 'it is appended instead' );

    # nothing queued -> nothing sent, or an idle flush would clear a playlist
    # that a load is in the middle of building.  (The replacement appended just
    # above is dropped first, so this really is the empty case.)
    $gp->hqNext( undef );
    @sent = ();
    $gp->flush;
    is( join( ',', @sent ), '', 'a flush with nothing queued sends nothing' );
}


# ---------------------------------------------------------------------------
# fade_volume's DURATION.  It is not only the pause ramp: the sleep timer calls
# it with the whole fade-out time and stops the player from the completion
# callback.  Firing that immediately ended playback a full fade early.
# ---------------------------------------------------------------------------
print "-- fade duration --\n";
Slim::Utils::Timers::_reset();

my $stopped = 0;
$c->fade_volume(-0.3125, sub { $stopped++ });
is($stopped, '1', 'a pause ramp still completes immediately - it is what pauses');
is(Slim::Utils::Timers::_pending(), '0', 'and schedules nothing');

$stopped = 0;
$c->fade_volume(-60, sub { $stopped++ });
is($stopped, '0', 'a 60s sleep fade does NOT stop the player straight away');
is(Slim::Utils::Timers::_pending(), '1', 'it is deferred to a timer');
Slim::Utils::Timers::_fireAll();
is($stopped, '1', 'and completes when the fade would have ended');

# a cancelled sleep timer must not still stop the player later
$stopped = 0;
$c->fade_volume(-60, sub { $stopped++ });
$c->fade_volume(-0.3125, sub { });
is(Slim::Utils::Timers::_pending(), '0', 'a new fade cancels the pending one');
Slim::Utils::Timers::_fireAll();
is($stopped, '0', 'so the superseded fade never fires');

print "-- repeat must be OFF, or the player can never advance --\n";
# This shipped the other way round for one build.  <SetRepeat value="1"/> was
# added to stop HQPlayer walking off the end of a one-entry playlist
# (clPlaylist::GetAlbumGain(): trackn > last, unhandled, kills the daemon) -
# but with repeat ON the playlist never ends, `state` never reaches 0,
# end-of-track is never reported, and a full LMS queue plays its FIRST TRACK
# forever.  Verified live 2026-08-28: with repeat OFF a complete track ends at
# state 0, the daemon survives, and LMS advances by itself.  The overrun needed
# the old two-channel load, which no longer exists.
{
    my @sent;
    no warnings 'redefine';
    local *Plugins::HQPlayerBridge::Player::_send = sub { push @sent, $_[1] };

    $c->assertRepeatOff;
    is(scalar(@sent), '1', 'assertRepeatOff sends exactly one command');
    is($sent[0], '<SetRepeat value="0"/>', 'it is <SetRepeat value="0"/>, NOT value="1"');
}
# The whitelist gates what can reach the wire at all - a verb missing from it
# is dropped before it is sent, silently.
ok(do { open my $fh,'<','../HQPlayerBridge/Control.pm'; local $/; <$fh> } =~ /\bSetRepeat\b/,
   'SetRepeat is in Control.pm\'s %KNOWN, or the guard never leaves the plugin');

print "-- bitrate limit: the difference between FLAC and MP3 --\n";
# LMS caps an unset maxBitrate at 320kbps for anything that is not a
# Squeezebox, which silently transcodes every streamed track to MP3.  The pref
# must end up 0, and ONLY when the user has never chosen one.
{
    my $sp = Slim::Utils::Prefs::preferences('server');

    my $fresh = Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:70', 'paddr', 1.0, undef, 12, undef);
    my $cp    = $sp->client($fresh);

    is($cp->get('maxBitrate'), '(undef)', 'a new player starts with no bitrate limit set');
    is($fresh->initBitrateLimit, '1', 'initBitrateLimit acts when the pref is unset');
    is($cp->get('maxBitrate'), '0', 'and sets it to 0 - unlimited, so LMS streams FLAC');

    # TRAP: 0 is a real choice and is NOT undef.  Re-running must not treat an
    # already-set 0 as "never set" and must stay idempotent.
    is(scalar($fresh->initBitrateLimit), '(undef)', 'running it again does nothing');
    is($cp->get('maxBitrate'), '0', 'and leaves the value alone');

    # A deliberate user limit is theirs, not ours to overwrite.
    my $chosen = Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:71', 'paddr', 1.0, undef, 12, undef);
    my $cp2    = $sp->client($chosen);
    $cp2->set('maxBitrate', 320);
    is(scalar($chosen->initBitrateLimit), '(undef)', 'a chosen limit is not overridden');
    is($cp2->get('maxBitrate'), '320', 'and survives untouched');
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
