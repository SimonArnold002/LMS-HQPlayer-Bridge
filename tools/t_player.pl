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
sub ok { my($c,$n)=@_; $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

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
my $didl = $c->_didl( FakeSong->new($tr), 'http://lms:9000/music/447812/download.flac', 'audio/x-flac' );

ok($didl =~ /<DIDL-Lite\b/ && $didl =~ m{</DIDL-Lite>$}, 'DIDL is a complete document');
ok($didl =~ m{<dc:title>Colony &amp; &quot;Collapse&quot;</dc:title>}, 'title is XML-escaped');
ok($didl =~ m{<upnp:artist>Johanna &lt;Warren&gt;</upnp:artist>}, 'artist is XML-escaped');
ok($didl =~ m{<dc:creator>Johanna &lt;Warren&gt;</dc:creator>}, 'dc:creator mirrors artist');
ok($didl =~ m{<upnp:album>Gemini I</upnp:album>}, 'album present');
ok($didl =~ m{<upnp:albumArtURI>[^<]*/music/abc123/cover\.jpg</upnp:albumArtURI>},
   'albumArtURI points at the LMS cover - this is what lights up the endpoint');
# proxiedImage on a LOCAL path returns the "no artwork" placeholder, not the
# cover. That produced a blank icon on the endpoint; it must never come back.
ok($didl !~ m{/imageproxy/}, 'local cover URL is direct, NOT wrapped in the image proxy');

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
is($c->_coverURL($remote), '(undef)', 'no handler artwork -> no albumArtURI rather than a bad one');
ok($didl =~ m{protocolInfo="http-get:\*:audio/x-flac:\*"}, 'res protocolInfo carries the real mime');
ok($didl =~ m{duration="0:01:47"}, 'duration formatted as H:MM:SS');
ok($didl !~ /<upnp:albumArtURI></, 'no empty albumArtURI element');

# a track with nothing set must still yield valid DIDL, not broken XML
my $bare = FakeTrack->new({ title=>'X', id=>1, ct=>'flc' });
my $d2 = $c->_didl( FakeSong->new($bare), 'http://lms/x.flac', undef );
ok($d2 =~ m{</DIDL-Lite>$}, 'bare track still yields a complete document');
ok($d2 !~ /<upnp:artist>/ && $d2 !~ /<upnp:album>/, 'absent fields are omitted, not emitted empty');
ok($d2 =~ m{protocolInfo="http-get:\*:\*:\*"}, 'unknown mime falls back to a wildcard');


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

print "-- volume debounce --\n";
ok($src =~ /sub _flushVolume/, '_flushVolume exists');
my ($volSub) = $src =~ /\nsub volume \{(.*?)\n\}/s;
ok($volSub && $volSub !~ /setVolume/,
   'volume() does not push straight to UPnP - LMS fades it 6 times per pause');
ok($volSub && $volSub =~ /killTimers\([^)]*_flushVolume/,
   'volume() kills the pending flush before scheduling a new one');


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
{
    no warnings 'redefine';
    *Plugins::HQPlayerBridge::Player::_send      = sub { push @sent, $_[1] };
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
is(Plugins::HQPlayerBridge::Player::_lmsToDb(100), '0',    'LMS 100 is 0dB');
is(Plugins::HQPlayerBridge::Player::_lmsToDb(50),  '-50',  'one LMS step is 1dB');
is(Plugins::HQPlayerBridge::Player::_lmsToDb(0),   '-100', 'LMS 0 is the floor');
is(Plugins::HQPlayerBridge::Player::_lmsToDb(150), '0',    'over-range clamps to 0dB');
is(Plugins::HQPlayerBridge::Player::_dbToLms(-53), '47',   'and back again');
# int() truncates towards zero, and every dB figure here is negative
is(Plugins::HQPlayerBridge::Player::_dbToLms(-53.4), '47',  'a fractional dB rounds towards the nearer step, not towards zero');
is(Plugins::HQPlayerBridge::Player::_dbToLms(-999),'0',    'under-range clamps to 0');

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

# HQPlayer's own UI, or the endpoint's remote, moved it
@sent = (); @ex = ();
$c->hqVolDb(-40);   # somewhere else, so -53 below is a genuine change
$c->_onStatus({ state => 2, position => 5, volume => -53 }, '');
is(join(',', @ex), 'mixer volume 47', 'a change at HQPlayer is mirrored into LMS');
is(scalar(@sent), '0', 'and is NOT sent straight back out');
is($c->hqVolDb, '-53', 'hqVolDb tracks it');
$c->volume(47);
is(scalar(@sent), '0', 'the mixer command it triggers does not echo either');

@ex = ();
$c->_onStatus({ state => 2, position => 6, volume => -53 }, '');
is(scalar(@ex), '0', 'an unchanged volume in the status stream does nothing');

print "-- fade_volume --\n";
my $fired = 0;
$c->_tempVolume(0);
$c->fade_volume(-0.3125, sub { $fired++ });
is($fired, '1', 'the callback fires immediately - it is what actually pauses');
is($c->_tempVolume, '(undef)',
   'and the ramp temporary volume is cleared, or the slider reads zero after a resume');

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
