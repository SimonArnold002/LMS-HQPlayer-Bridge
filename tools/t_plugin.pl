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

    is(join(',', @waits), '2,4,8,10,10,10,10',
       'with nothing found it retries fast and doubles, capped at COLD_PERIOD');

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
           'with no way to ask about the link it settles to the steady-state period');
    }

    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
}

print "-- discovery: how hard to probe is decided by the CONTROL LINK --\n";
{
    # The point of the whole exercise: an instance that is connected needs no
    # finding, and one that is not - powered off, asleep, moved - has to be
    # found again quickly.  Simon's HQPlayer sat unused for a week; the probe a
    # minute it collected in that time bought nothing, and when the endpoint
    # finally came on the cold start still took a measured 63s.
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
        is($wait->(), '600', 'every instance connected - go quiet for IDLE_PERIOD');

        $up = 0;
        is($wait->(), '10', 'a link that is down puts it straight back on COLD_PERIOD');

        $up = 1;
        is($wait->(), '600', 'and it goes quiet again once the link is back');
    }

    Plugins::HQPlayerBridge::Discovery->stop;
    Slim::Utils::Timers::_reset();
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

    package FeedCtl;
    sub new { bless {}, shift } sub connected { 1 }
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
    package PathCtl;
    sub new { bless {}, shift } sub connected { 1 }
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

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
