# Regression tests for player identity and the reported version.
#
# Both of these are about things that are NOT what they look like: the
# discovery "name" is a product string rather than an identity, and a version
# written down in a second place is a version that goes stale.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Plugin;

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# see the note on ok() in t_player.pl - a failed match returns the EMPTY LIST
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

my $ids = \&Plugins::HQPlayerBridge::Plugin::_idsFor;

# ---------------------------------------------------------------------------
# Player identity.
#
# The id is name-derived so that a DHCP move keeps the player's prefs, playlist
# and sync group.  But EVERY HQPlayer Embedded instance answers to the same
# product name, so on the name alone two instances are one player: each
# discovery round found the id it already had arriving with the other one's
# address, tore the player down and rebuilt it 60 seconds later - killing
# playback every round.
# ---------------------------------------------------------------------------
print "-- player identity --\n";

my $solo = $ids->([ { ip => '10.0.0.5', name => 'HQPlayerEmbedded' } ]);
my $moved = $ids->([ { ip => '10.0.0.9', name => 'HQPlayerEmbedded' } ]);

ok($solo->{'10.0.0.5'}->{id} =~ /^02(:[0-9a-f]{2}){5}$/,
   'the id is a locally-administered synthetic MAC');
is($moved->{'10.0.0.9'}->{id}, $solo->{'10.0.0.5'}->{id},
   'one instance keeps its id across a DHCP move - prefs and sync group survive');

my $pair = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded' },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded' },
]);

ok($pair->{'10.0.0.5'}->{id} ne $pair->{'10.0.0.7'}->{id},
   'two instances answering to the same product name are still two players');
ok($pair->{'10.0.0.5'}->{name} ne $pair->{'10.0.0.7'}->{name},
   'and are distinguishable in the player list');
ok($pair->{'10.0.0.5'}->{name} =~ /10\.0\.0\.5/,
   'the duplicate names carry the address');

my $named = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded' },
    { ip => '10.0.0.7', name => 'Study' },
]);
is($named->{'10.0.0.5'}->{id}, $solo->{'10.0.0.5'}->{id},
   'a genuinely unique name is unaffected by another instance appearing');
is($named->{'10.0.0.7'}->{name}, 'HQPlayer (Study)', 'and is named after itself');

# ---------------------------------------------------------------------------
# Version.  It used to be a hand-maintained constant, which sat at 0.2.3 while
# install.xml and repo.xml were at 0.2.7 - so the startup log and the settings
# page both named a build that had not been running for months.
# ---------------------------------------------------------------------------
print "-- version is read, not restated --\n";

my $install = do { local (@ARGV,$/) = ('../HQPlayerBridge/install.xml'); <> };
my $repo    = do { local (@ARGV,$/) = ('../repo.xml'); <> };

my ($iv) = $install =~ m{<version>([^<]+)</version>};
my ($rv) = $repo    =~ m{<plugin[^>]*\bversion="([^"]+)"};

ok($iv, "install.xml declares a version ($iv)");
is($rv, $iv, 'repo.xml agrees with install.xml');

Slim::Utils::PluginManager->_setTestData(
    'Plugins::HQPlayerBridge::Plugin', { version => $iv } );
is(Plugins::HQPlayerBridge::Plugin::version(), $iv,
   'the plugin reports the version LMS read out of install.xml');

my @copies;
for my $f (glob '../HQPlayerBridge/*.pm') {
    open my $fh, '<', $f or next;
    push @copies, "$f: $_" for grep { /^\s*use constant\s+\w*VERSION\b/ } <$fh>;
}
ok(!@copies, 'no module keeps its own copy of the version'.(@copies ? " (@copies)" : ''));

print "-- discovery: the cold start must not cost a whole ROUND_PERIOD --\n";
{
    # One lost multicast datagram used to cost a full minute of the plugin
    # looking broken: with nothing found there is no player at all, and the
    # retry was the same 60s as the steady-state round. Observed live -
    # the probe went out at 09:48:49 while hqplayerd happened to be
    # restarting, and the player did not appear until 09:49:49.
    require Plugins::HQPlayerBridge::Discovery;
    use IO::Socket::INET;

    no warnings 'redefine';
    # never touch the network from a unit test
    local *Plugins::HQPlayerBridge::Discovery::_round = sub { };

    Slim::Utils::Timers::_reset();
    Plugins::HQPlayerBridge::Discovery->start( sub { } );

    my @waits;
    for ( 1 .. 7 ) {
        Slim::Utils::Timers::_reset();
        my $t0 = Time::HiRes::time();
        Plugins::HQPlayerBridge::Discovery::_roundDone();
        my $t = Slim::Utils::Timers::_timers()->[0];
        push @waits, $t ? sprintf( '%.0f', $t->{when} - $t0 ) : 'none';
    }

    is(join(',', @waits), '2,4,8,16,32,60,60',
       'with nothing found it retries fast and doubles, capped at ROUND_PERIOD');

    # ...and once an instance answers it settles down. Seed %found the way a
    # real round does, by handing _reply an actual datagram on loopback.
    my $rx = IO::Socket::INET->new( Proto => 'udp', LocalAddr => '127.0.0.1', LocalPort => 0 );
    if ($rx) {
        my $tx = IO::Socket::INET->new( Proto => 'udp',
            PeerAddr => '127.0.0.1', PeerPort => $rx->sockport );
        $tx->send('<?xml version="1.0" encoding="UTF-8"?><discover name="HQPlayerEmbedded"'
                . ' result="OK" version="Signalyst HQPlayer Embedded 6">hqplayer</discover>');
        select( undef, undef, undef, 0.1 );
        Plugins::HQPlayerBridge::Discovery::_reply($rx);

        is(scalar @{ Plugins::HQPlayerBridge::Discovery::instances() }, '1',
           'the seeded reply is recorded as an instance');

        Slim::Utils::Timers::_reset();
        my $t0 = Time::HiRes::time();
        Plugins::HQPlayerBridge::Discovery::_roundDone();
        my $t = Slim::Utils::Timers::_timers()->[0];
        is($t ? sprintf('%.0f', $t->{when} - $t0) : 'none', '60',
           'once something answers it settles back to the steady-state period');
    }

    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
