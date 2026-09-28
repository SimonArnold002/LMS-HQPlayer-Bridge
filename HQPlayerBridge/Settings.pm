package Plugins::HQPlayerBridge::Settings;

# The settings page: how HQPlayer is found - automatically, or ONLY from the
# addresses typed into one box. Two modes, never both (Simon, 2026-09-27).
# docs/discovery-simplification-plan.md sections 4.5-4.6 and decision 4.
#
# House rules, from the fleet:
#   - every field is `pref_<name>`, or LMS logs an error per field per save;
#   - THE MODE IS A RADIO GROUP, to LBF's spec (its sort and genre_lookup
#     groups): <label>-wrapped, <br>-separated, no <select>, and EXACTLY ONE
#     option checked in every state - decided HERE in Perl (hqp_auto), never
#     by matching a stored value in the template. A group with nothing checked
#     submits nothing, and an unset or odd stored value then silently fails to
#     apply; that bug has caught the fleet more than once;
#   - a hidden `hqp_form` sentinel the real form always posts, so a partial
#     POST changes nothing;
#   - Material never shows `warning`, so every result is drawn IN the page;
#   - this module calls nothing in Plugin.pm. A save takes effect through the
#     prefs' change handler (Plugin::_settingsChanged); the parser lives in
#     Addresses.pm and the connection check in Control.pm, both `use`d here.
#
# A NEW ADDRESS IS SAVED ONLY IF HQPLAYER ANSWERS THERE. HQPlayer must be up
# and running to be added (Simon, 2026-09-27) - the same shape as LBF's token
# check: the handler returns nothing, each new address is asked <GetInfo/>, and
# the page is rendered through $callback once every answer (or the deadline)
# is in. An address already in the box is not re-checked: it never expires,
# and one HQPlayer being off must not block editing the others. Nor is one a
# player is CONNECTED at (typed as discovery is switched off): that proven
# link is the answer, and a second connection beside it is what inline review
# 2 removed (review 3, 2026-09-27). Each answer is handed to Addresses, so the
# save's own apply does not ask the same HQPlayer again - ONE connection a
# new address, at most.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Time::HiRes ();

use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Timers;

use Plugins::HQPlayerBridge::Addresses;
use Plugins::HQPlayerBridge::Control;

my $prefs = preferences('plugin.hqplayerbridge');

# The longest a save waits for HQPlayer to answer before the page is drawn.
# Control's own connect timeout is 5s; an HQPlayer that accepts and never
# replies would otherwise hold the page for Control's 30s reply window.
use constant CHECK_WAIT => 8;

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_HQPLAYER_BRIDGE') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/HQPlayerBridge/settings/basic.html') }

# The base class saves these one at a time; Plugin::_settingsChanged waits
# until both are stored before acting, so their order does not matter.
sub prefs { return ( $prefs, qw(addresses autodiscover) ) }

sub handler {
    my ( $class, $client, $params, $callback, @args ) = @_;

    if ( $params->{saveSettings} ) {

        if ( !defined $params->{hqp_form} ) {
            # Not the real form (a partial POST): keep what is stored rather
            # than blanking the box or changing the mode.
            $params->{"pref_$_"} = $prefs->get($_) for qw(addresses autodiscover);
            return $class->SUPER::handler( $client, $params, $callback, @args );
        }

        # The radio posts "1" (automatic) or "0" (addresses only). Anything
        # else - nothing posted at all included - is the default
        # (Addresses::AUTO_DEFAULT).
        my $posted = $params->{pref_autodiscover} // '';
        my $auto   = $posted eq '1' ? 1
                   : $posted eq '0' ? 0
                   : Plugins::HQPlayerBridge::Addresses::AUTO_DEFAULT();
        $params->{pref_autodiscover} = $auto;

        # What is SAVED now, to say what this save changed - and, below, which
        # addresses it adds and so must check.
        my $wasAuto = Plugins::HQPlayerBridge::Addresses::autoDiscover();

        # The box IN USE. Coming from automatic there is none: whatever the
        # pref holds was not in use, so each mode starts fresh and every
        # address typed on the switch is new, and checked (Simon, 2026-09-27).
        my ($had)   = $wasAuto ? ( [] ) : Plugins::HQPlayerBridge::Addresses::parse( $prefs->get('addresses') );

        # AUTOMATIC: the box is CLEARED - the typed players go on this save
        # (Plugin::_applySettings) and discovery finds again whatever it can
        # reach, under the same ids. A greyed-out box posts nothing anyway.
        if ($auto) {
            $params->{pref_addresses} = '';
            $params->{hqp_found}      = _savedLines( 1, $wasAuto, $had );
            return $class->SUPER::handler( $client, $params, $callback, @args );
        }

        my ( $ok, $bad ) = Plugins::HQPlayerBridge::Addresses::parse( $params->{pref_addresses} );

        # A bad entry is NAMED and nothing is saved - not the good ones
        # either, so the box never holds half of what was typed.
        return _refuse( $class, $client, $params, $callback, \@args,
            sprintf( Slim::Utils::Strings::string('PLUGIN_HQPLAYER_ADDR_BAD'),
                     join( ', ', map { "'$_'" } @$bad ) ) )
            if @$bad;

        # Addresses only, and none, IS SAVED: every player goes, and none
        # comes back until an address is typed (Simon, 2026-09-27: "It should
        # not discover or add any player without an IP added when in manual
        # mode"). The first build refused this save; REVERSED.

        $params->{pref_addresses} = join( ', ', @$ok );

        # Only the addresses this save ADDS are checked.
        my %had = map { $_ => 1 } @$had;
        my @new = grep { !$had{$_} } @$ok;

        if ( !@new ) {
            $params->{hqp_found} = _savedLines( 0, $wasAuto, $had, $ok );
            return $class->SUPER::handler( $client, $params, $callback, @args );
        }

        # Connected already: named from its player, no connection.
        my %names = map {
            my $n = Plugins::HQPlayerBridge::Addresses::held($_);
            defined $n ? ( $_ => $n ) : ();
        } @new;
        my @ask = grep { !exists $names{$_} } @new;

        return _saved( $class, $client, $params, $callback, \@args, $wasAuto, $had, $ok, \@new, \%names ) if !@ask;

        _check( \@ask, sub {
            my $found = shift;    # ip => GetInfo's attributes, or undef where nothing answered

            my @dead = grep { !$found->{$_} } @ask;

            my $body;

            if (@dead) {
                $body = _refuse( $class, $client, $params, undef, \@args,
                    sprintf( Slim::Utils::Strings::string('PLUGIN_HQPLAYER_ADDR_DEAD'),
                             join( ', ', @dead ) ) );
            }
            else {
                for my $ip (@ask) {
                    $names{$ip} = Plugins::HQPlayerBridge::Control::pick( $found->{$ip}, 'name' ) || 'HQPlayer';

                    # Before the save, whose apply keys the address from it.
                    Plugins::HQPlayerBridge::Addresses::answered( $ip, $found->{$ip} );
                }

                $body = _saved( $class, $client, $params, undef, \@args, $wasAuto, $had, $ok, \@new, \%names );
            }

            $callback->( $client, $params, $body, @args );
        } );

        return;    # async: the page is delivered through $callback above
    }

    return $class->SUPER::handler( $client, $params, $callback, @args );
}

# Save, naming the HQPlayer at each new address.
sub _saved {
    my ( $class, $client, $params, $callback, $args, $wasAuto, $had, $ok, $new, $names ) = @_;

    $params->{hqp_found} = _savedLines( 0, $wasAuto, $had, $ok, $new, $names );

    return $class->SUPER::handler( $client, $params, $callback, @$args );
}

# EVERY SAVE THAT GOES THROUGH SAYS WHAT IT DID (Simon, 2026-09-27: saving a
# blank box "gave no message at all"). Formatted HERE, as the refusals are:
# the template only prints finished strings.
#
#   automatically, it already was      Saved.
#   switched to automatically          now found automatically (+ the addresses cleared, if any)
#   addresses only                     removed ..., HQPlayer 'x' answered at ... (each new one),
#                                      no address entered (an empty box) - or Saved. if none of those
sub _savedLines {
    my ( $auto, $wasAuto, $had, $ok, $new, $names ) = @_;

    my $s = sub { Slim::Utils::Strings::string( 'PLUGIN_HQPLAYER_' . shift ) };

    if ($auto) {
        return [ $s->('SAVED') ] if $wasAuto;
        return [ $s->('SAVED_AUTO') . ( @$had ? ' ' . $s->('SAVED_CLEARED') : '' ) ];
    }

    # Removed means taken out of a box that was IN USE - coming from
    # automatic, whatever the pref held was not.
    my %keep = map { $_ => 1 } @$ok;
    my @gone = $wasAuto ? () : grep { !$keep{$_} } @$had;

    my @lines;
    push @lines, sprintf( $s->('ADDR_REMOVED'), join( ', ', @gone ) ) if @gone;
    push @lines, map { sprintf( $s->('ADDR_FOUND'), $names->{$_}, $_ ) } @{ $new || [] };
    push @lines, $s->('ADDR_EMPTY') if !@$ok;
    push @lines, $s->('SAVED') if !@lines;

    return \@lines;
}

# Draw the page with the reason, and SAVE NOTHING: with no saveSettings the
# base class writes no pref. The box keeps what was typed so nothing has to be
# typed again.
sub _refuse {
    my ( $class, $client, $params, $callback, $args, $error ) = @_;

    $params->{hqp_error} = $error;
    $params->{hqp_typed} = $params->{pref_addresses};

    delete $params->{saveSettings};

    return $class->SUPER::handler( $client, $params, $callback, @$args );
}

# Ask each address <GetInfo/> at once, and call $done->( { ip => attrs|undef } )
# exactly ONCE: when every one has answered or failed, or at CHECK_WAIT,
# whichever is first. An answer after that is ignored.
sub _check {
    my ( $ips, $done ) = @_;

    my %found;
    my $left     = scalar @$ips;
    my $finished = 0;
    my $timer    = {};    # the object the deadline timer hangs off

    my $finish = sub {
        return if $finished++;
        Slim::Utils::Timers::killTimers( $timer, \&_deadline );
        $done->( {%found} );
    };

    Slim::Utils::Timers::setTimer( $timer, Time::HiRes::time() + CHECK_WAIT, \&_deadline, $finish );

    for my $ip (@$ips) {
        $found{$ip} = undef;

        Plugins::HQPlayerBridge::Control->identify( $ip, sub {
            my ($attrs) = @_;
            return if $finished;
            $found{$ip} = $attrs if $attrs;
            $finish->() if --$left <= 0;
        } );
    }

    return;
}

sub _deadline { $_[1]->() }

# After the save, before the page is drawn - so a saved page shows what was
# SAVED (built in handler() it would show the old values). A refused save
# shows what was TYPED, with the reason above it, so nothing has to be typed
# again.
#
# hqp_auto decides BOTH radios: the template checks "automatic" when it is 1
# and "addresses only" when it is 0, so exactly one is checked in every state.
# Never set means Addresses::AUTO_DEFAULT - see its comment.
sub beforeRender {
    my ( $class, $params ) = @_;

    # The mode SAVED now - read once, for both the page's radio and hqp_saved.
    my $wasAuto = Plugins::HQPlayerBridge::Addresses::autoDiscover();

    if ( $params->{hqp_error} ) {
        # Only an addresses-only save is ever refused - an automatic one has
        # no addresses to check - so a refused page is always addresses-only.
        $params->{hqp_addresses} = $params->{hqp_typed};
        $params->{hqp_auto}      = 0;
    }
    else {
        $params->{hqp_addresses} = $prefs->get('addresses') // '';
        $params->{hqp_auto}      = $wasAuto;
    }

    # The addresses already SAVED - what handler() compares against to decide
    # what a save adds, and so what it will wait on. The page's "checking"
    # line uses the same list, so it appears exactly when the save will check.
    # Stored automatic means NONE, exactly as handler() reads it: the pref is
    # not in use there, so a switch starts fresh (a refused switch included).
    $params->{hqp_saved} = $wasAuto ? '' : $prefs->get('addresses') // '';

    # And the addresses a CONNECTED player already holds: handler() names
    # those from the player (Addresses::held) and asks nothing, so the line
    # leaves them out as well.
    $params->{hqp_held} = join ', ', @{ Plugins::HQPlayerBridge::Addresses::heldAll() };

    return;
}

1;
