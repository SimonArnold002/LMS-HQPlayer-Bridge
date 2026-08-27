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

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
