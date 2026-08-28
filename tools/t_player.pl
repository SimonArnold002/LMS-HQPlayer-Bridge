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

my ($playSub) = $src =~ /\nsub play \{(.*?)\n\}/s;
ok($playSub && $playSub =~ /bufferReady\(\s*0\s*\)/,
   'play() clears bufferReady so a stale 1 cannot start the next track early');
my ($stopSub) = $src =~ /\nsub stop \{(.*?)\n\}/s;
ok($stopSub && $stopSub =~ /bufferReady\(\s*0\s*\)/, 'stop() clears bufferReady');

# ReadyToStream in PLAYING/STREAMING is _NextIfMore: LMS answers it by
# streaming the NEXT song and calling play() again, clobbering the track that
# is playing.  We are not gapless, so it belongs at end-of-track only.
ok($src =~ /playerEndOfStream[^;]*;\s*\$controller->playerReadyToStream/s,
   'ReadyToStream is signalled only after EndOfStream, never alongside TrackStarted');

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

# helper: one pushed <Status/>, with the metadata child HQPlayer really sends
sub status {
    my ( $player, $state, $uri, $pos ) = @_;
    my $raw = qq{<Status state="$state" position="} . ( $pos // 0 ) . q{">}
            . ( $uri ? qq{<metadata bits="24" samplerate="96000" uri="$uri"/>} : '' )
            . q{</Status>};
    $player->_onStatus( { state => $state, position => $pos // 0 }, $raw );
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
is(join(',', @{$lc->{calls}}), 'playerTrackStarted,playerStatusHeartbeat',
   'and Started is signalled, exactly once, ahead of the heartbeat');
is($p->hqExpectStop, '0', 'the stop guard is disarmed only now');

# genuine end of track
$lc->{calls} = [];
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
