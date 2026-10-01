# The settings page: typed HQPlayer addresses and the automatic-discovery
# switch (docs/discovery-simplification-plan.md 4.5-4.6).
#
# This RUNS the real Settings::handler() against a base class that saves the
# way LMS's does - every pref in prefs() set from pref_<name>, present or not,
# and only when saveSettings is set - then calls beforeRender. The fleet rule
# behind it (LMS-Discography tools/t_settings.pl, and the Eversolo 1.5.0 page
# that shipped dead with every check green): a test of an extracted sub cannot
# see a handler that never reaches its end.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';

our ( %STORE, $SAVED, $BASE_RAN );

require Slim::Web::Settings;
require Slim::Utils::Strings;
{
    no warnings qw(redefine once);
    *Slim::Web::Settings::handler = sub {
        my ( $class, $client, $params ) = @_;
        $SAVED = 0;
        if ( $params->{saveSettings} ) {
            my ( $prefs, @names ) = $class->prefs;
            $prefs->set( $_, $params->{"pref_$_"} ) for @names;
            $SAVED = 1;
        }
        $class->beforeRender( $params, $client );
        $BASE_RAN = 1;
        return 'rendered';
    };

    # The real EN text, so an assertion can see the entry being NAMED.
    my %en;
    open my $fh, '<', '../HQPlayerBridge/strings.txt' or die $!;
    my $key;
    while (<$fh>) {
        if (/^(\S+)\s*$/) { $key = $1 }
        elsif ( defined $key && /^\tEN\t(.*)$/ ) { $en{$key} = $1 }
    }
    *Slim::Utils::Strings::string = sub { $en{ $_[0] } // $_[0] };
}

require Plugins::HQPlayerBridge::Settings;
require Slim::Utils::Timers;

my ( $pass, $fail ) = ( 0, 0 );
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# see the note on ok() in t_player.pl - a failed match returns the EMPTY LIST
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

my $S     = 'Plugins::HQPlayerBridge::Settings';
my $prefs = Slim::Utils::Prefs::preferences('plugin.hqplayerbridge');

# HQPlayer, stubbed at the one <GetInfo/>: %UP is ip => name for an HQPlayer
# that is running there. Answers are held until the test releases them, as a
# real connection answers on a later turn of the event loop.
our ( %UP, @ASKED, @HELD );
{
    no warnings qw(redefine once);
    *Plugins::HQPlayerBridge::Control::identify = sub {
        my ( $class, $ip, $cb ) = @_;
        push @ASKED, $ip;
        push @HELD, sub { $cb->( defined $UP{$ip} ? { name => $UP{$ip} } : undef ) };
    };
}
sub answer_all { my @h = @HELD; @HELD = (); $_->() for @h }

# The players the bridge already has: %HOLD is ip => [ 'up'|'down', name ],
# answered through the same hook Plugin::_linkStateAt fills in live.
our %HOLD;
my $A = 'Plugins::HQPlayerBridge::Addresses';
sub hold_rig {
    $A->can('reset')->();
    $A->can('init')->( undef, sub { @{ $HOLD{ $_[0] } || [] } },
                       sub { grep { $HOLD{$_}[0] eq 'up' } sort keys %HOLD } );
}

sub reset_store {
    $prefs->set( addresses => '10.0.0.1' ); $prefs->set( autodiscover => 1 );
    $BASE_RAN = 0; $SAVED = undef; %UP = (); @ASKED = (); @HELD = (); %HOLD = (); Slim::Utils::Timers::_reset();
    hold_rig();
}

# What the real page posts: the sentinel, the mode radio ("1" automatic, "0"
# addresses only), and the box unless it is greyed out.
# Returns ( $params, $syncBody, \$asyncBody ).
sub post {
    my (%f) = @_;
    my %p = ( saveSettings => 1, hqp_form => 1 );
    $p{pref_autodiscover} = $f{mode} if defined $f{mode};
    $p{pref_addresses}    = $f{addresses} if defined $f{addresses};
    my $async;
    my $cb = sub { $async = $_[2] };
    my $sync = $S->handler( undef, \%p, $cb );
    return ( \%p, $sync, \$async );
}

print "-- the prefs, the radio group, and the form --\n";
{
    my ( $p, @names ) = $S->prefs;
    is( join( ',', @names ), 'addresses,autodiscover', 'the two prefs' );

    my $tmpl = do { local ( @ARGV, $/ ) = ('../HQPlayerBridge/HTML/EN/plugins/HQPlayerBridge/settings/basic.html'); <> };
    # TT comments out FIRST: the comment above the group explains "no <select>",
    # and a source grep matching its own explanation is this repo's most
    # repeated false result.
    $tmpl =~ s/\[%#.*?%\]//gs;
    my @radios = $tmpl =~ /(<label><input type="radio" name="pref_autodiscover"[^>]*>[^<]*<\/label>)/g;
    is( scalar @radios, 2, 'the mode is a radio group of two, each <label>-wrapped (bare, Material does not draw it)' );
    ok( scalar( $tmpl =~ /<\/label><br>\s*<label><input type="radio"/ ), 'and <br>-separated, one per line' );
    ok( scalar( $tmpl !~ /<select/ ), 'no <select> - it overlaps the page' );
    ok( scalar( $radios[0] =~ /value="1"[^>]*\[% IF hqp_auto %\]checked/ ), '"automatically" is checked on hqp_auto' );
    ok( scalar( $radios[1] =~ /value="0"[^>]*\[% IF !hqp_auto %\]checked/ ),
        '"only these addresses" on its NEGATION - so exactly one is checked, whatever hqp_auto holds' );
    ok( scalar( $tmpl !~ /prefs\.autodiscover/ ), 'the template never matches the stored value - Perl decides' );
    ok( scalar( $tmpl =~ /name="hqp_form"/ ), 'the template posts the hqp_form sentinel' );
    ok( scalar( $tmpl =~ /<textarea[^>]*name="pref_addresses"[^>]*\[% IF hqp_auto %\]disabled="disabled"/ ),
        'the box is drawn greyed out in automatic mode' );
    ok( scalar( $radios[0] =~ /disabled=true/ && $radios[1] =~ /disabled=false/ ),
        'and picking a mode greys it out or brings it back, before saving' );
}

print "-- exactly one radio checked in EVERY stored state --\n";
my $DEF = Plugins::HQPlayerBridge::Addresses::AUTO_DEFAULT();
for my $case ( [ undef, $DEF, 'never set' ], [ 1, 1, '1' ], [ 0, 0, '0' ], [ '', 0, 'empty' ], [ 'x', 1, 'junk' ] ) {
    my ( $stored, $want, $what ) = @$case;
    reset_store();
    $prefs->set( autodiscover => $stored );
    my %p;
    $S->handler( undef, \%p );
    is( $p{hqp_auto}, $want, "stored $what: hqp_auto is $want - one of the two radios, never neither" );
}

print "-- automatic: the box is CLEARED, nothing is checked --\n";
{
    reset_store();
    my ( $p ) = post( mode => 1, addresses => '10.0.0.7' );
    ok( $BASE_RAN, 'the handler reached the end' );
    is( $SAVED, 1, 'it saves' );
    is( $prefs->get('addresses'), '', 'with the box cleared - the typed players go on this save' );
    is( scalar @ASKED, 0, 'and asks no HQPlayer anything' );

    reset_store();
    post( mode => 1 );    # the greyed box posts nothing
    is( $SAVED . '/' . $prefs->get('addresses'), '1/', 'a greyed-out box, posting nothing, still saves as cleared' );

    reset_store();
    my ( $q ) = post( mode => 1, addresses => 'hqplayer.local' );
    is( $SAVED . '/' . ( $q->{hqp_error} // 'none' ), '1/none', 'a bad entry in a box being cleared is not an error' );

    reset_store();
    post();    # the radio missing altogether (and a greyed box)
    is( $prefs->get('autodiscover'), $DEF, "no mode posted at all is AUTO_DEFAULT ($DEF)" );
}

print "-- addresses only: a NEW address is saved only if HQPlayer answers there --\n";
{
    reset_store();
    %UP = ( '192.168.1.10' => 'MacMini', '192.168.1.11' => 'Study' );
    my ( $p, $sync, $async ) = post( mode => 0, addresses => " 192.168.001.010,192.168.1.11\n192.168.1.10 " );
    ok( !defined $sync, 'the handler defers - the page waits for HQPlayer' );
    is( join( ',', @ASKED ), '192.168.1.10,192.168.1.11', 'each new address is asked, once, normalised' );
    is( $SAVED, undef, 'and nothing is saved before the answers are in' );
    answer_all();
    is( $$async, 'rendered', 'the page is delivered through the callback' );
    is( $SAVED, 1, 'both answered: it saves' );
    is( $prefs->get('addresses'), '192.168.1.10, 192.168.1.11',
        'separated by commas, spaces or new lines; normalised as DECIMAL (001.010 is .1.10, not octal); de-duplicated' );
    is( $prefs->get('autodiscover'), 0, 'in addresses-only mode' );
    is( join( ' | ', @{ $p->{hqp_found} || [] } ),
        "Saved: HQPlayer 'MacMini' answered at 192.168.1.10. | Saved: HQPlayer 'Study' answered at 192.168.1.11.",
        'and the page names the HQPlayer that answered at each' );
    is( $p->{hqp_addresses}, '192.168.1.10, 192.168.1.11', 'and shows what was SAVED' );
}

{
    reset_store();
    %UP = ( '10.0.0.5' => 'Up' );
    my ( $p, $sync, $async ) = post( mode => 0, addresses => '10.0.0.5, 10.0.0.6' );
    answer_all();
    is( $SAVED, 0, 'one of them not running: NOTHING is saved' );
    is( $prefs->get('addresses') . '/' . $prefs->get('autodiscover'), '10.0.0.1/1', 'not even the one that answered, or the mode' );
    ok( scalar( ( $p->{hqp_error} // '' ) =~ /nothing answered at 10\.0\.0\.6\b/ ), 'the error names the address nothing answered at' );
    ok( scalar( ( $p->{hqp_error} // '' ) !~ /10\.0\.0\.5/ ), 'and only that one' );
    is( $p->{hqp_addresses}, '10.0.0.5, 10.0.0.6', 'the box keeps what was typed' );
    is( $p->{hqp_auto}, 0, 'and the page stays on addresses-only' );
    is( $$async, 'rendered', 'the page is still delivered' );
}

{
    # UNTIDY TEXT, REFUSED FOR A DEAD ADDRESS. The dead-address refusal comes
    # AFTER the save has replaced pref_addresses with the parsed list, so the
    # box came back tidied - not what was typed, unlike a bad-entry refusal
    # (review 2026-09-28, finding 5). The tests above type tidy text, which
    # reads the same either way.
    reset_store();
    %UP = ( '10.0.0.5' => 'Up' );
    my $typed = "10.0.0.5\n010.0.0.6  10.0.0.6";
    my ($p) = post( mode => 0, addresses => $typed );
    answer_all();
    is( $SAVED, 0, 'untidy text, one address dead: nothing is saved' );
    ok( scalar( ( $p->{hqp_error} // '' ) =~ /nothing answered at 10\.0\.0\.6\b/ ), 'CONTROL: refused for the DEAD address, not a bad entry' );
    is( $p->{hqp_addresses}, $typed, 'and the box shows the text AS TYPED, not the parsed list' );
}

{
    # Only what the save ADDS is checked: an address already in the box is
    # not re-asked, so one HQPlayer being off cannot block editing the list.
    reset_store();
    $prefs->set( addresses => '10.0.0.1, 10.0.0.2' ); $prefs->set( autodiscover => 0 );
    my ( $p, $sync ) = post( mode => 0, addresses => '10.0.0.1' );
    is( scalar @ASKED, 0, 'removing an address asks nothing' );
    is( $SAVED . '/' . $prefs->get('addresses'), '1/10.0.0.1', 'and saves straight away' );
    is( $sync, 'rendered', 'synchronously' );
}

{
    # SWITCHING FROM AUTOMATIC STARTS FRESH (Simon, 2026-09-27, review finding
    # 4): the stored list is not in use in automatic mode, so nothing in it
    # counts as already checked. reset_store leaves 10.0.0.1 in the pref with
    # automatic on - only a hand-written `pref` puts it there, as the page
    # clears it - and nothing is running at it.
    reset_store();
    my ( $p, $sync, $async ) = post( mode => 0, addresses => '10.0.0.1' );
    is( join( ',', @ASKED ), '10.0.0.1', 'switching from automatic: an address the stale pref holds IS asked' );
    answer_all();
    is( $SAVED . '/' . $prefs->get('autodiscover'), '0/1', 'nothing answers there: NOTHING is saved, still automatic' );
    ok( scalar( ( $p->{hqp_error} // '' ) =~ /10\.0\.0\.1\b/ ), 'and the error names it' );
}

{
    # An HQPlayer that accepts and never answers must not hold the page for
    # Control's 30s reply window.
    reset_store();
    %UP = ( '10.0.0.9' => 'Slow' );
    my ( $p, $sync, $async ) = post( mode => 0, addresses => '10.0.0.9' );
    my ($t) = @{ Slim::Utils::Timers::_timers() };
    ok( $t && abs( $t->{when} - Time::HiRes::time() - Plugins::HQPlayerBridge::Settings::CHECK_WAIT() ) < 1,
        'a deadline is set, CHECK_WAIT (' . Plugins::HQPlayerBridge::Settings::CHECK_WAIT() . 's) away' );
    Slim::Utils::Timers::_fireAll();
    is( $SAVED . '/' . ( $$async // 'none' ), '0/rendered', 'at the deadline the page is drawn, and nothing is saved' );
    ok( scalar( ( $p->{hqp_error} // '' ) =~ /10\.0\.0\.9/ ), 'naming the address' );
    $SAVED = 'untouched';
    answer_all();
    is( $SAVED, 'untouched', 'and a late answer is ignored - the page was drawn once' );
}

print "-- an address the bridge is CONNECTED at opens no second connection --\n";
{
    # Discovery found the Mac mini; switching it off, its address is typed.
    reset_store();
    $prefs->set( addresses => '' );
    $HOLD{'10.0.0.5'} = [ 'up', 'Kept' ];
    my ( $p, $sync ) = post( mode => 0, addresses => '10.0.0.5' );
    is( scalar @ASKED, 0, 'its proven link is the answer - no GetInfo beside it (inline review 2(a), again at review 3)' );
    is( $sync, 'rendered', 'so the page is drawn at once' );
    is( $SAVED . '/' . $prefs->get('addresses') . '/' . $prefs->get('autodiscover'), '1/10.0.0.5/0', 'and it saves' );
    is( join( ' | ', @{ $p->{hqp_found} || [] } ), "Saved: HQPlayer 'Kept' answered at 10.0.0.5.",
        'naming the HQPlayer from its player' );

    reset_store();
    $prefs->set( addresses => '' );
    $HOLD{'10.0.0.5'} = [ 'down', 'Kept' ];
    %UP = ( '10.0.0.5' => 'Kept' );
    ( $p, $sync ) = post( mode => 0, addresses => '10.0.0.5' );
    is( join( ',', @ASKED ), '10.0.0.5', 'CONTROL: a player whose link is DOWN proves nothing - it is asked' );
    ok( !defined $sync, 'and the page waits for it' );

    reset_store();
    $prefs->set( addresses => '' );
    $HOLD{'10.0.0.5'} = [ 'up', 'Kept' ];
    %UP = ( '10.0.0.6' => 'New' );
    my $async;
    ( $p, $sync, $async ) = post( mode => 0, addresses => '10.0.0.5, 10.0.0.6' );
    is( join( ',', @ASKED ), '10.0.0.6', 'one connected, one new: only the new one is asked' );
    answer_all();
    is( join( ' | ', @{ $p->{hqp_found} || [] } ),
        "Saved: HQPlayer 'Kept' answered at 10.0.0.5. | Saved: HQPlayer 'New' answered at 10.0.0.6.",
        'and both are named, in the order typed' );
}

print "-- the page's answer is the save's answer: ONE connection a new address --\n";
{
    reset_store();
    %UP = ( '10.0.0.7' => 'Lounge' );
    post( mode => 0, addresses => '10.0.0.7' );
    answer_all();
    is( $SAVED, 1, 'saved' );

    # What the save's apply does next turn (Plugin::_applySettings).
    @ASKED = ();
    $A->can('set')->( ['10.0.0.7'] );
    $A->can('verify')->( sub { () } );
    is( scalar @ASKED, 0, 'the apply keys it from the page\'s answer - it does not ask the same HQPlayer again' );
    is( ( $A->can('entry')->('10.0.0.7') || {} )->{name}, 'Lounge', 'under the name the page was given' );

    $A->can('verify')->( sub { () } );
    is( scalar @ASKED, 1, 'used ONCE: with still no player at a later round, it is asked over TCP as before' );

    # A refused save hands nothing on, not even the address that answered.
    reset_store();
    %UP = ( '10.0.0.7' => 'Lounge' );
    post( mode => 0, addresses => '10.0.0.7, 10.0.0.8' );
    answer_all();
    is( $SAVED, 0, 'CONTROL: one dead address refuses the save' );
    @ASKED = ();
    $A->can('set')->( ['10.0.0.7'] );
    $A->can('verify')->( sub { () } );
    is( scalar @ASKED, 1, 'and its live neighbour\'s answer was not kept - a later save asks it itself' );

    # An answer for an address that did not end up in the box is dropped.
    reset_store();
    $A->can('answered')->( '10.0.0.9', { name => 'Gone' } );
    $A->can('set')->( ['10.0.0.1'] );
    $A->can('set')->( [ '10.0.0.1', '10.0.0.9' ] );
    $A->can('verify')->( sub { () } );
    ok( scalar( grep { $_ eq '10.0.0.9' } @ASKED ), 'an answer set() saw left out of the box is dropped, not kept for later' );
}

print "-- a bad entry is NAMED and NOTHING is saved --\n";
# Non-ASCII digits arrive as CHARACTERS - LMS decodes every form value
# (Slim::Web::HTTP, utf8decode) - so they are written that way here. A bare
# \d took them as digits and `+ 0` misread them (review 2026-09-28, finding 7).
binmode STDOUT, ':encoding(UTF-8)';
for my $case ( [ 'hqplayer.local', 'a host name' ], [ '192.168.1', 'a short address' ],
               [ '192.168.1.300', 'an octet over 255' ], [ 'fe80::1', 'an IPv6 address' ],
               [ '239.192.0.199', 'the multicast group' ],
               [ "192.168.1.\x{FF11}\x{FF10}", 'full-width digits (a CJK input method)' ],
               [ "192.168.1.1\x{FF10}",        'one full-width digit (was read as .1)' ],
               [ "192.168.1.\x{0661}\x{0660}", 'Arabic-Indic digits' ] ) {
    my ( $bad, $what ) = @$case;
    reset_store();
    my ( $p ) = post( mode => 0, addresses => "10.0.0.5, $bad" );
    is( $SAVED, 0, "$what: nothing is saved" );
    is( $prefs->get('addresses') . '/' . $prefs->get('autodiscover'), '10.0.0.1/1',
        "$what: not even the good address, or the mode" );
    ok( scalar( ( $p->{hqp_error} // '' ) =~ /'\Q$bad\E'/ ), "$what: the error names '$bad'" );
    is( $p->{hqp_addresses}, "10.0.0.5, $bad", "$what: and the box still shows what was typed" );
    is( scalar @ASKED, 0, "$what: and no HQPlayer is asked" );
}

print "-- addresses only, and none, IS SAVED - off is off --\n";
{
    reset_store();
    my ( $p, $sync ) = post( mode => 0, addresses => '' );
    is( $SAVED . '/' . ( $p->{hqp_error} // 'none' ), '1/none',
        'saved, with no error (Simon: no player without an IP added - the old refusal is REVERSED)' );
    is( $prefs->get('autodiscover') . '/' . $prefs->get('addresses'), '0/', 'discovery off, the box empty' );
    is( $sync, 'rendered', 'at once - there is nothing to ask' );
    is( scalar @ASKED, 0, 'and no HQPlayer is asked' );
    is( $p->{hqp_auto}, 0, 'and the page stays on addresses-only' );
    ok( !grep( { /ADDR_NEEDED/ } do { local ( @ARGV, $/ ) = ('../HQPlayerBridge/strings.txt'); <> } ),
        'the refusal string is gone' );
}

print "-- a partial POST changes nothing --\n";
{
    reset_store();
    my %p = ( saveSettings => 1 );
    $S->handler( undef, \%p );
    is( $prefs->get('addresses') . '/' . $prefs->get('autodiscover'), '10.0.0.1/1',
        'no sentinel: the box is not blanked and the mode is not changed' );
}

print "-- EVERY save that goes through says what it did --\n";
# Simon, 2026-09-27: saving a blank box "gave no message at all".
{
    my $lines = sub { join ' | ', @{ $_[0]->{hqp_found} || [] } };
    my $state = sub { my ( $auto, $box ) = @_; reset_store(); $prefs->set( autodiscover => $auto ); $prefs->set( addresses => $box ) };

    $state->( 0, '10.0.0.1' );
    my ( $p, $sync ) = post( mode => 0, addresses => '' );
    is( $lines->($p), 'Saved: removed 10.0.0.1. | Saved: no HQPlayer address entered, so there are no players until you add one.',
        'addresses only, box BLANKED: names what went, and says there are no players until one is added' );
    is( $sync, 'rendered', 'at once' );

    $state->( 1, '' );
    ( $p ) = post( mode => 0, addresses => '' );
    is( $lines->($p), 'Saved: no HQPlayer address entered, so there are no players until you add one.',
        'switched to addresses only with a blank box: the same' );

    $state->( 0, '10.0.0.1, 10.0.0.2' );
    ( $p ) = post( mode => 0, addresses => '10.0.0.1' );
    is( $lines->($p), 'Saved: removed 10.0.0.2.', 'an address removed: named' );

    $state->( 0, '10.0.0.1' );
    ( $p ) = post( mode => 0, addresses => '10.0.0.1' );
    is( $lines->($p), 'Saved.', 'nothing changed: Saved.' );

    $state->( 0, '10.0.0.1, 10.0.0.2' );
    %UP = ( '10.0.0.3' => 'New' );
    my ( $q, undef, $async ) = post( mode => 0, addresses => '10.0.0.1, 10.0.0.3' );
    answer_all();
    is( $lines->($q), "Saved: removed 10.0.0.2. | Saved: HQPlayer 'New' answered at 10.0.0.3.",
        'one removed and one added in a save: both said, removal first' );

    $state->( 0, '10.0.0.1' );
    ( $p ) = post( mode => 1 );
    is( $lines->($p), 'Saved: HQPlayer is now found automatically. The addresses were cleared and their players removed.',
        'switched to automatically: says so, and that the addresses went' );

    $state->( 0, '' );
    ( $p ) = post( mode => 1 );
    is( $lines->($p), 'Saved: HQPlayer is now found automatically.', 'switched to automatically from an empty box: no "cleared"' );

    $state->( 1, '' );
    ( $p ) = post( mode => 1 );
    is( $lines->($p), 'Saved.', 'automatically, and it already was: Saved.' );

    $state->( 1, '10.0.0.1' );    # a stale box under automatic - the page never stores one, a `pref` could
    ( $p ) = post( mode => 0, addresses => '' );
    is( $lines->($p), 'Saved: no HQPlayer address entered, so there are no players until you add one.',
        'coming FROM automatic, whatever the pref held was not in use - nothing is called "removed"' );

    $state->( 0, '10.0.0.1' );
    ( $p ) = post( mode => 0, addresses => 'bad.host' );
    ok( !$p->{hqp_found}, 'CONTROL: a REFUSED save says only why - no "Saved" line' );
}

print "-- the page's \"checking\" line is given the SAVED list --\n";
{
    reset_store();
    $prefs->set( addresses => '10.0.0.1' ); $prefs->set( autodiscover => 0 );
    my %p;
    $S->handler( undef, \%p );
    is( $p{hqp_saved}, '10.0.0.1', 'an ordinary page: the saved addresses' );

    reset_store();
    $prefs->set( addresses => '10.0.0.1' ); $prefs->set( autodiscover => 0 );
    %UP = ();
    my ( $q ) = post( mode => 0, addresses => '10.0.0.1, 10.0.0.9' );
    answer_all();
    is( $q->{hqp_saved} . ' / ' . $q->{hqp_addresses}, '10.0.0.1 / 10.0.0.1, 10.0.0.9',
        'a REFUSED page: still the SAVED list, while the box shows what was typed - so saving again says it is checking' );

    # Stored AUTOMATIC: no list is in use, so the page's list is empty, as the
    # save's is (review finding 4) - the stale 10.0.0.1 would be checked.
    reset_store();    # 10.0.0.1 in the pref, automatic on
    %p = ();
    $S->handler( undef, \%p );
    is( $p{hqp_saved}, '', 'stored automatic: NO saved list - a switch starts fresh, and says it is checking' );
    ( $q ) = post( mode => 0, addresses => '10.0.0.1' );
    answer_all();
    is( $q->{hqp_saved} // '', '', 'and a REFUSED switch from automatic: still none' );

    my $tmpl = do { local ( @ARGV, $/ ) = ('../HQPlayerBridge/HTML/EN/plugins/HQPlayerBridge/settings/basic.html'); <> };
    ok( scalar( $tmpl =~ /id="hqp_checking"[^>]*data-saved="\[% hqp_saved \| html %\]"/ ), 'and the template hands it to the script' );

    # The addresses a CONNECTED player holds: the save asks nothing there
    # (review finding 6), so the page is told, and leaves them out.
    reset_store();
    %HOLD = ( '10.0.0.7' => [ 'up', 'Den' ], '10.0.0.8' => [ 'down', 'Loft' ] );
    %p = ();
    $S->handler( undef, \%p );
    is( $p{hqp_held}, '10.0.0.7', 'the page is given the addresses held over a PROVEN link - not a down one' );
    ok( scalar( $tmpl =~ /id="hqp_checking"[^>]*data-held="\[% hqp_held \| html %\]"/ ), 'and the template hands them to the script' );
}

# THE SCRIPT, EXECUTED - not grepped. JavaScriptCore via osascript (no node on
# this Mac); SKIPPED out loud anywhere without it.
print "\n-- the checking script, executed --\n";
{
    my $osa = `which osascript 2>/dev/null`; chomp $osa;
    if ( !$osa ) {
        print "  skip no osascript here - the script is only source-checked\n";
    }
    else {
        my @out = `$osa -l JavaScript t_settings_page.js ../HQPlayerBridge/HTML/EN/plugins/HQPlayerBridge/settings/basic.html 2>&1`;
        print @out;
        my ( $p, $f ) = ( join( '', @out ) =~ /(\d+) passed, (\d+) failed/ );
        ok( scalar( defined $p && $p > 0 && defined $f && $f == 0 ),
            defined $f ? "the executed script: $p passed, $f failed" : 'the executed script reported nothing' );
    }
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit( $fail ? 1 : 0 );
