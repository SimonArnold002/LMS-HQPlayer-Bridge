package Plugins::HQPlayerBridge::Addresses;

# HQPlayer addresses typed into the settings page - the one box, several
# addresses. Docs: docs/discovery-simplification-plan.md sections 4.5 and 4.6.
#
# USED ONLY WITH AUTOMATIC DISCOVERY OFF (Simon, 2026-09-27: "we should not be
# having both active at same time"). With it on the box is empty and this list
# is too - see Plugin::_boxAddresses.
#
# Each address is keyed by its HQPlayer's NAME, never its address, exactly as
# a discovery reply is - so a user can delete an address and add it back, or
# replace it with HQPlayer's new one, and get the SAME player with its prefs
# and playlist. The name comes from:
#   - the player that already holds the address (discovery had found it, and
#     discovery has just been switched off) - no second control connection;
#   - the settings page's own <GetInfo/> answer, from the save that added
#     the address (answered) - used once, so a save costs ONE connection;
#   - otherwise one TCP <GetInfo/> (Control::identify), once a round until it
#     answers. A dead host costs one TCP attempt, not a line in anyone's
#     HQPlayer log.
#
# An address never expires: its player stays for as long as it is in the box.
# One whose link is down is left to that link, which reconnects on its own
# ladder. Addresses are checked on the discovery ROUND clock, the plugin's one
# clock, which keeps running with discovery off.
#
# NO ROUND OR lastSeen STAMP. Those exist for discovery's own entries - its TTL
# and Plugin::_liveOf's DHCP-move collapse - and neither applies here.
#
# TWO TYPED ADDRESSES ANSWERING TO ONE NAME ARE TWO PLAYERS, always - each is
# keyed by its name AND its address, down or not (Simon, 2026-09-27). The
# DHCP-move collapse in Plugin::_idsFor skips any group holding a typed
# address (`configured`), and that guard is the whole rule.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::HQPlayerBridge::Control;

my $log   = logger('plugin.hqplayerbridge');
my $prefs = preferences('plugin.hqplayerbridge');

# Automatic discovery when `autodiscover` has never been set - the ONE place
# the default lives; Plugin.pm's prefs->init and the settings page both read it.
#
# ON (Simon, 2026-09-27, after the off-by-default test builds 1.0.30-1.0.33):
# a new install, or an update from a release without this pref, finds HQPlayer
# exactly as before - nothing to configure for most setups.
#
# A DEFAULT NEVER OVERRIDES A USER'S CHOICE ON UPDATE (Simon, same day: "for
# any more updates it doesnt lose setting if you have it set to manual"). It
# only ever fills a pref that has never been stored: LMS's prefs->init sets a
# missing key and leaves a stored one alone (fleet-measured - LBF's `all_past`,
# stored as null by an unticked box, stayed null through restarts and updates
# despite init's default of 1). The settings page always stores an EXPLICIT 0
# or 1, and nothing else in this plugin writes `autodiscover` or `addresses`
# (pinned in t_plugin.pl) - so a user on addresses-only stays there, with their
# list, whatever this constant says in a later release.
use constant AUTO_DEFAULT => 1;

# The STORED mode: is automatic discovery on? The ONE reading of the pref -
# Plugin.pm and the settings page both ask this, so the plugin, the save and
# the page cannot disagree about which mode is in use. Never set means
# AUTO_DEFAULT. (What the settings page POSTS is a different question, read
# from the radio in Settings::handler.)
#
# OFF IS OFF, WHATEVER THE BOX HOLDS (Simon, 2026-09-27: "It should not
# discover or add any player without an IP added when in manual mode"). Off
# with an empty box is a bridge with no players until an address is typed -
# never discovery running on its own. (A first build refused that save, and
# inline review 2 then kept discovery running for it; both REVERSED.)
sub autoDiscover {
    my $v = $prefs->get('autodiscover');
    return defined $v ? ( $v ? 1 : 0 ) : AUTO_DEFAULT;
}

my @list;        # the box, parsed and normalised, in the user's order
my %entry;       # ip => { ip, name, version, configured } once identified
my %pending;     # ip => 1 while an identify is out
my %failed;      # ip => 1 once a failure has been reported - one line per outage
my %answered;    # ip => GetInfo's attributes, from the settings page's check - used once
my $onChange;    # called with no arguments when an address is newly identified
my $stateAt;     # Plugin::_linkStateAt - is a player already at this address?
my $heldAt;      # Plugin::_heldAddresses - every address a player holds over a PROVEN link

# ---------------------------------------------------------------------------
# Parsing. One rule, used by the settings page to refuse a save and by the
# plugin to read what was saved, so the two cannot disagree.
#
# Separated by commas, spaces, semicolons or new lines. IPv4 only, because the
# control link is (IO::Socket::INET) and discovery is (239.192.0.199). NO HOST
# NAMES (Simon, 2026-09-27): resolving one is a blocking DNS call in LMS's
# event loop - the restart helper's `allow` refuses them for the same reason.
#
# Returns ( \@ok, \@bad ): the normalised addresses, de-duplicated, in order;
# and every entry that is not one, exactly as typed, so it can be NAMED.
# ---------------------------------------------------------------------------
sub parse {
    my $text = shift;
    $text = '' unless defined $text;

    my ( @ok, @bad, %seen );

    for my $tok ( split /[\s,;]+/, $text ) {
        next unless length $tok;

        my $ip = normalise($tok);

        if ( !defined $ip ) {
            push @bad, $tok;
            next;
        }

        push @ok, $ip unless $seen{$ip}++;
    }

    return ( \@ok, \@bad );
}

# A dotted quad, read as DECIMAL: "192.168.001.010" is 192.168.1.10.
# inet_aton would read a leading zero as OCTAL (010 = 8), and the table is
# keyed by the string discovery reports, so both reasons say normalise here.
# Refused: anything else, 0.x.x.x, and multicast/broadcast (224 and up).
#
# ASCII DIGITS ONLY (/a). LMS hands a form field over DECODED (HTTP.pm's
# utf8decode), and a bare \d matches any Unicode digit - full-width from a CJK
# input method, Arabic-Indic - which `+ 0` then misreads: "192.168.1.１０"
# became 192.168.1.0 and "192.168.1.1０" 192.168.1.1, an address never typed.
# The page's JS `norm` is ASCII-only already; keep the two in step.
sub normalise {
    my $t = shift;

    return undef unless defined $t && $t =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/a;

    my @o = map { $_ + 0 } ( $1, $2, $3, $4 );

    return undef if grep { $_ > 255 } @o;
    return undef if $o[0] == 0 || $o[0] >= 224;

    return join '.', @o;
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
sub init {
    ( $onChange, $stateAt, $heldAt ) = @_;
    return;
}

# The box as saved. Returns the addresses that LEFT it, which the caller
# removes at once. An address kept keeps its identity - nothing re-identifies
# it on a save.
sub set {
    my $new = shift || [];

    my %keep    = map { $_ => 1 } @$new;
    my @removed = grep { !$keep{$_} } @list;

    for my $ip (@removed) {
        delete $entry{$ip};
        delete $failed{$ip};
    }

    delete $answered{$_} for grep { !$keep{$_} } keys %answered;

    @list = @$new;

    return \@removed;
}

sub reset {
    @list     = ();
    %entry    = ();
    %pending  = ();
    %failed   = ();
    %answered = ();
    $onChange = undef;
    $stateAt  = undef;
    $heldAt   = undef;
    return;
}

sub list  { return [@list] }
sub has   { my $ip = shift; return scalar grep { $_ eq $ip } @list }
sub entry { my $ip = shift; return $entry{$ip} }

# For the settings page, which calls nothing in Plugin.pm: the name of the
# HQPlayer whose player holds this address over a PROVEN link, or undef. That
# link is already the connection the page's check asks for, so the page names
# it from the player and opens no second one beside it.
sub held {
    my $ip = shift;

    return undef unless $stateAt;

    my ( $s, $name ) = $stateAt->($ip);
    return undef unless defined $s && $s eq 'up';

    return defined $name && length $name ? $name : 'HQPlayer';
}

# Every address held() would answer for, for the settings page's "checking"
# line: the save asks no HQPlayer at these, so the page names none of them.
sub heldAll {
    return [] unless $heldAt;
    return [ $heldAt->() ];
}

# The settings page's own <GetInfo/> answer for an address it is about to
# save. The save's apply (the next event-loop turn) keys the address from it
# instead of asking the same HQPlayer again a second later. Used once, by the
# next verify; dropped by set() if the address is not in the box.
sub answered {
    my ( $ip, $attrs ) = @_;
    $answered{$ip} = $attrs if $ip && $attrs;
    return;
}

# ---------------------------------------------------------------------------
# Once a round (Discovery's onRound), and at once after a settings save
# (Plugin::_applySettings). $state->($ip) says whether a player
# already holds that address: ( 'up' | 'down', its HQPlayer's name ), or an
# empty list for no player.
# ---------------------------------------------------------------------------
sub verify {
    my ($state) = @_;

    for my $ip (@list) {
        my ( $s, $name ) = $state ? $state->($ip) : ();
        my $told = delete $answered{$ip};

        # NO PLAYER: find out who is there - from the answer the settings page
        # just had, or over TCP, once a round.
        if ( !defined $s ) {
            $told ? _identified( $ip, $told ) : _identify($ip);
            next;
        }

        # A PLAYER ALREADY HOLDS IT - the address of an HQPlayer discovery had
        # found, typed in as discovery is switched off. Keyed from that
        # player's name, with NO second control connection to an HQPlayer this
        # plugin is already connected to.
        if ( !$entry{$ip} ) {
            $entry{$ip} = {
                ip         => $ip,
                name       => defined $name && length $name ? $name : 'HQPlayer',
                version    => '',
                configured => 1,
            };
        }
    }

    return;
}

sub _identify {
    my $ip = shift;

    return if $pending{$ip};
    $pending{$ip} = 1;

    Plugins::HQPlayerBridge::Control->identify( $ip, sub { _identified( $ip, @_ ) } );

    return;
}

sub _identified {
    my ( $ip, $attrs ) = @_;

    delete $pending{$ip};

    # Taken out of the box while we were asking.
    return unless has($ip);

    if ( !$attrs ) {
        if ( !$failed{$ip}++ ) {
            $log->warn("HQPlayer at $ip (from the settings) is not answering"
                . ' - trying again every round, further attempts are logged at debug');
        }
        else {
            main::DEBUGLOG && $log->is_debug && $log->debug("HQPlayer at $ip is still not answering");
        }
        return;
    }

    if ( delete $failed{$ip} ) {
        main::INFOLOG && $log->is_info && $log->info("HQPlayer at $ip is answering again");
    }

    my $name    = Plugins::HQPlayerBridge::Control::pick( $attrs, 'name' ) || 'HQPlayer';
    my $version = join ' ', grep { defined && length }
        Plugins::HQPlayerBridge::Control::pick( $attrs, 'product' ),
        Plugins::HQPlayerBridge::Control::pick( $attrs, 'version' );

    my $old = $entry{$ip};

    $entry{$ip} = {
        ip         => $ip,
        name       => $name,
        version    => $version,
        configured => 1,
    };

    main::INFOLOG && $log->is_info && ( !$old || $old->{name} ne $name )
        && $log->info("HQPlayer at $ip (from the settings) is '$name'");

    # Announced at once, as a new discovery reply is - but only when it is
    # news. The complete round that follows reconciles everything else.
    $onChange->() if $onChange && ( !$old || $old->{name} ne $name );

    return;
}

1;
