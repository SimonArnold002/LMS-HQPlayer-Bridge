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
# A CORPSE IS NOT AN INSTANCE.
#
# REPRODUCED on the rig 2026-09-20: hqplayerd moved from Wi-Fi to Ethernet with
# the daemon running.  It answers the multicast probe from ONE address only, so
# the new address arrived while the old one was still in %found inside
# INSTANCE_TTL - and one live address plus one corpse was counted as two
# instances.  The plain-id player was torn down for two address-qualified ones,
# taking the player's settings with it.
#
# These call _idsFor directly and assert its ANSWER, because that is the layer
# the fix lives at: a test driven through discovery would pass against a build
# where the gate does nothing.
# ---------------------------------------------------------------------------
print "-- identity: stale addresses --\n";

my $now = time();

my $ghosted = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now - 900, round => 1 },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded', lastSeen => $now,       round => 2 },
]);

is($ghosted->{'10.0.0.7'}->{id}, $solo->{'10.0.0.5'}->{id},
   'the address still answering keeps the PLAIN id - the settings move with it');
ok(!exists $ghosted->{'10.0.0.5'},
   'and the address that stopped answering is given no player at all');
ok(($ghosted->{'10.0.0.7'}->{name} || '') !~ /10\.0\.0\./,
   'the surviving player is not renamed with an address');

# CONTROL: the gate must not merge two instances that are both answering -
# that is the case the address-qualifying branch exists for.
my $both = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now,     round => 5 },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded', lastSeen => $now - 1, round => 5 },
]);

ok($both->{'10.0.0.5'}->{id} ne $both->{'10.0.0.7'}->{id},
   'two instances BOTH answering are still two players');

# The clock is not the test, the ROUND is: two replies from the same round a
# few seconds apart are both live, and an address one round old - however few
# seconds that is - is not.
my $sameRound = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now,     round => 9 },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded', lastSeen => $now - 3, round => 9 },
]);
ok($sameRound->{'10.0.0.5'}->{id} ne $sameRound->{'10.0.0.7'}->{id},
   'two replies in the SAME round are two instances, however far apart the clock says');
my $oneRoundOld = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now - 7, round => 8 },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded', lastSeen => $now,     round => 9 },
]);
is($oneRoundOld->{'10.0.0.7'}->{id}, $solo->{'10.0.0.5'}->{id},
   'an address only ONE round (~7s) old is left behind - the plain id moves on');
ok(!exists $oneRoundOld->{'10.0.0.5'},
   'and it gets no player - the 1.0.8 split cannot come back at the new pace');

# CONTROL: INSTANCE_TTL's grace is untouched.  A lone instance that has gone
# quiet - a daemon restart - keeps its id, and its player is held rather than
# rebuilt.
my $blip = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now - 900, round => 1 },
]);

is($blip->{'10.0.0.5'}->{id}, $solo->{'10.0.0.5'}->{id},
   'a lone instance gone quiet keeps its id - the TTL grace still holds it');

# A PARTIAL list is mid-round, so the instances that have not answered yet
# still carry the previous round's number and would all read as stale.
my $mid = $ids->([
    { ip => '10.0.0.5', name => 'HQPlayerEmbedded', lastSeen => $now - 900, round => 1 },
    { ip => '10.0.0.7', name => 'HQPlayerEmbedded', lastSeen => $now,       round => 2 },
], 1);

ok(!keys %$mid,
   'a PARTIAL list defers the whole group rather than judging it mid-round');

# ---------------------------------------------------------------------------
# AN ESTABLISHED PAIR IS NOT A DHCP MOVE.
#
# Found in review 2026-09-21: lastSeen cannot tell "the same daemon at an
# address it has left" from "a SECOND daemon that is briefly quiet", and
# hqplayerd restarts on any configuration change.  Collapsing a pair re-keyed
# the instance that did NOT restart onto the plain id mid-playback, tore down
# BOTH address-qualified players, and flipped it back a round later.  What
# separates the cases is what is already running, so _idsFor is handed the
# existing players - and _onInstances must hand them over, which is why the
# second half of this drives the real reconciliation and not just _idsFor.
# ---------------------------------------------------------------------------
print "-- identity: an established pair --\n";

my $idFor = \&Plugins::HQPlayerBridge::Plugin::_idFor;
my $PN    = 'HQPlayerEmbedded';
my ( $q5, $q7, $pl ) = ( $idFor->("$PN\@10.0.0.5"), $idFor->("$PN\@10.0.0.7"), $idFor->($PN) );

my $pairQuiet = $ids->([
    { ip => '10.0.0.5', name => $PN, lastSeen => $now,      round => 7 },
    { ip => '10.0.0.7', name => $PN, lastSeen => $now - 12, round => 6 },
], undef, { $q5 => 1, $q7 => 1 });

is($pairQuiet->{'10.0.0.5'}->{id}, $q5,
   'an established pair keeps its address-qualified id when one member misses a round');
is($pairQuiet->{'10.0.0.7'}->{id}, $q7,
   'and the quiet member keeps its player - INSTANCE_TTL grace holds for a PAIR too');

# CONTROL: with only the PLAIN player running it is a DHCP move, and the fix for
# that must still fire - otherwise "never collapse" would pass the two above.
my $moveUp = $ids->([
    { ip => '10.0.0.5', name => $PN, lastSeen => $now - 900, round => 1 },
    { ip => '10.0.0.9', name => $PN, lastSeen => $now,       round => 2 },
], undef, { $pl => 1 });

is($moveUp->{'10.0.0.9'}->{id}, $pl,
   'with only the plain player running, the live address still takes the plain id');
ok(!exists $moveUp->{'10.0.0.5'},
   'and the address a DHCP move left behind still gets no player');

# THROUGH THE REAL RECONCILIATION.  _create and _teardown are replaced only to
# record what would have happened; the registry and _onInstances are real.
{
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    my @ev;
    no warnings 'redefine';
    local *Plugins::HQPlayerBridge::Plugin::_create = sub {
        my ( $id, $inst, $name ) = @_;
        $reg->{$id} = { instance => $inst, name => $name };
        push @ev, "create $id";
    };
    local *Plugins::HQPlayerBridge::Plugin::_teardown = sub {
        my $id = shift;
        delete $reg->{$id} or return;
        push @ev, "teardown $id";
    };
    my $on = \&Plugins::HQPlayerBridge::Plugin::_onInstances;

    %$reg = ();
    my $t = $now;
    $on->([ { ip => '10.0.0.5', name => $PN, lastSeen => $t, round => 1 },
            { ip => '10.0.0.7', name => $PN, lastSeen => $t, round => 1 } ]);
    @ev = ();
    $t += 7;                                     # .7 restarting: misses one round
    $on->([ { ip => '10.0.0.5', name => $PN, lastSeen => $t,     round => 2 },
            { ip => '10.0.0.7', name => $PN, lastSeen => $t - 7, round => 1 } ]);
    is(join(', ', @ev) || 'nothing', 'nothing',
       'a pair member missing ONE round creates and tears down nothing');
    is(join(', ', sort keys %$reg), join(', ', sort ($q5, $q7)),
       'and both address-qualified players are still there');

    %$reg = ();
    $t = $now;
    $on->([ { ip => '10.0.0.5', name => $PN, lastSeen => $t, round => 1 } ]);
    @ev = ();
    # DHCP move: .5 left for .9. At Lyrion's 5s pace the address left behind is
    # only ONE ROUND - about 7 seconds - old when the new one answers. That is
    # the case the old 10-second allowance would have read as a second live
    # instance, splitting one daemon into two players (the 1.0.8 bug).
    $t += 7;
    $on->([ { ip => '10.0.0.5', name => $PN, lastSeen => $t - 7, round => 1 },
            { ip => '10.0.0.9', name => $PN, lastSeen => $t,     round => 2 } ]);
    is(join(', ', @ev), "teardown $pl, create $pl",
       'a DHCP move is ONE reconnect of the same plain-id player, nothing else');
    is($reg->{$pl} && $reg->{$pl}->{instance}->{ip}, '10.0.0.9',
       'and that player now follows the new address');

    # Lyrion forgets only a DISCONNECTED player. A player whose control link
    # is up is kept when discovery stops hearing it...
    %$reg = ();
    $reg->{$pl} = { instance => { ip => '10.0.0.5', name => $PN }, name => 'HQ',
                    link_of(1) };
    @ev = ();
    $on->([]);
    is(join(', ', @ev) || 'nothing', 'nothing',
       'a CONNECTED player is not removed when discovery stops hearing it');

    # ...and removed once the link is down.
    %{ $reg->{$pl} } = ( %{ $reg->{$pl} }, link_of(0) );
    $on->([]);
    is(join(', ', @ev), "teardown $pl",
       'a DISCONNECTED player that discovery stopped hearing is removed');

    # A pair shrinking to one re-keys the survivor onto the plain id. Its old
    # address-qualified player is connected, but its address now belongs to
    # the new id: keeping it too would put TWO players on one HQPlayer. The
    # switched-off member keeps its player until its own link drops.
    %$reg = ();
    $reg->{$q5} = { instance => { ip => '10.0.0.5', name => $PN }, name => 'HQ .5',
                    link_of(1) };
    $reg->{$q7} = { instance => { ip => '10.0.0.7', name => $PN }, name => 'HQ .7',
                    link_of(1) };
    @ev = ();
    $on->([ { ip => '10.0.0.5', name => $PN, lastSeen => $now, round => 9 } ]);
    is(join(', ', sort @ev), join(', ', sort ("create $pl", "teardown $q5")),
       'a re-keyed survivor is replaced, not duplicated');
    ok(exists $reg->{$q7}, 'and the quiet member is kept while its link is up');
    is(scalar(grep { ( $_->{instance} || {} )->{ip} eq '10.0.0.5' } values %$reg), 1,
       'exactly ONE player on the surviving address');
    %$reg = ();
}

{
    package LinkCtl;
    sub new { my ( $c, $up, $proven ) = @_; bless { up => $up, proven => $proven // $up }, $c }
    sub connected { $_[0]->{up} }
    sub proven    { $_[0]->{proven} }

    # A bridge's player, shaped as production builds it: the SAME control
    # object on the bridge and on the player, and `connected` answered by the
    # real Player::connected.
    package LinkClient;
    sub new       { bless { ctl => $_[1] }, $_[0] }
    sub hqControl { $_[0]->{ctl} }
    sub connected { Plugins::HQPlayerBridge::Player::connected( $_[0] ) }
}

# control => ..., client => ... for a bridge whose link is ($up, $proven)
sub link_of { my $c = LinkCtl->new(@_); return ( control => $c, client => LinkClient->new($c) ) }

# the same, with a feed player (FeedClient, defined with the feed tests)
sub feed_link { my $c = LinkCtl->new(@_); my $cl = FeedClient->new({}); $cl->{ctl} = $c; return ( control => $c, client => $cl ) }

is(Plugins::HQPlayerBridge::Discovery::INSTANCE_TTL(), 300,
   "an instance is forgotten after Lyrion's 300s (\$forget_disconnected_time)");

# ---------------------------------------------------------------------------
# CONNECTED FOLLOWS THE CONTROL LINK, as a Lyrion player's follows its socket.
# It was `tcpsock`, a literal 1, so a dead HQPlayer stayed "connected" - and
# listed in Material, which shows only connected players - until it was
# forgotten 300s later. Simon: "it should follow LMS players".
# ---------------------------------------------------------------------------
print "-- connected is the PROVEN control link --\n";
{
    require Plugins::HQPlayerBridge::Player;
    my $p = Plugins::HQPlayerBridge::Player->new('02:de:ad:00:00:01', 'paddr', 1.0, undef, 12, undef);
    $p->tcpsock(1);    # exactly as _create sets it

    is($p->connected, 0, 'no control link yet: not connected (tcpsock is 1 and does not count)');
    $p->hqControl( LinkCtl->new(1, 0) );
    is($p->connected, 0, 'accepted but never answered: NOT connected (hqplayerd accepts, then drops, with no endpoint)');
    $p->hqControl( LinkCtl->new(1, 1) );
    is($p->connected, 1, 'HQPlayer has replied: connected');
    $p->hqControl( LinkCtl->new(0, 0) );
    is($p->connected, 0, 'link down: NOT connected - Material drops it from the list');
}

print "-- Lyrion's disconnect/reconnect bookkeeping, on the PROVEN link --\n";
{
    my @ev;
    no warnings qw(redefine once);
    local *Slim::Control::Request::notifyFromArray = sub { push @ev, "notify $_[1]->[1]" };

    my $reg  = Plugins::HQPlayerBridge::Plugin::bridges();
    my $ctrl = FakeController->new( \@ev );
    my $cl   = FakeClient->new( \@ev, $ctrl );
    %$reg = ( 'x' => { client => $cl, instance => {} } );
    $cl->{power} = 1;

    # THE ACCEPT-THEN-DROP CYCLE (NAA off, expired trial): no reply, so no
    # new/reconnect, no disconnect, no sync-group churn - only the polling pair.
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onLinkState( 'x', 1 );
    Plugins::HQPlayerBridge::Plugin::_onLinkState( 'x', 0, 0 );
    is(join(', ', @ev), 'linkNew 1, refreshInfo, startPolling, stopPolling',
       'accepted then dropped with no reply: nothing announced, sync group untouched');
    # AND NOTHING TOUCHES THE HELD VOLUME. _onLinkProven used to release it on
    # any first reply, which is looser than the truth: a slider move made after
    # the link came up queues its <Volume> behind refreshInfo's commands, so the
    # first reply can be VolumeRange's while that <Volume> is still queued. The
    # hold is released by its OWN reply - Player::_volumeDelivered, pinned in
    # t_player.pl - so no volume hook may appear here at all.
    is(scalar(grep { /volume/i } @ev), '0',
       'and nothing here releases a volume held over the outage');

    # EVERY proof is a RECONNECT: `client new` came from LMS's own constructor,
    # and _create marked the player disconnected straight after. The
    # announcement goes out BEFORE playerActive, so nothing there can lose it.
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onLinkProven('x');
    is(join(', ', @ev), 'disconnected 0, notify reconnect, playerActive',
       'first proof, powered: announced as a reconnect, then made active');

    # a proven link going down: flagged and announced - and NOT playerInactive,
    # which would send <Stop/> down the dead link and reconnect ahead of the backoff
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onLinkState( 'x', 0, 1 );
    is(join(', ', @ev), 'stopPolling, disconnected 1, notify disconnect',
       'down after proven: flagged and announced, NO playerInactive (no command on a dead link)');

    # later proofs are RECONNECTS too
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onLinkProven('x');
    is(join(', ', @ev), 'disconnected 0, notify reconnect, playerActive',
       'a later proof is a reconnect');

    # playerActive DYING (it can run the whole _JumpToTime -> play() path) must
    # not unwind the proof: the announcement is already out, and nothing escapes
    $ctrl->{die} = 1;
    @ev = ();
    my $ok = eval { Plugins::HQPlayerBridge::Plugin::_onLinkProven('x'); 1 };
    ok($ok, 'a playerActive that dies does not escape _onLinkProven');
    is(join(', ', @ev), 'disconnected 0, notify reconnect, playerActive',
       'and the reconnect was announced regardless');
    $ctrl->{die} = 0;

    # CONTROL: proven but powered off stays out of the active set
    $cl->{power} = 0;
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onLinkProven('x');
    is(join(', ', @ev), 'disconnected 0, notify reconnect',
       'proven, powered off: reconnected but NOT made active');

    # FORGOTTEN in LMS. The notification arrives AFTER forgetClient has deleted
    # the client, so ->client is undef in production - modelled that way here,
    # or the test passes against a handler that can never fire.
    my @torn;
    local *Plugins::HQPlayerBridge::Plugin::_teardown = sub { push @torn, $_[0]; delete $reg->{ $_[0] } };
    Plugins::HQPlayerBridge::Plugin::_onForget( FakeRequest->new('someone-else') );
    is(scalar @torn, 0, 'a forget for a player the bridge does not own is ignored');
    Plugins::HQPlayerBridge::Plugin::_onForget( FakeRequest->new('x') );
    is(join(', ', @torn), 'x', 'forgetting a bridge player drops its bridge, though ->client is already gone');
    %$reg = ();
}

print "-- _create: the constructor said `new`, so the player is marked disconnected at once --\n";
{
    my @ev;
    no warnings qw(redefine once);
    local *Slim::Control::Request::notifyFromArray = sub { push @ev, "notify $_[1]->[1]" };
    local *Plugins::HQPlayerBridge::Control::connect = sub { push @ev, 'connect' };
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    %$reg = ();
    Plugins::HQPlayerBridge::Plugin::_create( '02:de:ad:00:00:03',
        { ip => '10.9.9.9', name => 'Made' }, 'HQPlayer (Made)' );
    my $c = ( $reg->{'02:de:ad:00:00:03'} || {} )->{client};
    ok($c, 'the player was created');
    is($c ? $c->disconnected : '(none)', 1, 'and reads disconnected until HQPlayer replies');
    is(join(', ', @ev), 'notify new, notify disconnect, connect',
       'the constructor announces `new`, then `disconnect` is queued BEFORE the link is opened');
    is($c ? $c->connected : '(none)', 0, 'CONTROL: connected is 0 too - the two agree');
    %$reg = ();
}

print "-- forgetClient clears the literal tcpsock first (LMS < 9.1 dies on it) --\n";
{
    my $seen;
    no warnings qw(redefine once);
    local *Slim::Player::Client::forgetClient = sub { $seen = defined $_[0]->tcpsock ? $_[0]->tcpsock : 'undef' };
    my $p = Plugins::HQPlayerBridge::Player->new('02:de:ad:00:00:02', 'paddr', 1.0, undef, 12, undef);
    $p->tcpsock(1);
    my $closed = 0;
    $p->hqControl( CloseCtl->new(\$closed) );
    $p->forgetClient;
    is($seen, 'undef', 'LMS forgetClient sees no tcpsock, so slimproto_close is never handed the 1');
    is($closed, 1, 'and the control link is CLOSED, so a connect started by the forget\'s Stop ends there');

    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    $src =~ s/^\s*#.*$//mg;
    ok(scalar( $src !~ /Slim::Player::Client::forgetClient\(/ ),
       'every forget in Plugin.pm is a METHOD call, so the override runs');
}

print "-- _teardown stops only a controller the player has to itself --\n";
{
    # The REAL _teardown, which no other block here drives. controller->stop
    # is StreamingController::_Stop, over EVERY player in a sync group; LMS's
    # forgetClient runs unsync first, which stops just the one it removes.
    package TdCtl;
    sub new        { bless { n => $_[1], ev => $_[2] }, $_[0] }
    sub allPlayers { return ( (1) x $_[0]->{n} ) }
    sub stop       { push @{ $_[0]->{ev} }, 'controller stop' }
    package TdClient;
    sub new           { bless { ctl => $_[1], ev => $_[2] }, $_[0] }
    sub controller    { $_[0]->{ctl} }
    sub _stopPolling  {}
    sub forgetClient  { push @{ $_[0]->{ev} }, 'forgetClient' }
    package main;

    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    for my $case ( [ 1, 'controller stop, forgetClient', 'a solo player: its controller is stopped, as before' ],
                   [ 2, 'forgetClient', 'in a group: the group is NOT stopped, forgetClient\'s unsync stops just this one' ] ) {
        my @ev;
        %$reg = ( td => { client => TdClient->new( TdCtl->new( $case->[0], \@ev ), \@ev ) } );
        Plugins::HQPlayerBridge::Plugin::_teardown('td');
        is(join(', ', @ev), $case->[1], $case->[2]);
        ok(!exists $reg->{td}, '  and the bridge is gone');
    }
    %$reg = ();
}

print "-- the removal pass reads PROVEN, as Player::connected does --\n";
{
    my @ev;
    no warnings qw(redefine once);
    local *Plugins::HQPlayerBridge::Plugin::_teardown = sub { push @ev, "teardown $_[0]" };
    local *Plugins::HQPlayerBridge::Plugin::_create   = sub { push @ev, "create $_[0]" };
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    %$reg = ( 'gone' => { instance => { ip => '10.9.0.1', name => 'Gone' }, name => 'HQ gone',
                          link_of(1, 0) } );
    Plugins::HQPlayerBridge::Plugin::_onInstances([]);
    is(join(', ', @ev), 'teardown gone',
       'accepted but never answering, and gone from discovery: removed');
    %$reg = ( 'live' => { instance => { ip => '10.9.0.2', name => 'Live' }, name => 'HQ live',
                          link_of(1, 1) } );
    @ev = ();
    Plugins::HQPlayerBridge::Plugin::_onInstances([]);
    is(join(', ', @ev) || 'nothing', 'nothing', 'CONTROL: a proven link is still kept');
    %$reg = ();
}

{
    package FakeController;
    sub new { bless { ev => $_[1], only => 0 }, $_[0] }
    sub playerActive     { push @{ $_[0]->{ev} }, 'playerActive'; die "boom\n" if $_[0]->{die} }
    sub playerInactive   { push @{ $_[0]->{ev} }, 'playerInactive' }
    sub onlyActivePlayer { $_[0]->{only} }

    package FakeClient;
    sub new { bless { ev => $_[1], ctrl => $_[2], id => $_[3] // 'x', power => 0 }, $_[0] }
    sub id           { $_[0]->{id} }
    sub controller   { $_[0]->{ctrl} }
    sub power        { $_[0]->{power} }
    sub disconnected { push @{ $_[0]->{ev} }, "disconnected $_[1]" }
    sub refreshInfo  { push @{ $_[0]->{ev} }, 'refreshInfo' }
    # The startup-volume latch. Recorded as an event because WHERE it is armed
    # is the whole point: on link-up, never on a track load.
    sub hqVolLinkNew { push @{ $_[0]->{ev} }, "linkNew $_[1]" }
    sub _startPolling { push @{ $_[0]->{ev} }, 'startPolling' }
    sub _stopPolling  { push @{ $_[0]->{ev} }, 'stopPolling' }

    package LoopReq;
    sub new           { bless { loop => {} }, $_[0] }
    sub isQuery       { 1 }
    sub client        { undef }
    sub addResultLoop { $_[0]->{loop}{ $_[2] }{ $_[3] } = $_[4] }
    sub addResult     {}
    sub setStatusDone {}

    package CloseCtl;
    sub new   { bless { n => $_[1] }, $_[0] }
    sub close { ${ $_[0]->{n} }++ }

    package FakeRequest;
    # as in production after `client forget`: the id survives, the client does not
    sub new { bless { id => $_[1] }, $_[0] }
    sub clientid { $_[0]->{id} }
    sub client   { undef }
}

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

print "-- discovery: the cold start must not cost a whole round --\n";
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

    is(join(',', @waits), '2,4,8,10,10,10,10',
       'with nothing found it looks again at 2, 4, 8, then every 10s');

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
        is($t ? sprintf('%.0f', $t->{when} - $t0) : 'none', '10',
           'an instance known but no way to ask whether it is connected - 10s, never idle');
    }

    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
}

print "-- discovery: how often to look is decided by the CONTROL LINK --\n";
{
    # An instance that is connected needs no finding, and one that is not -
    # powered off, asleep, moved - has to be found again quickly. Once every
    # known one is connected only a NEW HQPlayer is left to find, so it looks
    # every IDLE_PERIOD (15s). It was ten minutes until 2026-09-23, which hid a
    # second HQPlayer for that long, then a flat 5s, which filled HQPlayer's
    # log with discovery lines.
    require Plugins::HQPlayerBridge::Discovery;

    no warnings 'redefine';
    local *Plugins::HQPlayerBridge::Discovery::_round = sub { };

    my $up = 1;
    my $seen;

    my $wait = sub {
        Slim::Utils::Timers::_reset();
        my $t0 = Time::HiRes::time();
        Plugins::HQPlayerBridge::Discovery::_roundDone();
        my $t = Slim::Utils::Timers::_timers()->[0];
        return $t ? sprintf( '%.0f', $t->{when} - $t0 ) : 'none';
    };

    Slim::Utils::Timers::_reset();
    Plugins::HQPlayerBridge::Discovery->start(
        sub { $seen = $_[1] ? 'partial' : 'full' },
        sub { $up },
    );

    # Seed one instance the way a real round does.
    my $rx = IO::Socket::INET->new( Proto => 'udp', LocalAddr => '127.0.0.1', LocalPort => 0 );
    if ($rx) {
        my $tx = IO::Socket::INET->new( Proto => 'udp',
            PeerAddr => '127.0.0.1', PeerPort => $rx->sockport );
        $tx->send('<?xml version="1.0" encoding="UTF-8"?><discover name="HQPlayerEmbedded"'
                . ' result="OK" version="Signalyst HQPlayer Embedded 6">hqplayer</discover>');
        select( undef, undef, undef, 0.1 );
        Plugins::HQPlayerBridge::Discovery::_reply($rx);

        is($seen, 'partial',
           'a NEW instance is announced the moment it answers, not at the end of the round');
        is($seen eq 'partial' ? 1 : 0, 1,
           'and it is flagged partial, so the caller must not remove anyone on it');

        $up = 1;
        is($wait->(), '15', 'every known instance connected - every 15s, not ten minutes');

        $up = 0;
        is($wait->(), '10', 'a link that is down puts it straight back on 10s');

        $up = 1;
        is($wait->(), '15', 'and back to 15s once the link is up again');
    }

    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
}

print "-- discovery hearing a disconnected HQPlayer reconnects it now --\n";
{
    package PokeCtl;
    sub new { bless { pokes => 0 }, shift } sub reconnectNow { $_[0]->{pokes}++ }
    sub connected { 0 } sub proven { 0 }
    package main;

    no warnings qw(redefine once);
    local *Plugins::HQPlayerBridge::Plugin::_create   = sub { };
    local *Plugins::HQPlayerBridge::Plugin::_teardown = sub { };
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    my %keep = %$reg;
    my $id   = Plugins::HQPlayerBridge::Plugin::_idFor('PokeTest');
    my $ctl  = PokeCtl->new;
    %$reg = ( $id => { instance => { ip => '10.7.0.5', name => 'PokeTest' }, name => 'HQ',
                       control => $ctl, client => LinkClient->new($ctl) } );
    my $now = Plugins::HQPlayerBridge::Discovery::round();

    Plugins::HQPlayerBridge::Plugin::_onInstances(
        [ { ip => '10.7.0.5', name => 'PokeTest', round => $now } ] );
    is($ctl->{pokes}, 1, 'an instance that answered THIS round has its link retried now');

    Plugins::HQPlayerBridge::Plugin::_onInstances(
        [ { ip => '10.7.0.5', name => 'PokeTest', round => $now - 1 } ] );
    is($ctl->{pokes}, 1, 'CONTROL: one only remembered from an earlier round is not');

    %$reg = %keep;
}

print "-- one connected test: Player::connected, nowhere else --\n";
{
    # Plugin.pm used to repeat `control && control->proven` in three places
    # (both signalPathFor fields and the removal guard). Round 2 of the
    # 1.0.17 review had to fix copies that had drifted to the ACCEPT. Every
    # reader now asks the player.
    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    $src =~ s/^\s*#.*$//mg;
    my @copies = $src =~ /(->proven\b)/g;
    is(scalar @copies, 0, 'Plugin.pm has no copy of the connected test of its own');
}

print "-- discovery: the connected answer is the player's own --\n";
{
    # Discovery goes quiet (IDLE_PERIOD) only on this answer, so it must be the
    # one Material shows - Player::connected - and nothing else.
    package FakeConn; sub new { bless { c => $_[1] }, $_[0] } sub connected { $_[0]->{c} }
    package main;

    my $br = Plugins::HQPlayerBridge::Plugin::bridges();
    local $br->{'02:00:00:00:00:99'} = { instance => { ip => '10.9.9.9' }, client => FakeConn->new(1) };

    is(Plugins::HQPlayerBridge::Plugin::_linkUpFor('10.9.9.9'), 1,
       'a connected player at that address reads connected');
    $br->{'02:00:00:00:00:99'}->{client} = FakeConn->new(0);
    is(Plugins::HQPlayerBridge::Plugin::_linkUpFor('10.9.9.9'), 0,
       'a disconnected one does not');
    is(Plugins::HQPlayerBridge::Plugin::_linkUpFor('10.9.9.8'), 0,
       'an address with no player yet does not');

    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    ok(scalar( $src =~ /Discovery->start\(\s*\\&_onInstances,\s*\\&_linkUpFor\s*\)/ ),
       'and it is what the plugin hands discovery');

    # One probe a round: nothing reschedules _probe inside a round.
    my $dsrc = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Discovery.pm'); <> };
    $dsrc =~ s/^\s*#.*$//mg;
    ok(scalar( $dsrc !~ /setTimer\([^;]*\\&_probe/ ), 'a round sends one probe, not a burst');
}

print "-- reconcile: a partial list must never remove a player --\n";
{
    # The immediate announce hands the caller a list with ONE instance in it
    # while the others have not answered yet.  Read as a complete round that
    # says "everyone else is gone", and two seconds of a slow reply would cost
    # another player its playlist and sync group.
    my %b = %{ Plugins::HQPlayerBridge::Plugin::bridges() };

    Plugins::HQPlayerBridge::Plugin::_onInstances(
        [ { ip => '10.0.0.1', name => 'HQPlayerEmbedded' } ], 1 );

    is(scalar keys %{ Plugins::HQPlayerBridge::Plugin::bridges() } >= scalar keys %b ? 1 : 0,
       1, 'a partial round removes nothing');
}

print "-- the watchdog is armed by the LINK, not by a track --\n";
{
    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    $src =~ s/^\s*#.*$//mg;

    my ($ls) = $src =~ /sub _onLinkState \{(.*?)\n\}/s;

    is( ( defined $ls && $ls =~ /_startPolling/ ? 'yes' : 'no' ),
        'yes', 'a link coming up arms the status subscription' );

    is( ( defined $ls && $ls =~ /_stopPolling/ ? 'yes' : 'no' ),
        'yes', 'and a link going down stops it' );

    is( ( defined $ls && $ls =~ /else\s*\{[^}]*_stopPolling/s ? 'yes' : 'no' ),
        'yes', 'the stop is on the DOWN branch, not next to the start' );
}

# The settings page tidies the source container in PERL, not in the template:
# a Template::Toolkit vmethod that throws takes the whole page down, and a
# broken settings page fails quietly in LMS.
print "-- the settings page's mime tidy --\n";
is(Plugins::HQPlayerBridge::Plugin::_shortMime('audio/x-flac'), 'FLAC',
   'audio/x-flac reads as FLAC');
is(Plugins::HQPlayerBridge::Plugin::_shortMime('audio/mpeg'), 'MPEG',
   'and a subtype with no x- prefix still loses the audio/');
is(Plugins::HQPlayerBridge::Plugin::_shortMime(undef), '(undef)',
   'and no mime at all is undef, not an empty string the template would print');


# THE MATERIAL/APPS FEED.  There is no settings page any more - nothing in this
# plugin is configurable, so the only thing one was ever good for was reading
# numbers, and it could not keep them current.
#
# A BROWSE LIST CANNOT REFRESH ITSELF IN MATERIAL. Settled from Material's own
# source: every `refreshList` trigger in browse-page.js is a USER ACTION inside
# Material, and no LMS notification is wired to it. So these rows are a
# SNAPSHOT, permanently, and the live reading lives on its own page.
print "-- the apps feed --\n";
{
    package FeedClient;
    sub new { bless { path => $_[1] || {} }, $_[0] }
    sub hqRate { '44100' } sub hqBits { '16' } sub hqMime { 'audio/x-flac' }
    sub hqPath { $_[0]->{path} }
    sub hqTier { 1 }
    sub hqTransport { 5 }
    sub id { "02:fe:ed:00:00:01" }
    sub hqControl { $_[0]->{ctl} ||= FeedCtl->new }
    sub connected { Plugins::HQPlayerBridge::Player::connected( $_[0] ) }

    package FeedCtl;
    sub new { bless {}, shift } sub connected { 1 } sub proven { 1 }
}

my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
%$reg = ( 'aa' => {
    name     => 'HQPlayer (Test)',
    control  => FeedCtl->new,
    instance => { ip => '10.0.0.5' },
    client   => FeedClient->new({
        active_rate => '96000', active_bits => '24', active_mode => 'PCM',
        active_filter => 'poly-sinc-gauss-long', active_shaper => 'TPDF',
        process_speed => '30.306',
    }),
} );

my $feed;
Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );

ok(ref $feed eq 'HASH', 'the feed calls its callback with a hash');
my @i = @{ $feed->{items} || [] };

is($i[0]->{name}, 'PLUGIN_HQPLAYER_LIVE_TITLE', 'the live-view row is FIRST');
is($i[0]->{type}, 'link', 'and it is a link, so Material opens it');

# The route is Live.pm's own constant, not a copy of the string. A duplicated
# literal is exactly how a working link rots into a 404.
is($i[0]->{weblink}, Plugins::HQPlayerBridge::Live::PATH(),
   'and it weblinks to the path Live.pm actually registers');

# THE ROWS SIMON DID NOT ASK FOR AND MUST NOT COME BACK.
is(scalar( grep { ($_->{nextWindow} // '') eq 'refresh' } @i ), '0',
   'there is NO manual Refresh row - a live view was asked for, not a button');
is(scalar( grep { ($_->{weblink} // '') =~ /settings/ } @i ), '0',
   'and nothing links to a settings page - there is not one any more');

# WITH A BRIDGE PRESENT there is nothing to say about waiting - the waiting rows
# below must not appear here as well.
is(scalar( grep { ($_->{name} // '') eq 'PLUGIN_HQPLAYER_LIVE_WAITING' } @i ), '0',
   'a discovered bridge draws no waiting row');

my @status = @i[1 .. $#i];
is(scalar( grep { ($_->{type} // '') ne 'text' } @status ), '0',
   'every status row is type=text - a non-playable row with no action gets one FORCED on by XMLBrowser');

my $all = join '|', map { $_->{name} } @status;

# THE APPS LIST SHOWS SETTINGS, NOT THE SIGNAL PATH. This list is a snapshot
# that can never refresh itself (Material has no plugin-reachable path to
# re-render a browse page), so what belongs here is what is still TRUE a minute
# later: the things you would go into HQPlayer to change. The moving signal
# path - source and output formats per track, a speed that changes every
# second - is the live page's job.
ok(scalar( $all =~ /PLUGIN_HQPLAYER_MODE: PCM/ ),                       'the output mode is reported');
ok(scalar( $all =~ /PLUGIN_HQPLAYER_FILTER: poly-sinc-gauss-long/ ),    'and the filter');
ok(scalar( $all =~ /PLUGIN_HQPLAYER_SHAPER: TPDF/ ),                    'and the shaper');
ok(scalar( $all =~ /PLUGIN_HQPLAYER_OUTPUT: PLUGIN_HQPLAYER_TRANSPORT_ID 5/ ),
   'and the transport, labelled Output with the id as its VALUE');
ok(scalar( $all =~ /PLUGIN_HQPLAYER_CONNECTED - 10\.0\.0\.5:4321/ ),   'and the link state with the address');

# THE CONTROL. Without these the change could be additive and every assertion
# above would still pass while the stale signal path stayed on the page.
ok(scalar( $all !~ /PLUGIN_HQPLAYER_SOURCE:/ ),
   'the per-track SOURCE format is gone - it moves, so it belongs on the live page');
ok(scalar( $all !~ /PLUGIN_HQPLAYER_OUTFORMAT:/ ), 'and so is the output format');
ok(scalar( $all !~ /30\.3/ ),
   'and the processing SPEED is gone - a number that changes every second has no business in a snapshot');

# A player that has reported nothing must not produce empty rows.
$reg->{aa}->{client} = FeedClient->new({});
{
    no warnings 'redefine';
    local *FeedClient::hqRate = sub { undef };
    local *FeedClient::hqMime = sub { undef };
    Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
}
is(scalar( grep { ($_->{name} // '') =~ /:\s*$/ } @{ $feed->{items} } ), '0',
   'a silent instance produces no half-empty rows');

%$reg = ();


# THE SIGNAL PATH IS FORMATTED ONCE. Three surfaces show these strings - the
# Apps feed, the settings page and the `signalpath` poll - and they must never
# disagree about what "Processing" reads like, so all three call signalPathFor.
print "-- signalPathFor: one formatter, three surfaces --\n";
{
    package PathClient;
    sub new  { bless { p => $_[1], tier => $_[2] }, $_[0] }
    sub hqRate { '44100' } sub hqBits { '16' } sub hqMime { 'audio/x-flac' }
    sub hqPath { $_[0]->{p} } sub hqTier { $_[0]->{tier} }
    sub hqTransport { $_[0]->{tr} }
    sub hqControl { $_[0]->{ctl} ||= PathCtl->new }
    sub connected { Plugins::HQPlayerBridge::Player::connected( $_[0] ) }
    package PathCtl;
    sub new { bless {}, shift } sub connected { 1 } sub proven { 1 }
}

my $bridge = {
    name     => 'HQPlayer (Test)',
    control  => PathCtl->new,
    instance => { ip => '10.0.0.5' },
    client   => PathClient->new({
        active_rate => '96000', active_bits => '24', active_mode => 'PCM',
        active_filter => 'poly-sinc-gauss-long', active_shaper => 'TPDF',
        process_speed => '30.306',
    }, 1),
};

my $p = Plugins::HQPlayerBridge::Plugin::signalPathFor( undef, $bridge );
is($p->{source}, '44100 Hz / 16 bit FLAC', 'source is the <metadata/> child half');
is($p->{output}, '96000 Hz / 24 bit PCM',  'output is the <Status/> root half');
# ONE FIELD PER FACT. These used to be joined into a single `processing` line
# with the labels baked into the VALUE, which left the live page rendering a
# sentence it could not lay out. Three fields, three rows.
is($p->{filter}, 'poly-sinc-gauss-long', 'filter is its own field');
is($p->{shaper}, 'TPDF',                 'shaper is its own field');
is($p->{speed},  '30.3PLUGIN_HQPLAYER_SPEED',
   'and the speed is its own field, carrying only its unit');
ok(!exists $p->{processing},
   'the joined processing line is GONE - two ways to say one thing is how they drift');
is($p->{tier}, 'PLUGIN_HQPLAYER_TIER1', 'the tier prose follows hqTier');
is($p->{connected}, 'PLUGIN_HQPLAYER_CONNECTED - 10.0.0.5:4321', 'and the link state carries the address');
{
    # an ACCEPT that has not replied is not "Connected" - the same test as
    # Player::connected, so the feed and Material cannot disagree
    my $acc = { name => 'HQPlayer (Test)', instance => { ip => '10.0.0.5' }, feed_link(1, 0) };
    is(Plugins::HQPlayerBridge::Plugin::signalPathFor(undef, $acc)->{connected},
       'PLUGIN_HQPLAYER_DISCONNECTED - 10.0.0.5:4321',
       'accepted but never answered reads DISCONNECTED, as Material shows it');
    is(Plugins::HQPlayerBridge::Plugin::signalPathFor(undef, $acc)->{up}, 0,
       'and its `up` flag is 0 - the live page reads the flag, not the string');
    %$acc = ( %$acc, feed_link(1, 1) );
    is(Plugins::HQPlayerBridge::Plugin::signalPathFor(undef, $acc)->{up}, 1,
       'CONTROL: a proven link is `up` 1');

    # and the QUERY carries it - the live page reads the query, not signalPathFor
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    my %keep = %$reg;
    %$reg = ( 'q1' => { %$acc, feed_link(1, 0) } );
    no warnings qw(redefine once);
    local *Plugins::HQPlayerBridge::Plugin::nowPlayingFor = sub { {} };
    my $rq = LoopReq->new;
    Plugins::HQPlayerBridge::Plugin::_signalPathQuery($rq);
    is(defined $rq->{loop}{0}{up} ? $rq->{loop}{0}{up} : '(absent)', 0,
       'the signalpath query sends `up` (0 for an unanswered accept)');
    %$reg = %keep;
}

# A key must be ABSENT, not empty - a caller tests it to skip the row rather
# than drawing a label with nothing after it.
my $q = Plugins::HQPlayerBridge::Plugin::signalPathFor( undef,
    { control => PathCtl->new, instance => {}, client => PathClient->new({}, undef) } );
ok(!exists $q->{output},     'no output reported means the key is ABSENT, not empty');
ok(!exists $q->{filter}, 'and so does no filter');
ok(!exists $q->{shaper}, 'and no shaper');
ok(!exists $q->{speed},  'and no speed');
ok(!exists $q->{tier},       'and no tier');

# A bridge with no player at all must not die.
my $none = Plugins::HQPlayerBridge::Plugin::signalPathFor( undef, { instance => {} } );
is(scalar(keys %$none), '0', 'a bridge with no player yields an empty path, not a crash');

# ONE FORMATTER, TWO AUDIENCES. The Apps feed and the live page draw on the
# same signalPathFor, and each renders its half VERBATIM - the feed the settings
# (mode/filter/shaper/transport), the live page the moving signal path. Neither
# surface formats anything itself, which is what keeps them from disagreeing
# about what "Filter" reads like.
{
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    %$reg = ( aa => $bridge );
    my $feed;
    Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
    my $names = join '|', map { $_->{name} } @{ $feed->{items} };
    for my $k (qw( filter shaper )) {
        ok(scalar( defined $p->{$k} && index($names, $p->{$k}) >= 0 ),
           "the feed renders the formatter's $k verbatim");
    }
    %$reg = ();
}

print "-- nothing discovered yet SAYS so, in the same words as the live page --\n";
# A bare link and nothing else leaves the user unsure whether the plugin is
# working at all. Discovery keeps probing, and an instance that is simply
# switched off will appear on its own - so the wording is WAITING, not failed,
# matching the live page. The second row is the diagnostic for when it never
# does turn up.
{
    my $reg = Plugins::HQPlayerBridge::Plugin::bridges();
    %$reg = ();
    my $feed;
    Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
    my @i = @{ $feed->{items} || [] };
    is($i[0]->{type}, 'link', 'the live-view row is still first');
    is($i[1]->{name}, 'PLUGIN_HQPLAYER_LIVE_WAITING',
       'and an empty registry says it is waiting for the player');
    is($i[2]->{name}, 'PLUGIN_HQPLAYER_NONE_DESC',
       'with the discovery diagnostic under it');
    is(scalar( grep { ($_->{type} // '') ne 'text' } @i[1 .. $#i] ), '0',
       'both are plain text rows - a non-playable item with an action navigates when tapped');
}

print "-- the Material Home tile: the ONLY one-tap route to the live view --\n";
# AN APPS ENTRY CANNOT OPEN A PAGE. Material's `apps` command builds every
# plugin entry itself with `type => 'redirect'` and a `go` action into
# [<tag>,'items'] - there is no weblink field a plugin can supply, and
# browse-resp.js does not auto-open a single-item feed. So Apps always browses
# into the feed. A "pinned" custom action carrying a weblink becomes a HOME
# tile that opens it on one tap, and that is what postinitPlugin registers.
my @reg;
{
    no warnings 'redefine', 'once';
    *Plugins::MaterialSkin::Plugin::registerCustomAction = sub { push @reg, [@_]; return };
}

Plugins::HQPlayerBridge::Plugin::postinitPlugin();

is(scalar(@reg), '1', 'exactly one action is registered');
is($reg[0][0], 'pinned', 'in the "pinned" section - that is what becomes a Home tile');
is($reg[0][1]{iframe}, Plugins::HQPlayerBridge::Live::PATH(),
   'and it points at the live page via `iframe`, which opens INLINE in Material');
ok(scalar(!exists $reg[0][1]{weblink}),
   'NOT `weblink` - doCustomAction calls window.open for that, tearing off a separate window');
ok(scalar(defined $reg[0][1]{title} && length $reg[0][1]{title}), 'the tile has a title');

# THE TILE'S TITLE IS ITS NAME ON THE HOME SCREEN. It must be the same string
# the Apps row uses - two labels for one destination is how they drift.
is($reg[0][1]{title}, $i[0]->{name},
   'and it is the SAME string as the Apps row, so the two cannot drift apart');
ok(scalar(defined $reg[0][1]{icon}), 'and an icon');

# THE TRAP. registerCustomAction PUSHES - no unregister, no de-dupe - so a
# second call puts the tile on Home twice. It must only ever run at postinit.
@reg = ();
Plugins::HQPlayerBridge::Plugin::postinitPlugin();
is(scalar(@reg), '1', 'each call registers again - so it must run ONCE per server run');

print "-- and no Material means no tile, not a crash --\n";
{
    # ->can on a package that was never loaded answers undef. An install with
    # no Material must get a working plugin and a silent skip.
    no warnings 'redefine', 'once';
    undef *Plugins::MaterialSkin::Plugin::registerCustomAction;
    @reg = ();
    my $ok = eval { Plugins::HQPlayerBridge::Plugin::postinitPlugin(); 1 };
    ok($ok, 'postinitPlugin survives Material being absent');
    is(scalar(@reg), '0', 'and registers nothing');
}


# RESTARTING HQPLAYER through the hqrestart helper (tools/hqrestart/). No
# settings: the bridge pings a fixed port on the host discovery already found,
# and a restart row appears only once that answers as the helper.
print "-- the restart row --\n";
{
    package FakeRes; sub new { bless { c => $_[1] }, $_[0] } sub content { $_[0]->{c} }
}
{
    my $P   = 'Plugins::HQPlayerBridge::Plugin';
    my $rs  = Plugins::HQPlayerBridge::Plugin::restartable();
    my $REQ = \@Slim::Networking::SimpleAsyncHTTP::REQ;
    %$rs = ();

    Slim::Networking::SimpleAsyncHTTP::_reset();
    Plugins::HQPlayerBridge::Plugin::_probeRestart('10.0.0.5');
    is(scalar(@$REQ), '1', 'a link-up probes the host once');
    is($REQ->[0]{url}, 'http://10.0.0.5:8090/ping', 'on the fixed port, at /ping (which needs no token)');

    # CONTROL: something else answering on 8090 is not the helper.
    $REQ->[0]{cb}->( FakeRes->new('<html>not it</html>') );
    is($rs->{'10.0.0.5'} ? 1 : 0, 0, 'a stranger answering on 8090 does NOT make the host restartable');
    $REQ->[0]{ecb}->( undef, 'Connect timed out' );
    is($rs->{'10.0.0.5'} ? 1 : 0, 0, 'and nothing listening leaves it so, silently');

    $REQ->[0]{cb}->( FakeRes->new('{"ok": true, "service": "hqrestart"}') );
    is($rs->{'10.0.0.5'} ? 1 : 0, 1, 'the helper answering makes it restartable');

    Slim::Networking::SimpleAsyncHTTP::_reset();
    Plugins::HQPlayerBridge::Plugin::_probeRestart('10.0.0.5');
    is(scalar(@$REQ), '0', 'a host already known is not probed again');

    my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    $src =~ s/^\s*#.*$//mg;
    my ($ls) = $src =~ /sub _onLinkState \{(.*?)\n\}/s;
    ok(scalar( defined $ls && $ls =~ /if \(\$up\) \{[^}]*_probeRestart/s ),
       'the probe runs on link UP');
    ok(scalar( $src !~ /delete \$restartable/ ),
       'and nothing ever REMOVES a host - a row that vanished would shift the positional item_ids under a tap');

    # THE ROW: in the restart block, right under the Live View row and above
    # every instance block - see topLevel for why it cannot live inside one.
    %$reg = ( 'aa' => {
        name => 'HQPlayer (Test)', control => FeedCtl->new,
        instance => { ip => '10.0.0.5' }, client => FeedClient->new({ active_mode => 'PCM' }),
    } );
    Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
    my @r = @{ $feed->{items} };
    is($r[0]{name}, 'PLUGIN_HQPLAYER_LIVE_TITLE', 'the Live View row is still first');
    is($r[1]{name}, 'PLUGIN_HQPLAYER_RESTART', 'then Restart, ABOVE the instance blocks');
    is($r[1]{type}, 'link', 'as a link');
    is($r[1]{passthrough}[0]{id}, 'aa', 'carrying the bridge id, not an address that can move');
    ok(scalar( !exists $r[1]{nextWindow} ), 'with no nextWindow - it opens a page, it is not the banned Refresh row');
    is($r[2]{name}, 'HQPlayer (Test)', 'then the instance name row');
    is(scalar( grep { ($_->{type} // '') ne 'text' } @r[2 .. $#r] ), '0',
       'and every row below the restart block is text - nothing below it can be tapped');

    # CONTROL: an unknown host gets no row.
    {
        my @keep = @{ Plugins::HQPlayerBridge::Plugin::restartRows() };
        @{ Plugins::HQPlayerBridge::Plugin::restartRows() } = ();
        %{ Plugins::HQPlayerBridge::Plugin::restartNames() } = ();
        $reg->{aa}{instance}{ip} = '10.0.0.6';
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar( grep { ($_->{name} // '') eq 'PLUGIN_HQPLAYER_RESTART' } @{ $feed->{items} } ), '0',
           'a host whose helper never answered has NO restart row');
        $reg->{aa}{instance}{ip} = '10.0.0.5';
        @{ Plugins::HQPlayerBridge::Plugin::restartRows() } = @keep;
    }

    # BOTH TAPS ARE RESOLVED BY POSITION, walking the feed again from topLevel.
    # With the row inside each instance's block, A leaving discovery while B's
    # confirm page was open made "Restart HQPlayer B now" restart C (simulated
    # 2026-09-21). The block is append-only, so no tappable row moves.
    {
        no warnings 'redefine';
        local *Plugins::HQPlayerBridge::Plugin::cstring = sub { join ' ', grep { defined } @_[1 .. $#_] };
        @{ Plugins::HQPlayerBridge::Plugin::restartRows() } = ();
        %{ Plugins::HQPlayerBridge::Plugin::restartNames() } = ();
        %$reg = map { my ($id, $ip) = @$_; ( $id => {
            name => "HQ $id", control => FeedCtl->new, instance => { ip => $ip },
            client => FeedClient->new({}) } ) } ( [ 'A', '10.0.1.1' ], [ 'B', '10.0.1.2' ], [ 'C', '10.0.1.3' ] );
        $rs->{$_} = 1 for qw(10.0.1.1 10.0.1.2 10.0.1.3);
        my $walk = sub {    # XMLBrowser: item_id "p.q" -> topLevel item p, its page's item q
            my ( $p, $q ) = @_;
            my $top; Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $top = shift->{items} }, {} );
            my $it = $top->[$p] or return;
            return $it unless defined $q;
            my $page; $it->{url}->( undef, sub { $page = shift->{items} }, {}, $it->{passthrough}[0] );
            return $page->[$q];
        };
        my $top; Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $top = shift->{items} }, {} );
        my ($posB) = grep { ( ( $top->[$_]{passthrough} || [{}] )->[0]{id} // '' ) eq 'B' } 0 .. $#$top;
        is($walk->( $posB, 0 )->{name}, 'PLUGIN_HQPLAYER_RESTART_NOW HQ B', 'the confirm page reads "Restart HQ B now"');

        delete $reg->{A};                       # A leaves while that page is open
        my $now = $walk->( $posB, 0 );
        is($now->{passthrough}[0]{id}, 'B', 'the second tap still restarts B, not C');
        is($now->{name}, 'PLUGIN_HQPLAYER_RESTART_NOW HQ B', 'and the page still names B');
        is($walk->( $posB )->{passthrough}[0]{id}, 'B', 'and the first tap still lands on B\'s row');

        my ($posA) = grep { ( ( $top->[$_]{passthrough} || [{}] )->[0]{id} // '' ) eq 'A' } 0 .. $#$top;
        is($walk->( $posA )->{passthrough}[0]{id}, 'A', 'A keeps its row after leaving - rows never close up');
        my $gone = $walk->( $posA, 0 );
        is($gone->{name}, 'PLUGIN_HQPLAYER_RESTART_GONE', 'and tapping it says A is no longer connected');
        is($gone->{type}, 'text', 'as text, so there is nothing to tap through to');

        # A NEW host only ever APPENDS, after every existing row.
        $reg->{D} = { name => 'HQ D', control => FeedCtl->new, instance => { ip => '10.0.1.0' }, client => FeedClient->new({}) };
        $rs->{'10.0.1.0'} = 1;
        is($walk->( $posB )->{passthrough}[0]{id}, 'B', 'a host arriving later does not move B - it sorts first but appends');
        is($walk->( $posB + 2 )->{passthrough}[0]{id}, 'D', 'it goes at the END of the block');

        # CONTROL: the old in-block placement WOULD have shifted - the rows below are text now.
        my $all; Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $all = shift->{items} }, {} );
        is(scalar( grep { ( $_->{type} // '' ) eq 'link' && ref $_->{url} } @$all ), '4',
           'exactly the four restart rows are tappable, and all sit in the block');

        @{ Plugins::HQPlayerBridge::Plugin::restartRows() } = ();
        %{ Plugins::HQPlayerBridge::Plugin::restartNames() } = ();
        %$reg = ( 'aa' => {
            name => 'HQPlayer (Test)', control => FeedCtl->new,
            instance => { ip => '10.0.0.5' }, client => FeedClient->new({ active_mode => 'PCM' }),
        } );
    }

    # A HOST MISSED AT LINK-UP IS ASKED AGAIN WHEN THE LIST IS DRAWN - the
    # helper and hqplayerd start at login in no fixed order - but throttled.
    {
        no warnings 'redefine';
        my $now = 1_000_000;
        local *Plugins::HQPlayerBridge::Plugin::_now = sub { $now };
        Slim::Networking::SimpleAsyncHTTP::_reset();
        $reg->{aa}{instance}{ip} = '10.0.0.7';
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar(@$REQ), '1', 'drawing the list asks an unknown host again');
        is($REQ->[0]{url}, 'http://10.0.0.7:8090/ping', 'at /ping');
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar(@$REQ), '1', 'but not again on every draw');
        $now += 61;
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar(@$REQ), '2', 'and again once a minute has passed');
        Plugins::HQPlayerBridge::Plugin::_probeRestart('10.0.0.7');
        is(scalar(@$REQ), '3', 'while a link-up is never throttled');
        $REQ->[2]{cb}->( FakeRes->new('{"ok": true, "service": "hqrestart"}') );
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar( grep { ($_->{name} // '') eq 'PLUGIN_HQPLAYER_RESTART' } @{ $feed->{items} } ), '1',
           'and once it answers, the row is there on the next open');
        $now += 3600;
        Plugins::HQPlayerBridge::Plugin::topLevel( undef, sub { $feed = shift }, {} );
        is(scalar(@$REQ), '3', 'and a known host is never asked again');
        $reg->{aa}{instance}{ip} = '10.0.0.5';
    }

    # THE FIRST TAP ONLY ASKS - and names the instance, because the row that
    # opened it was found by POSITION and can have shifted onto a neighbour.
    Slim::Networking::SimpleAsyncHTTP::_reset();
    my $page;
    {
        no warnings 'redefine';
        local *Plugins::HQPlayerBridge::Plugin::cstring = sub { join ' ', grep { defined } @_[1 .. $#_] };
        Plugins::HQPlayerBridge::Plugin::_restartConfirm( undef, sub { $page = shift }, {}, { id => 'aa' } );
    }
    is(scalar(@$REQ), '0', 'the first tap restarts NOTHING - it only asks');
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_NOW HQPlayer (Test)',
       'it offers Restart now, NAMING the instance it will restart');
    is($page->{items}[0]{passthrough}[0]{id}, 'aa', 'for the same bridge');
    Plugins::HQPlayerBridge::Plugin::_restartConfirm( undef, sub { $page = shift }, {}, { id => 'gone' } );
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_GONE', 'and a bridge gone by then offers nothing to tap');
    is($page->{items}[0]{type}, 'text', 'as plain text');

    # THE SECOND DOES IT, and the page that opens is the outcome.
    Plugins::HQPlayerBridge::Plugin::_restartNow( undef, sub { $page = shift }, {}, { id => 'aa' } );
    is($REQ->[0]{url}, 'http://10.0.0.5:8090/restart', 'Restart now calls the helper');
    # A GET here is reachable by anything that can make LMS fetch a URL - its
    # own image proxy does, for any client - so the helper waives the token
    # ONLY for a JSON POST. Measured 2026-09-21.
    is($REQ->[0]{method}, 'POST', 'as a POST - the helper refuses a tokenless GET');
    is($REQ->[0]{headers}{'Content-Type'}, 'application/json', 'sent as JSON, which is what the helper trusts');
    # The helper bounds a restart at total_timeout = 90s; waiting only as long
    # reads a slow service stop as a failure that then succeeds.
    ok(scalar( $REQ->[0]{timeout} > 90 ), 'and it waits LONGER than the helper\'s 90s bound');
    # The helper names this number (BRIDGE_WAIT) to warn a user who sets a
    # `total_timeout` past it; the two must not drift apart silently.
    my $hsrc = do { local (@ARGV,$/) = ('hqrestart/hqrestart.py'); <> };
    my ($bw) = ($hsrc // '') =~ /^BRIDGE_WAIT = (\d+)/m;
    is($bw, $REQ->[0]{timeout}, 'and the helper knows that same number');
    $page = undef;
    $REQ->[0]{cb}->( FakeRes->new('{"ok": true, "old_pid": 1, "new_pid": 2, "seconds": 7.1}') );
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_OK', 'success says so');

    # CONTROL: a refusal must not read as success.
    $page = undef;
    $REQ->[0]{ecb}->( undef, '401 Unauthorized', FakeRes->new('{"ok": false, "error": "bad or missing token"}') );
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_FAIL', 'a refusal (this server not in `allow`) says it FAILED');
    $page = undef;
    $REQ->[0]{cb}->( FakeRes->new('garbage') );
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_FAIL', 'and so does an answer that is not the helper\'s');

    # The reply parser must not be a LOAD-TIME dependency: JSON::PP is core Perl
    # but LMS does not ship it, and a `use` that died at BEGIN would take the
    # whole plugin down over one optional row.
    my $psrc = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Plugin.pm'); <> };
    ok(scalar( $psrc !~ /^\s*use\s+JSON/m ), 'JSON is not loaded at BEGIN - a missing one must not kill the plugin');
    ok(scalar( $psrc =~ /require\s+JSON::PP/ ), 'it is required at call time instead');

    Slim::Networking::SimpleAsyncHTTP::_reset();
    Plugins::HQPlayerBridge::Plugin::_restartNow( undef, sub { $page = shift }, {}, { id => 'gone' } );
    is(scalar(@$REQ), '0', 'a bridge that has gone away is not called');
    is($page->{items}[0]{name}, 'PLUGIN_HQPLAYER_RESTART_GONE', 'and the page says why');

    %$reg = (); %$rs = ();
}

print "-- discovery: every reply is stamped with the round it answered --\n";
{
    # _liveOf tells an address the daemon has LEFT from one still answering by
    # the round number, and every fixture above supplies that number by hand.
    # So this proves the REAL reply path stamps it: if it ever stopped, every
    # address would read as live and a DHCP move would split one daemon into
    # two players again - with every fixture above still passing.
    require Plugins::HQPlayerBridge::Discovery;
    no warnings 'redefine';
    local *Plugins::HQPlayerBridge::Discovery::_round = sub { };
    Slim::Utils::Timers::_reset();
    Plugins::HQPlayerBridge::Discovery->start( sub { } );

    my $rx = IO::Socket::INET->new( Proto => 'udp', LocalAddr => '127.0.0.1', LocalPort => 0 );
    my $tx = $rx && IO::Socket::INET->new( Proto => 'udp', PeerAddr => '127.0.0.1', PeerPort => $rx->sockport );
    my $answer = sub {
        $tx->send('<discover name="HQPlayerEmbedded" result="OK" version="x">hqplayer</discover>');
        select( undef, undef, undef, 0.1 );
        Plugins::HQPlayerBridge::Discovery::_reply($rx);
        return { map { $_->{ip} => $_->{round} } @{ Plugins::HQPlayerBridge::Discovery::instances() } };
    };
    if ($tx) {
        my $r1 = $answer->()->{'127.0.0.1'};
        ok( defined $r1, 'a reply carries the round it answered (' . ( $r1 // 'undef' ) . ')' );
        my $again = $answer->()->{'127.0.0.1'};
        is( $again // 'undef', $r1 // 'undef', 'a second reply in the SAME round carries the same number' );
        Plugins::HQPlayerBridge::Discovery::_roundDone();
        my $r2 = $answer->()->{'127.0.0.1'};
        ok( defined $r1 && defined $r2 && $r2 > $r1,
            'a reply in the NEXT round carries a later one (' . ( $r1 // '?' ) . ' -> ' . ( $r2 // '?' ) . ')' );
    }
    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
}

print "-- a same-named pair is reported once, not every round --\n";
{
    # Discovery runs every 5s now, and a same-named pair is a steady state -
    # HQPlayer Embedded names every instance "HQPlayerEmbedded". A WARN per
    # round would be ~500 lines an hour for as long as both are up.
    my @warned;
    no warnings 'redefine';
    local *Slim::Utils::Log::Obj::warn = sub { push @warned, $_[1] };
    my $ids  = \&Plugins::HQPlayerBridge::Plugin::_idsFor;
    my $pair = sub { [ map { { ip => $_, name => 'PairTest', round => 3 } } @_ ] };

    $ids->( $pair->('10.1.0.5', '10.1.0.7') ) for 1 .. 5;
    is( scalar @warned, 1, 'five complete rounds of the same pair warn ONCE' );

    $ids->( $pair->('10.1.0.5', '10.1.0.9') );
    is( scalar @warned, 2, 'and again when the pair\'s addresses change' );

    $ids->( $pair->('10.1.0.5') );                       # down to one: not a pair
    $ids->( $pair->('10.1.0.5', '10.1.0.9') );           # and back
    is( scalar @warned, 3, 'and again when a pair that went away comes back' );

    # CONTROL: a partial (mid-round) list never warns - it defers the group.
    @warned = ();
    %{ Plugins::HQPlayerBridge::Plugin::bridges() } = ();
    $ids->( $pair->('10.2.0.5', '10.2.0.7'), 1 );
    is( scalar @warned, 0, 'a partial list says nothing' );

    # The whole pair leaves the table - both switched off overnight - and
    # comes back on the SAME addresses. The name never shrank to one, so only
    # the name leaving the table can say the warning is owed again.
    @warned = ();
    $ids->( $pair->('10.3.0.5', '10.3.0.7') );
    $ids->( [] );                                        # a complete round, nobody answers
    $ids->( $pair->('10.3.0.5', '10.3.0.7') );
    is( scalar @warned, 2, 'a pair that left the table and came back on the same addresses warns again' );

    # CONTROL: a PARTIAL list without the name does not clear it - it only
    # holds who has answered so far.
    @warned = ();
    $ids->( $pair->('10.4.0.5', '10.4.0.7') );
    $ids->( [ { ip => '10.9.9.1', name => 'Other', round => 4 } ], 1 );
    $ids->( $pair->('10.4.0.5', '10.4.0.7') );
    is( scalar @warned, 1, 'CONTROL: a partial list missing the pair does not re-arm its warning' );
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
