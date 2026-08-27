# Regression tests for the UPnP renderer client.
#
# Two failure modes that both look like "the player is there but will not
# play", and neither of which the syntax check can see:
#
#   * the device description is fetched when the player is created and again
#     when the control link comes UP.  Neither recurs, so a failed first fetch
#     (LMS and hqplayerd booting together) left the player permanently
#     unplayable while the control link stayed up.
#   * Play is retried because a Play issued too soon after SetAVTransportURI
#     genuinely fails - but retrying 8 times against a daemon that has stopped
#     answering meant 8 x the SOAP timeout of apparent buffering.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::UPnP;
use Slim::Utils::Timers;
use Time::HiRes ();

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# see the note on ok() in t_player.pl - a failed match returns the EMPTY LIST
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

my $U = 'Plugins::HQPlayerBridge::UPnP';

# The description fetch, with the daemon's answer under test control.
my $describeFails = 1;
my $describes     = 0;
{
    no warnings qw(redefine once);
    *Slim::Networking::SimpleAsyncHTTP::new = sub {
        my ( $class, $cb, $ecb ) = @_;
        return bless { cb => $cb, ecb => $ecb }, $class;
    };
    *Slim::Networking::SimpleAsyncHTTP::get = sub {
        my $self = shift;
        $describes++;
        return $self->{ecb}->( $self, 'connect timed out' ) if $describeFails;
        return $self->{cb}->( bless {}, 'FakeRootXML' );
    };
    package FakeRootXML;
    sub content {
        return '<root><service><serviceType>urn:schemas-upnp-org:service:AVTransport:3'
             . '</serviceType><controlURL>/control/av-transport</controlURL></service>'
             . '<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:3'
             . '</serviceType><controlURL>/control/rendering-control</controlURL></service></root>';
    }
}

print "-- describe keeps trying --\n";
Slim::Utils::Timers::_reset();

my $u = $U->new( ip => '10.0.0.5', name => 'HQPlayer' );
$u->describe;

is($u->ready, '0', 'a failed description leaves the renderer not ready');
is(Slim::Utils::Timers::_pending(), '1',
   'and schedules another attempt - nothing else ever would');

my $first = Slim::Utils::Timers::_timers()->[0];
Slim::Utils::Timers::_fireAll();
my $second = Slim::Utils::Timers::_timers()->[0];
ok($second && $second->{when} > $first->{when},
   'the retry interval backs off rather than hammering the daemon');

$describeFails = 0;
Slim::Utils::Timers::_fireAll();
is($u->ready, '1', 'and it recovers on its own once hqplayerd answers');
is(Slim::Utils::Timers::_pending(), '0', 'with no retry left running');

$describes = 0;
$u->describe;
is(Slim::Utils::Timers::_pending(), '0', 'a successful description schedules nothing');

$u->close;
$describeFails = 1;
$u->describe;
is($describes, '1', 'and a closed renderer stops fetching altogether');
is(Slim::Utils::Timers::_pending(), '0', 'leaving no timers behind for a player that has gone');

# ---------------------------------------------------------------------------
# Play retries.  The retry itself is deliberately blind to which error came
# back - a UPnP fault is an HTTP 500 whose errorCode is in the body, not in the
# status line the async client hands us - so what is bounded is the WAIT.
# ---------------------------------------------------------------------------
print "-- Play retries are bounded --\n";
Slim::Utils::Timers::_reset();

my @plays;
my $playFails = 1;
{
    no warnings 'redefine';
    *Plugins::HQPlayerBridge::UPnP::play = sub {
        my ( $self, $cb, $timeout ) = @_;
        push @plays, $timeout;
        return $cb->( $playFails ? ( undef, '500 Internal Server Error' ) : ( 'ok', undef ) );
    };
}

my $v = $U->new( ip => '10.0.0.5', name => 'HQPlayer' );

my ( $done, $err ) = ( 0, undef );
$v->playWhenReady( sub { $done++; $err = $_[1] } );

ok($plays[0] && $plays[0] < 15,
   'each attempt uses a short timeout, not the 15s general SOAP one');

my $rounds = Slim::Utils::Timers::_fireAll();
is($done, '1', 'a Play that never succeeds does fail the track, exactly once');
ok($err, 'and reports the error to the caller');
ok(scalar(@plays) <= 8, 'within the retry ceiling ('.scalar(@plays).' attempts)');

# The retry CEILING alone is not the bound that matters: 8 attempts against a
# daemon that has stopped answering is 8 x the per-attempt timeout.  A deadline
# across the whole loop is what turns two minutes of apparent buffering into a
# prompt failure, so test the deadline itself - the fake daemon above answers
# instantly, so no wall-clock time passes here on its own.
@plays = ();
( $done, $err ) = ( 0, undef );
$v->playWhenReady( sub { $done++; $err = $_[1] }, 1, Time::HiRes::time() - 1 );
is($done, '1', 'a Play loop past its deadline gives up at once');
is(scalar(@plays), '1', 'without burning the rest of the retry budget');
ok($err, 'and still reports the failure rather than hanging the track');

my $worst = Plugins::HQPlayerBridge::UPnP::PLAY_DEADLINE()
          + Plugins::HQPlayerBridge::UPnP::PLAY_TIMEOUT();
ok($worst <= 20,
   "so a dead daemon is reported in at most ${worst}s, not the ~2 minutes it used to take");

print "-- a cancelled Play does not come back --\n";
Slim::Utils::Timers::_reset();
@plays = ();

( $done, $err ) = ( 0, undef );
$v->playWhenReady( sub { $done++ } );
$v->cancelPlay;                      # the track was stopped or skipped
Slim::Utils::Timers::_fireAll();
is($done, '0', 'the completion callback for a cancelled track never fires');

# and a Play still in flight when the cancel happens is dropped too
Slim::Utils::Timers::_reset();
$done = 0;
$playFails = 0;
{
    no warnings 'redefine';
    *Plugins::HQPlayerBridge::UPnP::play = sub {
        my ( $self, $cb ) = @_;
        $self->cancelPlay;           # a stop lands while Play is in flight
        return $cb->( 'ok', undef );
    };
}
$v->playWhenReady( sub { $done++ } );
is($done, '0', 'nor does one that was cancelled while the daemon was answering');

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
