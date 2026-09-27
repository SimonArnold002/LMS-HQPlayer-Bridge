package Plugins::HQPlayerBridge::Plugin;

# HQPlayer Bridge - present each discovered HQPlayer instance to LMS as an
# ordinary player, driven over HQPlayer's own XML control API.
#
# This replaces the usual squeeze2upnp path.  That bridge runs an external
# binary which holds a real SlimProto session, buffers the audio itself, and
# re-serves it over UPnP/DLNA - two extra hops for what is really a control
# problem.  Both LMS and HQPlayer are pull engines, so this plugin moves no
# audio at all: it hands HQPlayer a URL pointing back at LMS's own HTTP
# server and lets HQPlayer fetch the bytes directly.
#
# Instances are found by multicast, or from addresses typed into the settings
# page (Settings.pm), which is also where automatic discovery can be switched
# off. The other surfaces are the Apps feed and the live view (Live.pm).

use strict;
use warnings;

# OPMLBased, not Base, for ONE reason: it is what registers a top-level app
# entry, and that entry is how the plugin is reachable in Material at all.  The
# feed it serves is a row that opens the live view plus HQPlayer's current
# settings - see topLevel.
use base qw(Slim::Plugin::OPMLBased);

use Digest::MD5 qw(md5_hex);
# pack_sockaddr_in, NOT sockaddr_in: the latter switches on wantarray, so in a
# function-call argument list it is in LIST context, reads its two arguments as
# a request to UNPACK one, and croaks
# "usage: (port,iaddr) = sockaddr_in(sin_sv)".
use Socket qw(pack_sockaddr_in INADDR_LOOPBACK);

use Slim::Utils::Log;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes ();
use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Source;

use Plugins::HQPlayerBridge::Live;
use Slim::Display::NoDisplay;
use Slim::Utils::Strings qw(cstring);

use Plugins::HQPlayerBridge::Addresses;
use Plugins::HQPlayerBridge::Control;
use Plugins::HQPlayerBridge::Discovery;
use Plugins::HQPlayerBridge::Player;
use Plugins::HQPlayerBridge::Stream;

# The version is READ from install.xml, never restated here.  A second copy is
# a copy that goes stale: this was a hand-maintained constant sitting at 0.2.3
# while install.xml and repo.xml were at 0.2.7, so the startup log and the
# live page both reported a build that had not been running for months.
my $VERSION;

sub version {
    return $VERSION if defined $VERSION;

    $VERSION = eval {
        Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__)->{version};
    } || 'unknown';

    return $VERSION;
}

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.hqplayerbridge',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_HQPLAYER_BRIDGE',
});

# The settings page's two prefs. The default mode is Addresses::AUTO_DEFAULT.
my $prefs = preferences('plugin.hqplayerbridge');
$prefs->init( { addresses => '', autodiscover => Plugins::HQPlayerBridge::Addresses::AUTO_DEFAULT() } );

# id => { instance => {...}, control => $ctl, client => $client }
my %bridges;
my %splitWarned;  # name => the addresses last reported as a same-named pair

# ip => 1 once that host's restart helper answered; never shrinks in a run.
# See _probeRestart.
my %restartable;
my %probedAt;       # ip => when it was last asked - the REPROBE_AFTER throttle

# The Restart rows, in the order they first appeared: bridge ids, APPEND-ONLY
# for the server run, plus the name each was last seen under. See topLevel.
my @restartRows;
my %restartName;

sub getDisplayName { 'PLUGIN_HQPLAYER_BRIDGE' }

sub initPlugin {
    my $class = shift;

    # is_app puts it under Apps, where Material can pin it to the home screen.
    #
    # `menu` IS DISCARDED HERE, and passing it is only convention. Checked
    # against LMS's own OPMLBased: `if ($args{is_app}) { $args{menu} = 'apps' }`
    # runs before initJive/initCLI/webPages read it, so with is_app set the
    # value handed in never survives. The siblings all pass 'radios' and land
    # under Apps for exactly this reason - it is not the 'radios' doing it.
    $class->SUPER::initPlugin(
        tag    => 'hqplayerbridge',
        feed   => \&topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 80,
        @_,
    );

    main::INFOLOG && $log->is_info && $log->info( 'HQPlayer Bridge v' . $class->version . ' starting' );

    # The tier 4 audio endpoint.  Registered before discovery so that a player
    # created by the very first probe reply already has somewhere to point.
    Plugins::HQPlayerBridge::Stream->init;

    # The standalone live page. A raw handler, so it owes nothing to the skin
    # or to any wrapper - see Live.pm for why that matters.
    Plugins::HQPlayerBridge::Live->init( $class->version );

    # What the live page polls. Registered unconditionally: it is a CLI
    # query like any other, reachable over jsonrpc and the command line whether
    # or not a web UI is running.
    Slim::Control::Request::addDispatch(
        [ 'hqplayerbridge', 'signalpath' ], [ 0, 1, 0, \&_signalPathQuery ] );

    # A disconnected player can now be FORGOTTEN from LMS - `client forget`
    # refuses a connected one, and these used to read connected for ever. When
    # that happens the bridge lets go too, or its control link would go on
    # reconnecting a player LMS no longer has. NO UI in LMS or Material sends
    # it to this player (Slimproto's timer is for SlimProto clients, and the
    # on-device menu needs a display) - only a third-party app or a hand-typed
    # command. If the instance still answers discovery, or its address is in
    # the settings, the next round (15s at most) makes a FRESH player: unlike a
    # Lyrion player, which returns only when it reconnects, this one returns
    # when discovery answers.
    Slim::Control::Request::subscribe( \&_onForget, [ ['client'], ['forget'] ] );

    if (main::WEBUI) {
        require Plugins::HQPlayerBridge::Settings;
        Plugins::HQPlayerBridge::Settings->new;
    }

    # A saved settings page - or a `pref` command - takes effect AT ONCE: a
    # removed address loses its player now, not at the next round.
    $prefs->setChange( \&_settingsChanged, qw(addresses autodiscover) );

    # A typed address answering for the first time is announced straight
    # away, as a new discovery reply is. Additive only - see _onInstances.
    # _linkStateAt also tells the settings page which addresses are already
    # connected, so its check opens no second link to them.
    Plugins::HQPlayerBridge::Addresses::init( sub { _onInstances( _table(), 1 ) }, \&_linkStateAt );
    Plugins::HQPlayerBridge::Addresses::set( _boxAddresses() );

    _startDiscovery();

    return;
}

# TWO MODES, NEVER BOTH (Simon, 2026-09-27: "only allow manual ip addresses
# when auto is turned off ... we should not be having both active at same
# time"). Automatic discovery ON: the box is empty and ignored. OFF: the box is
# the whole list and no UDP is sent. Switching cleans out the other mode's
# players - see _applySettings.
sub _rawBox {
    my ($ok) = Plugins::HQPlayerBridge::Addresses::parse( $prefs->get('addresses') );
    return $ok;
}

# Never set means Addresses::AUTO_DEFAULT. The settings page always stores an
# explicit 0 or 1 (the mode radio, Settings::handler).
#
# OFF IS OFF, WHATEVER THE BOX HOLDS (Simon, 2026-09-27: "It should not
# discover or add any player without an IP added when in manual mode"). Off
# with an empty box is a bridge with no players until an address is typed -
# never discovery running on its own. (A first build refused that save, and
# inline review 2 then kept discovery running for it; both REVERSED.)
sub _autoDiscover {
    my $v = $prefs->get('autodiscover');
    return defined $v ? ( $v ? 1 : 0 ) : Plugins::HQPlayerBridge::Addresses::AUTO_DEFAULT();
}

# The addresses in use: the box with discovery off, none with it on.
sub _boxAddresses {
    return _autoDiscover() ? [] : _rawBox();
}

# The round clock always runs: with automatic discovery off it opens no socket
# and sends nothing, but its rounds are still when the typed addresses are
# checked.
sub _startDiscovery {
    Plugins::HQPlayerBridge::Discovery->start(
        sub { _onInstances( _table(), $_[1] ) },
        onRound => \&_onRound,
        udp     => _autoDiscover(),
    );

    return;
}

sub _onRound {
    my $round = shift;
    Plugins::HQPlayerBridge::Addresses::verify( $round, \&_linkStateAt );
    return;
}

# Does a player already hold this address? ( 'up' | 'down', its HQPlayer's
# name ), or an empty list for no player. `up` is the proven link - the answer
# Material shows. The name lets a typed address that a player already holds
# be keyed without opening a second control connection to it.
sub _linkStateAt {
    my $ip = shift;

    for my $b ( values %bridges ) {
        my $inst = $b->{instance} or next;
        next unless ( $inst->{ip} // '' ) eq $ip;
        return ( $b->{client} && $b->{client}->connected ? 'up' : 'down', $inst->{name} );
    }

    return;
}

# THE ONE TABLE the players are reconciled against. With the two modes
# exclusive, it is discovery's list OR the typed addresses, never a mix - but
# it is keyed by address either way, so a transition can never make one
# HQPlayer two rows.
sub _table {
    my %t = map { $_->{ip} => { %$_ } } @{ Plugins::HQPlayerBridge::Discovery::instances() };

    for my $ip ( @{ Plugins::HQPlayerBridge::Addresses::list() } ) {
        my $e = Plugins::HQPlayerBridge::Addresses::entry($ip) or next;
        $t{$ip} ||= { %$e };
    }

    return [ map { $t{$_} } sort keys %t ];
}

# LMS fires the change handler once PER PREF, in the middle of a save, so the
# first call would see a half-saved page - the switch flipped but the box not
# yet written, or the other way round. Applied one event-loop turn later
# instead, once, when both are stored.
sub _settingsChanged {
    Slim::Utils::Timers::killTimers( undef, \&_applySettings );
    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time(), \&_applySettings );
    return;
}

# The settings were saved (or a `pref` command changed one).
#
# SWITCHING CLEANS OUT THE OTHER MODE, at once and connected or not (Simon,
# 2026-09-27: "when its turned off clean the records"):
#   - discovery OFF: every player whose address is not in the box goes, and
#     discovery's table is dropped (Discovery->stop);
#   - discovery ON: the box is cleared (by the settings page) and every typed
#     player goes. Discovery finds again whatever it can reach, under the same
#     id - a player is keyed by HQPlayer's name - so its prefs and playlist
#     come back with it.
# Within the typed mode, an address taken out of the box loses its player the
# same way; typing it back brings the same player back.
sub _applySettings {
    my $auto = _autoDiscover();
    my $box  = _boxAddresses();

    my $removed = Plugins::HQPlayerBridge::Addresses::set($box);

    if ( $auto != Plugins::HQPlayerBridge::Discovery::listening() ) {
        main::INFOLOG && $log->is_info && $log->info(
            'automatic discovery ' . ( $auto ? 'on' : 'off - no UDP at all, only the addresses in the settings' ) );

        # Restarting the clock runs a round at once, which keys every address
        # in the box: from the player that already holds it, or over TCP.
        Plugins::HQPlayerBridge::Discovery->stop;
        _startDiscovery();
    }
    else {
        # Anything newly typed is keyed now, not at the next round.
        Plugins::HQPlayerBridge::Addresses::verify(
            Plugins::HQPlayerBridge::Discovery::round(), \&_linkStateAt );
    }

    my %gone = map { $_ => 1 } @$removed;
    my %box  = map { $_ => 1 } @$box;

    for my $id ( keys %bridges ) {
        my $ip = ( $bridges{$id}->{instance} || {} )->{ip};

        next unless defined $ip;
        next if $auto ? !$gone{$ip} : $box{$ip};

        $log->info( ( $bridges{$id}->{name} || $id ) . ": $ip is not in use in the settings any more, removing player" );
        _teardown($id);
    }

    return;
}

sub _onForget {
    my $request = shift;

    # THE ID, NOT ->client: the notification is delivered from the queue
    # AFTER clientForgetCommand has run forgetClient, which deletes the client
    # from %clientHash - and Request::client is a getClient() lookup, so it is
    # always undef here.
    my $id = $request->clientid or return;

    return unless $bridges{$id};

    main::INFOLOG && $log->is_info && $log->info("$bridges{$id}->{name}: forgotten in LMS, dropping its link");
    _teardown($id);

    return;
}

# ---------------------------------------------------------------------------
# ONE TAP TO THE LIVE VIEW - and a Home tile is the ONLY surface that gives it.
#
# AN APPS ENTRY CANNOT OPEN A PAGE, and that is Material's doing, not a choice
# here. Its `apps` command builds every plugin entry itself, hardcoded:
#
#     $request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
#     my $actions = { go => { cmd => [ $app->tag, 'items' ], ... } };
#
# There is no `weblink` field a plugin can supply, and browse-resp.js does not
# auto-open a single-item feed. So tapping "HQPlayer Bridge" in Apps ALWAYS
# browses into the feed - one tap to a list, a second to anything else.
#
# Material 6.4.6 added a registration API for custom actions, and
# `loadCustomPinned` in browse-page.js turns any action in the "pinned" section
# carrying a `weblink` into a tile on the HOME screen that opens that link
# directly. That is the one-tap route, and this registers it.
#
# TRAP: registerCustomAction PUSHES. There is no unregister and no de-dupe, so
# registering twice puts the tile on Home twice. It runs exactly once per
# server run, from postinitPlugin - never from anywhere re-enterable.
#
# Called through the ->can code ref rather than as a compiled
# Plugins::MaterialSkin::Plugin::registerCustomAction(...), which would bind to
# that glob at OUR compile time. `->can` on a package that was never loaded
# answers undef rather than dying, so no Material means no tile and no error.
sub postinitPlugin {
    my $register = eval { Plugins::MaterialSkin::Plugin->can('registerCustomAction') };

    if ( !$register ) {
        main::INFOLOG && $log->is_info && $log->info(
            'no Material registerCustomAction - no Home tile (the Apps entry still works)' );
        return;
    }

    my $ok = eval {
        # THIS STRING IS THE TILE'S NAME ON THE HOME SCREEN, which is why it
        # names the plugin rather than describing an action - Simon's call.
        # The Apps row uses the same one deliberately: two labels for one
        # destination is how they drift apart.
        # `iframe`, NOT `weblink`, and the difference is the whole behaviour.
        # A pinned tile is dispatched as a CUSTOM ACTION - browse-functions.js
        # `if (item.isPinned) { if (item.custom) { performCustomAction(...) } }`
        # -> doCustomAction, which branches:
        #
        #     if (action.iframe)       bus.$emit('dlg.open', 'iframe', ...)
        #     else if (action.weblink) window.open(...)
        #
        # so `weblink` ALWAYS tears off a separate browser window (there is no
        # relative-vs-absolute test on this path - that test lives in
        # openWebLink, which is the BROWSE-ROW route, not this one) and
        # `iframe` opens it inline as a Material dialog. Simon wanted inline.
        #
        # loadCustomPinned accepts either key, so the Home tile appears either
        # way; only where it opens changes.
        $register->( 'pinned', {
            title  => Slim::Utils::Strings::string('PLUGIN_HQPLAYER_LIVE_TITLE'),
            iframe => Plugins::HQPlayerBridge::Live::PATH(),
            icon   => 'graphic_eq',
        } );
        1;
    };

    $log->warn( "could not register the Material Home tile: $@" ) if !$ok;

    return;
}

sub shutdownPlugin {
    Slim::Control::Request::unsubscribe( \&_onForget );
    Plugins::HQPlayerBridge::Discovery->stop;
    Plugins::HQPlayerBridge::Addresses::reset();
    %splitWarned = ();

    for my $id ( keys %bridges ) {
        _teardown($id);
    }

    return;
}

# Exposed so the tests can stage a registry; the feed and the query read it
# directly.
sub bridges { return \%bridges }

# ---------------------------------------------------------------------------
# The Material/Apps feed.  READ-ONLY, and deliberately shallow: a row that opens
# the live view, then HQPlayer's current settings.
#
# WHY IT EXISTS AT ALL: an Apps entry is the only place a plugin can put itself
# in Material without the user going through the server settings menu. A
# `weblink` item opens the live view in Material's own iframe dialog - the
# pattern LMS-Listen-to-Later and LMS-ListenBrainz-New-Releases both use.
#
# That row is FIRST, because an action row belongs at the top of the section it
# acts on.
#
# Everything below it is `type => 'text'`: these are facts to read, not things
# to open. A non-playable item with no action still gets an `addAction` forced
# onto it by XMLBrowser, which is how a "divider" ends up navigating somewhere
# when tapped - `text` avoids that entirely.
# ---------------------------------------------------------------------------
use constant ICON => 'plugins/HQPlayerBridge/html/images/HQPlayerBridgeIcon.png';
use constant SETTINGS_PATH => '/plugins/HQPlayerBridge/settings/basic.html';

sub topLevel {
    my ( $client, $callback, $args ) = @_;

    # THE LIVE VIEW FIRST. The live reading is not a settings page: the one
    # that existed until 0.2.62 was only a place to read numbers from, and it
    # could not keep them current. (The settings page that came back on
    # 2026-09-27 holds only the typed addresses and the discovery switch.)
    #
    # A BROWSE LIST CANNOT REFRESH ITSELF IN MATERIAL, and that is settled from
    # Material's own source, not inferred: every `refreshList` trigger in
    # browse-page.js is a USER ACTION inside Material (a playlist edit, a
    # favourite change, random mix). No LMS notification is wired to it, so
    # there is no plugin-reachable path to re-render this page. The rows below
    # are therefore a SNAPSHOT taken when the page opened, and always will be.
    #
    # So the live reading lives on a page of its own - see Live.pm - and this
    # row opens it. The manual Refresh row that used to sit here is GONE:
    # Simon asked for a live view, not a button to press.
    my @items = ( {
        name    => cstring( $client, 'PLUGIN_HQPLAYER_LIVE_TITLE' ),
        type    => 'link',
        weblink => Plugins::HQPlayerBridge::Live::PATH(),
        image   => ICON,
    } );

    # THE SETTINGS PAGE, second and ALWAYS present: a fixed row above the
    # Restart block, so it never moves one of those positional rows within a
    # run. A relative weblink opens in Material's own iframe dialog.
    push @items, {
        name    => cstring( $client, 'PLUGIN_HQPLAYER_SETTINGS' ),
        type    => 'link',
        weblink => SETTINGS_PATH,
    } if main::WEBUI;

    # THE RESTART ROWS: ONE BLOCK, RIGHT UNDER THE LIVE VIEW, APPEND-ONLY.
    #
    # An item_id is a row POSITION, and a tap is resolved by walking the feed
    # again from here - both taps of the confirm-then-restart pair. Inside each
    # instance's block, a row moved whenever an EARLIER instance left
    # discovery, and a tap on B's "Restart ... now" then restarted C (simulated
    # 2026-09-21: the page read "Restart HQPlayer B now" and C was restarted).
    #
    # So these rows live in one block above everything that can move, and the
    # block only ever APPENDS: a host that becomes restartable is added at the
    # end, and a bridge that goes away KEEPS its row (tapping it says so). No
    # actionable row can change position within a run; what shifts below it is
    # text, which does nothing when tapped.
    for my $id ( sort keys %bridges ) {
        my $b = $bridges{$id} or next;
        next unless $restartable{ ( $b->{instance} || {} )->{ip} // '' };
        push @restartRows, $id unless exists $restartName{$id};
        $restartName{$id} = $b->{name};
    }
    push @items, map { {
        name        => cstring( $client, 'PLUGIN_HQPLAYER_RESTART', $restartName{$_} ),
        type        => 'link',
        url         => \&_restartConfirm,
        passthrough => [ { id => $_ } ],
    } } @restartRows;

    for my $id ( sort keys %bridges ) {
        my $b = $bridges{$id} or next;

        push @items, { name => $b->{name}, type => 'text' };

        # A host missed at link-up is asked again when the list is drawn, or
        # the row stays hidden until the link next drops - days on a healthy
        # host. hqplayerd and the helper start at login in no fixed order, so
        # the miss is ordinary. Throttled; the row shows on the NEXT open.
        _probeRestart( ( $b->{instance} || {} )->{ip} );

        my $p = signalPathFor( $client, $b );

        # Every row is `text`: these are facts to read. A non-playable item
        # with no action gets an addAction FORCED onto it by XMLBrowser, which
        # is how a feed "divider" ends up navigating when tapped.
        push @items, { name => $p->{connected}, type => 'text' } if $p->{connected};

        # HQPLAYER'S SETTINGS, NOT THE SIGNAL PATH. The signal path moves - the
        # source and output formats change per track and the processing speed
        # changes every second - and this list is a snapshot that can never
        # refresh itself, so showing it here was showing a stale copy of what
        # the live view already does properly. These four are what you would go
        # into HQPlayer to change, so they are still true when the page is a
        # minute old.
        for my $f ( [ mode      => 'PLUGIN_HQPLAYER_MODE' ],
                    [ filter    => 'PLUGIN_HQPLAYER_FILTER' ],
                    [ shaper    => 'PLUGIN_HQPLAYER_SHAPER' ],
                    [ transport => 'PLUGIN_HQPLAYER_OUTPUT' ] ) {
            my ( $key, $label ) = @$f;
            push @items, {
                name => cstring( $client, $label ) . ': ' . $p->{$key},
                type => 'text',
            } if $p->{$key};
        }
    }

    # WHAT IT IS STILL WAITING FOR SAYS SO, rather than leaving the user to
    # wonder whether the plugin is working: waitingText, the SAME words the
    # live page shows, true to the mode - and with typed addresses, even when
    # other players are connected. Last, so it can never move a positional
    # row above it. With no player at all, the diagnostic follows, matching
    # what is actually running (with discovery off no probe was sent at all);
    # with no address typed the waiting row already says what to do.
    #
    # This feed is a snapshot: Material never re-renders a browse list on its
    # own. The live page is the surface that follows the state as it changes.
    my $wait = waitingText($client);

    push @items, { name => $wait, type => 'text' } if length $wait;

    if ( !keys %bridges ) {
        my $auto = Plugins::HQPlayerBridge::Discovery::listening();

        push @items, {
            name => cstring( $client, $auto ? 'PLUGIN_HQPLAYER_NONE_DESC' : 'PLUGIN_HQPLAYER_NONE_DESC_OFF' ),
            type => 'text',
        } if $auto || @{ Plugins::HQPlayerBridge::Addresses::list() };
    }

    $callback->( { items => \@items } );

    return;
}

# ---------------------------------------------------------------------------
# RESTARTING HQPLAYER, through the hqrestart helper (tools/hqrestart/).
#
# WHY: a power-cycled NAA endpoint is often not used again until hqplayerd
# restarts, and nothing on HQPlayer's side can do that remotely. The control
# API has no restart verb, `:8088/restart` is a no-op (measured 2026-09-21),
# and the web UI's Refresh devices drops the saved SDM mode to PCM - a restart
# reloads it. So a small webhook runs on the HQPlayer host and does it.
#
# NO CONFIGURATION, which is still true of this plugin: the helper listens on
# a fixed port of the host discovery already found, `/ping` needs no token, and
# the restart is authorised on the helper's side by this server's address
# (its `allow` list). No helper answering means no row - the ordinary case.
#
# THE RESTART IS A JSON POST, NEVER A GET: the helper only waives the token for
# that. LMS's own image proxy will GET any URL a client hands it, from THIS
# server's address - so a GET-able restart was reachable from any web page on
# the LAN (measured 2026-09-21 against `/status`).
#
# MANUAL ONLY. The bridge never restarts HQPlayer by itself - auto-recovery of
# the NAA was DECLINED 2026-09-21 ("This is for Eversolo to fix").
# ---------------------------------------------------------------------------
use constant RESTART_PORT  => 8090;
use constant REPROBE_AFTER => 60;    # seconds between asks of one still-unknown host

sub restartable { return \%restartable }
sub probedAt    { return \%probedAt }       # for the tests
sub restartRows  { return \@restartRows }    # for the tests
sub restartNames { return \%restartName }

sub _restartUrl { return 'http://' . $_[0] . ':' . RESTART_PORT . $_[1] }

# JSON::PP is loaded at CALL TIME, not with a top-level `use`: it is core Perl
# but not shipped by LMS, and a BEGIN failure on a platform that lacks it would
# take the WHOLE plugin down over the one optional row that reads a reply. A
# miss here costs the Restart row and nothing else.
sub _decode {
    my $body = shift;
    my $r = eval { require JSON::PP; JSON::PP::decode_json( $body // '' ) };
    return ref $r eq 'HASH' ? $r : {};
}

# The clock, as a sub so the tests can move it; `time` is a builtin that a
# glob assignment cannot reach.
sub _now { return time() }

# At every link-up and whenever the Apps list is drawn, while the host is still
# unknown - at most once per REPROBE_AFTER either way. A link-up is throttled
# too: the link retries a refusing instance every 10s (Control::BACKOFF_MAX),
# and an unthrottled probe was a 3s GET to a dead :8090 every ~10s for ever on
# a host with no helper. A host already known is never asked again.
sub _probeRestart {
    my $ip = shift;
    return unless $ip;
    return if $restartable{$ip};
    return if _now() - ( $probedAt{$ip} || 0 ) < REPROBE_AFTER;
    $probedAt{$ip} = _now();

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $r = _decode( eval { $_[0]->content } );
            return unless ( $r->{service} // '' ) eq 'hqrestart';

            $restartable{$ip} = 1;
            main::INFOLOG && $log->is_info && $log->info("restart helper found on $ip");
        },
        sub { },    # nothing listening: no helper installed, the normal case
        { timeout => 3 },
    )->get( _restartUrl( $ip, '/ping' ) );

    return;
}

# The first tap only asks: a restart stops playback, and a browse row is easy
# to hit by accident.
#
# Both taps are resolved by POSITION from topLevel, which is why the rows that
# open this sit in an append-only block that never moves (see topLevel). A
# bridge gone by then gets text at the same position, so nothing to tap.
sub _restartConfirm {
    my ( $client, $callback, $args, $pt ) = @_;

    my $b = $bridges{ ( $pt || {} )->{id} // '' };
    return $callback->( { items => [
        { name => cstring( $client, 'PLUGIN_HQPLAYER_RESTART_GONE' ), type => 'text' },
    ] } ) unless $b;

    $callback->( { items => [
        {
            name        => cstring( $client, 'PLUGIN_HQPLAYER_RESTART_NOW', $b->{name} ),
            type        => 'link',
            url         => \&_restartNow,
            passthrough => [ $pt ],
        },
        { name => cstring( $client, 'PLUGIN_HQPLAYER_RESTART_DESC' ), type => 'text' },
    ] } );

    return;
}

# Answers when HQPlayer is back (the helper waits for the new process, ~7s on
# a Mac), so the page that opens is the outcome. The helper bounds the whole
# restart at 90s (`total_timeout`); this waits longer, or a slow service stop
# would read as a failure that then succeeds. The control link drops and
# comes back on its own backoff - nothing here touches it.
sub _restartNow {
    my ( $client, $callback, $args, $pt ) = @_;

    my $say = sub { $callback->( { items => [ { name => shift, type => 'text' } ] } ) };

    my $b  = $bridges{ ( $pt || {} )->{id} // '' };
    my $ip = $b && ( $b->{instance} || {} )->{ip};
    return $say->( cstring( $client, 'PLUGIN_HQPLAYER_RESTART_GONE' ) ) unless $ip;

    main::INFOLOG && $log->is_info && $log->info("asking the helper on $ip to restart HQPlayer");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $r = _decode( eval { $_[0]->content } );
            return $say->( cstring( $client, 'PLUGIN_HQPLAYER_RESTART_OK', $r->{seconds} // '?' ) )
                if $r->{ok};
            $say->( cstring( $client, 'PLUGIN_HQPLAYER_RESTART_FAIL', $r->{error} // '?' ) );
        },
        sub {
            # A 401 / 409 / 500 lands HERE, with the helper's reason in the body.
            my ( undef, $error, $res ) = @_;
            my $r = _decode( eval { $res->content } );
            $log->warn( "restart on $ip failed: " . ( $r->{error} || $error || '?' ) );
            $say->( cstring( $client, 'PLUGIN_HQPLAYER_RESTART_FAIL', $r->{error} || $error || '?' ) );
        },
        { timeout => 120 },
    )->post( _restartUrl( $ip, '/restart' ), 'Content-Type' => 'application/json', '{}' );

    return;
}

# audio/x-flac -> FLAC.  HQPlayer reports the source container as a MIME type;
# the bare subtype is what a listener recognises.
#
# It lives HERE because BOTH surfaces reach it through signalPathFor - the
# Apps feed and the live view's query - and neither is loaded only under
# main::WEBUI.  (It moved out of the old Settings.pm, which was WEBUI-only,
# for that reason; that page went in 0.2.60-0.2.76.)
sub _shortMime {
    my $mime = shift or return undef;

    $mime =~ s{^audio/}{}i;
    $mime =~ s{^x-}{}i;

    return uc $mime;
}

# WHAT THE BRIDGE IS STILL WAITING FOR - true to the mode, and ONE answer for
# the Apps feed and the live page (whose poll carries it as `waiting`), so the
# two never disagree. '' when it is waiting for nothing: the poll sends that
# too, so the live page drops a line that no longer holds.
#
#   automatically, no player       looking on the network
#   automatically, players         '' - there is no list of HQPlayers to expect
#   addresses only, none typed     nothing to wait for: enter one in Settings
#   addresses only                 every typed address with NO player yet, named
#                                  - even while others are connected (review 6:
#                                  one off at an LMS restart was shown nowhere)
sub waitingText {
    my $client = shift;

    if ( Plugins::HQPlayerBridge::Discovery::listening() ) {
        return keys %bridges ? '' : cstring( $client, 'PLUGIN_HQPLAYER_WAIT_AUTO' );
    }

    my $list = Plugins::HQPlayerBridge::Addresses::list();

    return cstring( $client, 'PLUGIN_HQPLAYER_NONE_DESC_EMPTY' ) if !@$list;

    # In LIST context: _linkStateAt answers ( state, name ) or nothing, and
    # in scalar context a player with no name would read as no player.
    my @waiting = grep { my @at = _linkStateAt($_); !@at } @$list;

    return '' if !@waiting;

    ( my $text = cstring( $client, 'PLUGIN_HQPLAYER_WAIT_ADDR' ) ) =~ s/%s/join( ', ', @waiting )/e;

    return $text;
}

# ---------------------------------------------------------------------------
# The query the live page polls.
#
# `["hqplayerbridge","signalpath"]` answers the SAME display strings the page
# was rendered with, so the poller only has to drop them into the DOM - it
# never parses a formatted row apart, which would break the moment anyone
# translates the strings.
#
# IT COSTS HQPLAYER NOTHING. Every value is already in memory from the
# <Status/> push we subscribe to whether anyone is looking or not; this reads a
# hash. No command goes out on 4321 for a poll.
# ---------------------------------------------------------------------------
sub _signalPathQuery {
    my $request = shift;

    if ( !$request->isQuery( [ ['hqplayerbridge'], ['signalpath'] ] ) ) {
        $request->setStatusBadDispatch();
        return;
    }

    my $client = $request->client;
    my $i      = 0;

    for my $id ( sort keys %bridges ) {
        my $b = $bridges{$id} or next;
        my $p = signalPathFor( $client, $b );

        $request->addResultLoop( 'bridges_loop', $i, 'id', $id );
        $request->addResultLoop( 'bridges_loop', $i, 'name', $b->{name} )
            if defined $b->{name};

        # THE PLAYER ID, because the live page SENDS as well as reads now. A
        # transport or volume command is an ordinary jsonrpc request addressed
        # to a player, and this is the only place the page can learn which
        # player belongs to which bridge - `id` above is the INSTANCE key, not a
        # player id, and they are not interchangeable.
        $request->addResultLoop( 'bridges_loop', $i, 'playerid', $b->{client}->id )
            if $b->{client};

        for my $k (qw( connected up source output filter shaper speed tier )) {
            $request->addResultLoop( 'bridges_loop', $i, $k, $p->{$k} ) if defined $p->{$k};
        }

        # Now playing rides the SAME poll - one round trip, and the page never
        # has to know which player id belongs to which bridge.
        my $np = nowPlayingFor( $b->{client} );

        for my $k (qw( title artist album artwork state position duration
                       volume muted volctl extid )) {
            $request->addResultLoop( 'bridges_loop', $i, "np_$k", $np->{$k} )
                if defined $np->{$k};
        }

        $i++;
    }

    $request->addResult( 'count', $i );
    $request->addResult( 'waiting', waitingText($client) );
    $request->setStatusDone();

    return;
}

# ---------------------------------------------------------------------------
# THE SIGNAL PATH, FORMATTED ONCE.
#
# TWO surfaces show these strings - the Apps feed, and the `signalpath` query
# the live page polls - and they must never disagree about what "Processing"
# reads like. So the formatting lives HERE and each surface renders what it is
# given; neither formats a value of its own.
#
# Returns display strings, already localised, with a key ABSENT rather than
# empty when HQPlayer has not reported it: a caller can then test the key and
# skip the row instead of drawing a label with nothing after it.
# ---------------------------------------------------------------------------
sub signalPathFor {
    my ( $client, $b ) = @_;

    my $c = $b->{client} or return {};

    my %out;

    # Player::connected - the answer Material shows - and nothing else, so no
    # surface can disagree with it.
    my $up = $c->connected ? 1 : 0;

    $out{connected} = cstring( $client,
        $up ? 'PLUGIN_HQPLAYER_CONNECTED' : 'PLUGIN_HQPLAYER_DISCONNECTED' )
        . ' - ' . ( $b->{instance}->{ip} || '?' ) . ':4321';

    # The same fact as a FLAG, for a reader that must not parse the display
    # string: the live page used to test for a '-', which both strings contain.
    $out{up} = $up;

    # SOURCE is off the <metadata/> child; OUTPUT off the <Status/> root. See
    # _onStatus in Player.pm for why they are different elements.
    my $src = _fmtFormat( $c->hqRate, $c->hqBits, _shortMime( $c->hqMime ) );
    my $dst = _fmtFormat( $c->hqPath->{active_rate}, $c->hqPath->{active_bits},
                          $c->hqPath->{active_mode} );

    $out{source} = $src if $src;
    $out{output} = $dst if $dst;

    # DEFINED, NOT TRUE. `process_speed` is "0" whenever HQPlayer is not
    # actively processing, and 0 is false in Perl - so a truthiness guard
    # DELETED the speed from the string rather than reporting it as 0.0x.
    # Measured live: one sample carried no speed at all while samples 2s either
    # side carried 69.2x. The row's content silently depended on transport
    # state, which is exactly the thing a live view must not do.
    my $has = sub {
        my $v = $c->hqPath->{ $_[0] };
        return defined $v && $v ne '';
    };

    # ONE FIELD PER FACT, and the surfaces choose which they draw.
    #
    # These three used to be joined into a single `processing` line as well -
    # "Filter X - Shaper Y - 30.3x realtime" - which meant the label was baked
    # into the VALUE and the live page rendered a sentence it could not lay out.
    # Simon asked for them as three rows, and once each has a row of its own
    # there is nothing left for the joined string to do, so it is gone rather
    # than kept as a second way of saying the same thing.
    #
    # The Apps list draws only the SETTINGS half (mode/filter/shaper): it is a
    # snapshot that can never tick, so a speed that changes every second has no
    # business in it. Same source, same formatter, two audiences.
    $out{mode}   = $c->hqPath->{active_mode}   if $has->('active_mode');
    $out{filter} = $c->hqPath->{active_filter} if $has->('active_filter');
    $out{shaper} = $c->hqPath->{active_shaper} if $has->('active_shaper');

    $out{speed}  = sprintf( '%.1f%s', $c->hqPath->{process_speed},
                            cstring( $client, 'PLUGIN_HQPLAYER_SPEED' ) )
        if $has->('process_speed');

    # The closest thing to "which NAA", and it is only an ID. HQPlayer's control
    # API has no way to NAME a transport, let alone enumerate the available
    # ones: <GetTransport/> answers a single value+arg and there is no
    # TransportItem response at all (verified against Signalyst's own client).
    my $t = $c->hqTransport;
    $out{transport} = cstring( $client, 'PLUGIN_HQPLAYER_TRANSPORT_ID' ) . ' ' . $t
        if defined $t && $t ne '';

    my $tier = $c->hqTier;

    $out{tier} = cstring( $client,
          $tier == 1 ? 'PLUGIN_HQPLAYER_TIER1'
        : $tier == 3 ? 'PLUGIN_HQPLAYER_TIER3'
        : $tier == 5 ? 'PLUGIN_HQPLAYER_TIER5'
        :              'PLUGIN_HQPLAYER_TIER4' ) if $tier;

    return \%out;
}

# ---------------------------------------------------------------------------
# NOW PLAYING, resolved the way LMS-NowPlayingDisplay already does it.
#
# NOT re-derived. That plugin has been through the metadata traps this one
# would hit in the same order, and its ARTWORK ORDER in particular is the part
# nobody would guess right first time:
#
#   1. `artwork_url` - streaming services and remote tracks set this to an LMS
#      imageproxy path (`/imageproxy/<encoded>/image.jpg`), already
#      server-relative and ready for the browser.
#   2. `/music/<coverid>/cover.jpg` for local tracks - but ONLY when the
#      coverid does not start with `-`. LMS gives REMOTE tracks synthetic
#      NEGATIVE ids and the /music/ endpoint 404s on them.
#
# `remoteMeta` is the other half: for a remote track the useful metadata sits
# at the TOP LEVEL of the status response, not in `playlist_loop` - so each
# field falls back to it rather than rendering blank.
# ---------------------------------------------------------------------------
sub nowPlayingFor {
    my $client = shift or return {};

    my %np;

    # songTime is the live position and is not in the status result.
    eval { $np{position} = Slim::Player::Source::songTime($client) || 0 };

    my $req = eval {
        Slim::Control::Request::executeRequest(
            $client, [ 'status', '-', 1, 'tags:aluKcd' ] );
    };

    return \%np unless $req && !$req->isStatusError;

    my $res = $req->getResults || {};

    $np{state} = { play => 'playing', pause => 'paused' }->{ $res->{mode} || '' }
              || 'stopped';

    # VOLUME, AND MUTE THE WAY LMS ACTUALLY REPORTS IT.
    #
    # There is no separate muting field in a status result: LMS stores the level
    # NEGATED while muted, so the sign IS the mute flag and the magnitude is the
    # level to show. That is Material's own rule, read from its source
    # (server.js: `player.muted = ... player.volume<0` then `Math.abs`), and a
    # reader that skips it shows "-69" on a muted player.
    my $vol = $res->{'mixer volume'};

    if ( defined $vol && $vol ne '' ) {
        $np{muted}  = $vol < 0 ? 1 : 0;
        $np{volume} = int( abs($vol) + 0.5 );
    }

    # WHETHER A SLIDER SHOULD EXIST AT ALL. This is the field the skins gate on
    # - Slim::Control::Queries computes it as
    #     use_volume_control = (digitalVolumeControl || !hasDigitalOut) ? 1 : 0
    # - so it already accounts for the user setting this player to fixed volume
    # in LMS's own audio settings, which is the one switch that means "LMS stops
    # driving HQPlayer's volume". Reading it here rather than the pref keeps the
    # page and every other skin agreeing, and costs nothing: it rides the status
    # request this sub already makes. See Player::_volumeIsFixed.
    $np{volctl} = ( exists $res->{use_volume_control} && !$res->{use_volume_control} )
                ? 0 : 1;

    my $loop = $res->{playlist_loop};
    my $t    = ( ref $loop eq 'ARRAY' && @$loop ) ? $loop->[0] : {};
    my $rm   = $res->{remoteMeta} || {};

    $np{title}  = $t->{title}  // $rm->{title}  // '';
    $np{artist} = $t->{artist} // $t->{trackartist} // $t->{albumartist}
               // $rm->{artist} // '';
    $np{album}  = $t->{album}  // $rm->{album}  // '';

    $np{duration} = ( $t->{duration} || $rm->{duration} || 0 ) + 0;

    my $art = $t->{artwork_url} || $rm->{artwork_url};

    if ($art) {
        $np{artwork} = $art;
    }
    else {
        my $cover = $t->{coverid} // $t->{artwork_track_id} // $t->{id}
                 // $rm->{coverid} // $rm->{id};

        # A leading "-" is the synthetic id LMS mints for a remote track;
        # /music/ answers 404 for those, so a cover URL built from one is a
        # broken image rather than a missing one.
        $np{artwork} = "/music/$cover/cover.jpg"
            if defined $cover && $cover ne '' && $cover !~ /^-/;
    }

    # THE SERVICE BADGE'S KEY, FROM THE URL - see _extid. Absent for a local
    # file, a plain radio stream, or any service Material has no emblem for.
    my $extid = _extid( $t->{url} // $rm->{url} );
    $np{extid} = $extid if defined $extid;

    # NOTHING PLAYING DROPS THE TRACK, NOT THE PLAYER.
    #
    # These keys are absent rather than blank, so the page draws no artwork, no
    # title and no progress bar instead of an empty panel - unchanged.
    #
    # What is NOT dropped is the player's own state: `state`, `volume`, `muted`
    # and `volctl` describe the endpoint, not the track, and they are exactly
    # what the transport and volume controls need in order to still work when
    # the queue is stopped. Returning an empty hash here would have left the
    # page with a mute button and no idea whether it was muted.
    delete @np{ qw( title artist album artwork duration position extid ) }
        unless length $np{title};

    return \%np;
}

# ---------------------------------------------------------------------------
# THE SERVICE BADGE, IN THE SHAPE THE OTHER PLUGINS SEND IT.
#
# LMS-Listen-to-Later and LMS-Pitchfork-Reviews put a service logo on a row by
# setting `extid`: Material reads the part before the first ':' and looks it up
# in its own misc/emblems.json. That route is NOT open to this plugin - those
# are XMLBrowser rows that MATERIAL renders, and the live page renders itself
# (see Live.pm) - so the key travels in the same `extid` shape and the page
# draws the badge from it. Sending the same shape is the point: the page can
# then do exactly what Material does with it, and a service Material learns
# about needs no change here beyond a line in the table.
#
# THE KEY COMES FROM THE URL, BECAUSE A STATUS RESULT HAS NO `extid` FOR THE
# PLAYING TRACK. Measured on the rig, not assumed: `status` with `tags:x` adds
# nothing, and a Qobuz track answers `url => 'qobuz://449954371.flac'` and
# nothing else that names the service. Material has the same problem and
# solves it the same way (getTrackSource), so the prefixes below are ITS
# track-sources.json keys mapped to ITS emblems.json keys - they are not
# always the same word (sounds: -> bbc), and an invented one draws nothing.
my %EMBLEM = (
    'qobuz:'         => 'qobuz',
    'tidal:'         => 'tidal',
    'wimp:'          => 'wimp',
    'spotify:'       => 'spotify',
    'spoton:'        => 'spoton',
    'deezer:'        => 'deezer',
    'bandcamp:'      => 'bandcamp',
    'youtube:'       => 'youtube',
    'ytm:'           => 'ytm',
    'pandora:'       => 'pandora',
    'pyrrha:'        => 'pyrrha',
    'radioparadise:' => 'radioparadise',
    'ibcst:'         => 'ibcst',
    'sounds:'        => 'bbc',
);

# MATERIAL'S SECOND TIER: A SUBSTRING, NOT A PREFIX. Its `getTrackSource` tries
# the prefixes above and then an `includes` table, because these two services
# are also reachable as an ORDINARY http(s) stream - a Radio Paradise FLAC
# favourite is `https://stream.radioparadise.com/flacm`, which no prefix
# matches. Without this tier Material badges such a track and this page did
# not, which is exactly the divergence the prefix table exists to avoid.
# `.planetradio.co.uk` is Material's third entry and is deliberately absent:
# it carries no `extid`, so Material draws no badge for it either.
my %EMBLEM_IN = (
    '.radioparadise.com/' => 'radioparadise',
    '.bandcamp.com'       => 'bandcamp',
);

sub _extid {
    my $url = shift;

    return undef unless defined $url && length $url;

    my $lc = lc $url;

    for my $pfx ( keys %EMBLEM ) {
        return $EMBLEM{$pfx} . ':' if index( $lc, $pfx ) == 0;
    }

    # ONLY AFTER the prefixes, which is Material's own order.
    for my $frag ( keys %EMBLEM_IN ) {
        return $EMBLEM_IN{$frag} . ':' if index( $lc, $frag ) >= 0;
    }

    return undef;
}

sub _fmtFormat {
    my ( $rate, $bits, $extra ) = @_;

    return undef unless $rate;

    my $s = "$rate Hz";
    $s .= " / $bits bit" if $bits;
    $s .= " $extra"      if defined $extra && length $extra;

    return $s;
}

# ---------------------------------------------------------------------------
# Reconcile the discovered instance list against the players we have made
# ---------------------------------------------------------------------------
# $partial is set when discovery is announcing a reply mid-round, before the
# rest of the instances have had their chance to answer.  Such a list is
# additive only: see the removal pass at the end.
sub _onInstances {
    my ( $instances, $partial ) = @_;

    $instances ||= [];

    my %seen;

    my $ids = _idsFor( $instances, $partial, \%bridges );

    for my $inst (@$instances) {
        # NO ENTRY MEANS DELIBERATELY NOT ACTED ON, and it is not an error.
        # _idsFor drops an address that has stopped answering when EXACTLY ONE
        # address still answers to the same name and that name is not already
        # split into address-qualified players (it is then the same daemon,
        # seen at the address a DHCP move left), and it defers a whole name
        # group on a PARTIAL list
        # because freshness cannot be judged until the round is complete.
        # Either way the address gets no player this round; a deferred group is
        # resolved by the complete round ~LISTEN_TIME later, and a dropped
        # corpse is torn down by the removal pass below because nothing marks
        # its id seen.
        my $entry = $ids->{ $inst->{ip} } or next;

        my $id   = $entry->{id};
        my $name = $entry->{name};

        $seen{$id} = 1;

        # One bad instance must not abort the whole round - this ran inside a
        # timer callback, so an exception here used to surface only as
        # "Timer ... _roundDone failed" with the real cause swallowed.
        local $@;

        eval {

        if ( my $b = $bridges{$id} ) {
            # Follow the instance if DHCP moved it.
            if ( $b->{instance}->{ip} ne $inst->{ip} ) {
                $log->info("$inst->{name}: address changed $b->{instance}->{ip} -> $inst->{ip}, reconnecting");
                _teardown($id);
                _create( $id, $inst, $name );
            }
            else {
                # Nothing to poke: a down link reconnects on its own ladder
                # (Control::BACKOFF_MAX), whatever discovery hears.
                $b->{instance} = $inst;
            }
        }
        else {
            _create( $id, $inst, $name );
        }

        1 } or do {
            my $err = $@ || 'unknown error';
            $log->error("failed to set up '$inst->{name}' at $inst->{ip}: $err");
            _teardown($id);
        };
    }

    # Anything that has stopped answering goes away - but only when this was a
    # complete round.  A partial list says nothing about who is absent.
    return if $partial;

    for my $id ( keys %bridges ) {
        next if $seen{$id};

        # Lyrion forgets only a DISCONNECTED player, and so does this: a live
        # control link outranks discovery going quiet (see INSTANCE_TTL). A
        # dead peer loses its link to the status watchdog within ~40s, and is
        # removed at the first complete round after that.
        #
        # NOT when its address went to ANOTHER id this round: that is the same
        # daemon re-keyed (a pair shrinking to one takes the plain id), and
        # keeping the old player too would leave two players, and two control
        # links, on one HQPlayer.
        my $b  = $bridges{$id};
        my $ip = ( $b->{instance} || {} )->{ip};
        # Player::connected, the answer Material shows.
        next if $b->{client} && $b->{client}->connected && !( defined $ip && $ids->{$ip} );

        $log->info( ( $bridges{$id}->{instance}->{name} || $id ) . ': no longer answering, removing player' );
        _teardown($id);
    }

    return;
}

# A stable synthetic MAC.  The 0x02 prefix marks it locally administered, so it
# can never collide with real Squeezebox hardware.
sub _idFor {
    my $key = shift;

    my @o = unpack( '(A2)5', substr( md5_hex($key), 0, 10 ) );

    return lc( '02:' . join( ':', @o ) );
}

# The player's display name.  Two instances answering to the same product name
# are told apart by address here too - otherwise LMS shows two identical
# players and there is no way to know which is which.
sub _nameFor {
    my ( $inst, $duplicated ) = @_;

    my $name = $inst->{name} && $inst->{name} ne 'HQPlayer'
             ? "HQPlayer ($inst->{name})"
             : 'HQPlayer';

    $name .= " $inst->{ip}" if $duplicated;

    return $name;
}

# Which members of a name group are STILL ANSWERING: the ones that answered
# the same discovery ROUND as the newest reply. Anything from an earlier round
# is an address the daemon has left.
#
# It used to be judged by the clock - replies within ADDR_SLACK (10s) of the
# newest counted as the same round. That only worked while rounds were MORE
# than 10s apart; when discovery moved to rounds 5-15s apart, an address
# left one round ago would have looked fresh, and a DHCP move would have split
# one daemon into two players again - the 1.0.8 bug. Counting rounds says what
# was meant directly, and does not care how far apart they are.
#
# NO ROUND AT ALL means every member counts as live.  That is the case the
# suite's fixtures build, and it is the conservative answer: it keeps two
# genuinely separate instances apart rather than silently merging them.
sub _liveOf {
    my $group = shift;

    my ($newest) = sort { $b <=> $a }
                   grep { defined }
                   map  { $_->{round} } @$group;

    return [@$group] unless defined $newest;

    my @live = grep { !defined $_->{round}
                      || $_->{round} == $newest } @$group;

    # Belt and braces: never hand back an empty group.
    return @live ? \@live : [@$group];
}

# True when any member of a name group already holds an ADDRESS-QUALIFIED
# player - i.e. the name is an established pair, not one daemon that has moved.
# No $existing (the suite's direct calls) means nothing is running yet.
sub _isSplit {
    my ( $name, $group, $existing ) = @_;

    return 0 unless $existing;

    for my $inst (@$group) {
        return 1 if exists $existing->{ _idFor( $name . '@' . $inst->{ip} ) };
    }

    return 0;
}

# Player id for every discovered instance, keyed by ip.
#
# The id is derived from the instance NAME rather than its address, so that a
# DHCP move does not orphan the player's prefs, playlist and sync group - the
# address-changed branch above follows the instance instead.
#
# TRAP: the discovery name is a PRODUCT string, not an identity.  Every
# HQPlayer Embedded instance answers "HQPlayerEmbedded", so on the name alone
# two instances are one player: each discovery round would see the id it
# already has arrive with the other one's address, tear the player down and
# build it again a round later, killing playback every time.  (A DHCP move
# is the same shape - the old address lingers in the discovery table for
# INSTANCE_TTL, so for that window the instance appears twice under one name.)
#
# So a name that more than one live instance answers to is not usable on its
# own, and those instances are told apart by address.  A name only one instance
# answers to - the ordinary case, and the only one where the prefs actually
# matter - keeps the plain name-derived id and its DHCP immunity.
#
# LIVE IS THE WHOLE WORD, AND IT USED TO GO UNENFORCED.  REPRODUCED on the rig
# 2026-09-20: the Mac running hqplayerd was moved from Wi-Fi (.109) onto
# Ethernet (.238) with the daemon left running.  hqplayerd answers the
# multicast probe from ONE address only - whichever the routing table picks -
# so .238 arrived while .109 was still sitting in %found inside INSTANCE_TTL,
# and one live address plus one corpse counted as two instances:
#
#   discovery: found 'HQPlayerEmbedded' at 192.168.1.238
#   2 instances answer to 'HQPlayerEmbedded' (192.168.1.109, 192.168.1.238)
#     - identifying them by address instead
#   HQPlayerEmbedded: no longer answering, removing player
#
# The plain-id player was torn down and replaced by TWO address-qualified ones,
# taking the user's settings with it - they live under the id.  So the count
# that decides this is of instances STILL ANSWERING, never of rows in the table.
#
# THE CASE THIS FIXES IS A DHCP MOVE, which is the one `_idFor`'s comment above
# already promises immunity from: the lease moves, nothing is left at the old
# address, the corpse stops answering and the group collapses back to one.
#
# IT DELIBERATELY DOES NOT MERGE TWO ADDRESSES THAT ARE BOTH ANSWERING, and an
# interface move is exactly that once the daemon is healthy.  MEASURED the same
# day: hqplayerd answers the MULTICAST probe from one address only, but answers
# a UNICAST probe on EVERY address it holds.  While `_probe` unicast to every
# address in %found (until 2026-09-27) a remembered address refreshed its own
# lastSeen for ever and that split was PERMANENT; with multicast only, the
# unused address now ages out after INSTANCE_TTL and the pair collapses to the
# plain id (docs/discovery-simplification-plan.md section 5).  Running HQPlayer on more than one
# active interface is DECLINED as scope (Simon, 2026-09-20; the vendor
# documents single-interface operation), so collapsing it is not this gate's
# job - and merging on the name alone would take two REAL instances with it.
# See CLAUDE.md, `more than one interface active is DECLINED`.
sub _idsFor {
    my ( $instances, $partial, $existing ) = @_;

    $instances ||= [];

    my %byName;

    for my $inst (@$instances) {
        push @{ $byName{ $inst->{name} || $inst->{ip} } }, $inst;
    }

    my %id;

    for my $name ( keys %byName ) {
        my $group = $byName{$name};

        if ( @$group == 1 ) {
            delete $splitWarned{$name};
            my $inst = $group->[0];
            $id{ $inst->{ip} } = {
                id   => _idFor($name),
                name => _nameFor( $inst, 0 ),
            };
            next;
        }

        # A PARTIAL list is mid-round: the instances that have not answered
        # YET still carry the previous round's number, so every one of them
        # would read as stale and a genuinely second instance would be demoted
        # to a corpse.  Defer the whole group - the complete round decides it
        # ~LISTEN_TIME later, and until then nothing is touched.
        next if $partial;

        my $live = _liveOf($group);

        # One address still answering, the rest are the same daemon at
        # addresses it has left.  Keep the plain name-derived id - that is what
        # the player's prefs, playlist and sync group hang off - and leave the
        # corpses without one.
        #
        # BUT ONLY WHEN THE NAME IS NOT ALREADY AN ESTABLISHED PAIR.  Missing a
        # round cannot tell "the same daemon at an address it has left" from "a
        # SECOND daemon that is briefly quiet" - hqplayerd restarts on any
        # configuration change and misses a round or more while it does.
        # Collapsing that re-keyed the instance that did NOT restart onto the
        # plain id mid-playback, tore down BOTH address-qualified players, and
        # flipped it back on the next round (found in review 2026-09-21).
        # What separates the two cases is what is already running: a DHCP move
        # leaves the PLAIN-id player in place, an established pair already
        # holds ADDRESS-QUALIFIED ones.  A pair keeps today's behaviour, and
        # its quiet member sits out INSTANCE_TTL's grace untouched.
        if ( @$live == 1 && !_isSplit( $name, $group, $existing ) ) {
            delete $splitWarned{$name};
            my $inst = $live->[0];

            main::INFOLOG && $log->is_info && $log->info(
                "'$name' is in the discovery table at "
              . join( ', ', map { $_->{ip} } @$group )
              . " but only $inst->{ip} is still answering - keeping the plain id" );

            $id{ $inst->{ip} } = {
                id   => _idFor($name),
                name => _nameFor( $inst, 0 ),
            };

            next;
        }

        # Said once per CHANGE, not once per round: discovery runs every
        # 10-15s, and a same-named pair is a steady state - HQPlayer Embedded
        # names every instance "HQPlayerEmbedded" - so saying it each round
        # would fill the log for as long as both are up.
        my $addrs = join( ', ', sort map { $_->{ip} } @$group );
        if ( ( $splitWarned{$name} // '' ) ne $addrs ) {
            $splitWarned{$name} = $addrs;
            $log->warn( scalar(@$group) . " instances answer to '$name' ($addrs)"
                . ' - identifying them by address instead' );
        }

        for my $inst (@$group) {
            $id{ $inst->{ip} } = {
                id   => _idFor( $name . '@' . $inst->{ip} ),
                name => _nameFor( $inst, 1 ),
            };
        }
    }

    # A name that has left the table altogether - both of a pair switched
    # off, say - is no longer a pair, so its warning is owed again if it comes
    # back. Only on a COMPLETE list: a partial one holds only the instances
    # that have answered so far.
    if ( !$partial ) {
        for my $name ( keys %splitWarned ) {
            delete $splitWarned{$name} unless $byName{$name};
        }
    }

    return \%id;
}

sub _create {
    my ( $id, $inst, $name ) = @_;

    $name ||= _nameFor( $inst, 0 );

    main::INFOLOG && $log->is_info && $log->info("creating player '$name' [$id] for $inst->{ip}");

    # Built into a scalar first so the packing is unambiguous - see the note on
    # the Socket import above.
    my $paddr = pack_sockaddr_in( 0, INADDR_LOOPBACK );

    my $client = eval {
        Plugins::HQPlayerBridge::Player->new(
            $id,        # client id / MAC
            $paddr,     # peer address - never used, but the constructor wants one
            1.0,        # revision
            undef,      # no socket: this player has none
            12,         # deviceid
            undef,      # uuid
        );
    };

    if ( !$client ) {
        $log->error( "could not create player for $inst->{ip}: " . ( $@ || 'new() returned nothing' ) );
        return;
    }

    $client->macaddress($id);

    # A literal 1, never a socket. It no longer decides `connected` - that is
    # the proven control link, see Player::connected. Kept because every
    # release has set it and code outside LMS may test it; in LMS core
    # (public/9.1) only the Squeezebox classes, Slimproto, Display::Graphics
    # (not this player's NoDisplay), NetTest and Client::forgetClient read it -
    # and forgetClient is why Player::forgetClient clears it first.
    $client->tcpsock(1);

    $client->display( Slim::Display::NoDisplay->new($client) );

    eval { $client->init };
    if ($@) {
        $log->error("player init failed for $name: $@");
        eval { $client->forgetClient };
        return;
    }

    # Named after init, because init runs initPrefs - setting the playername
    # pref before the client's prefs exist risks it being reset by the defaults.
    eval { $client->name($name) };
    $log->warn("could not set player name for $id: $@") if $@;

    # Also after init, for the same reason: the client's prefs have to exist
    # before we can tell an unset bitrate cap from a chosen one.  Without this
    # LMS transcodes every streamed track to MP3 320 - see initBitrateLimit.
    eval { $client->initBitrateLimit };
    $log->warn("could not set the bitrate limit for $id: $@") if $@;

    my $ctl = Plugins::HQPlayerBridge::Control->new(
        ip      => $inst->{ip},
        name    => $name,
        onState => sub {
            my ( $c, $up, $wasProven ) = @_;
            _onLinkState( $id, $up, $wasProven );
        },
        onProven => sub { _onLinkProven($id) },
        # Every Status message - the one we asked for and the ~1/s HQPlayer
        # pushes afterwards - drives the player's state machine.
        onStatus => sub {
            my ( $attrs, $raw ) = @_;
            $client->_onStatus( $attrs, $raw );
        },
    );

    $client->hqControl($ctl);
    $client->hqInstance($inst);

    $bridges{$id} = {
        instance => $inst,
        control  => $ctl,
        client   => $client,
        name     => $name,
    };

    # `client new` WAS ALREADY SENT - by LMS's own Slim::Player::Client::new,
    # which every constructor reaches. The player reads disconnected until
    # HQPlayer replies (Player::connected is `proven`), so say so now: this
    # also takes back what `new` set up for a player that may never answer
    # (UPnP's MediaRenderer registers on `new` and unregisters on
    # `disconnect`). Every proof after this is a `client reconnect`.
    $client->disconnected(1);
    Slim::Control::Request::notifyFromArray( $client, [ 'client', 'disconnect' ] );

    $ctl->connect;

    return;
}

sub _onLinkState {
    my ( $id, $up, $wasProven ) = @_;

    my $b = $bridges{$id} or return;

    my $client = $b->{client} or return;

    if ($up) {
        # The TCP accept only. Nothing LMS-facing happens here: hqplayerd also
        # accepts when it is about to drop the socket, so the player is not
        # reported connected until HQPlayer REPLIES - see _onLinkProven.
        $client->refreshInfo;

        # The status subscription is armed HERE, not at a track load.  It is
        # the plugin's only liveness signal for a peer that goes quiet without
        # closing the socket - see _statusWatchdog in Player.pm.
        $client->_startPolling;

        # Throttled like every other call (see _probeRestart): the link retries
        # a refusing instance every BACKOFF_MAX (10s), and every accept
        # reaches this branch.
        _probeRestart( ( $b->{instance} || {} )->{ip} );
    }
    else {
        $client->_stopPolling;

        # Only a link LMS was told about: an accept-then-drop never was, and
        # must announce nothing - and was never made active, so it has no
        # group to leave.
        #
        # THEN LEAVE THE GROUP, exactly as Slimproto's close does: playerInactive
        # unless this is the only active player. Left in, a synced member with a
        # dead link is still handed every track, fails to open it, and LMS fails
        # that track for the WHOLE group - every other room skipping through the
        # playlist. Out of it, the others play on; `_onLinkProven`'s playerActive
        # brings it back at the group's position (_JumpToTime restarts the
        # group, as a Lyrion player rejoining does). A solo player is left
        # active, Slimproto's rule, so a restart never stops a lone player here.
        #
        # playerInactive's _stopClient reaches Player::stop, whose <Stop/> is
        # failed quietly on the dead link (Control::send) - no reconnect, nothing
        # queued. Control::_dropLink calls this BEFORE it fails the load that
        # was in flight, so stop()'s new generation retires that load instead of
        # letting it report a failure against the group.
        if ($wasProven) {
            $client->disconnected(1);
            Slim::Control::Request::notifyFromArray( $client, [ 'client', 'disconnect' ] );

            # Look NOW: if HQPlayer moved (DHCP), this is how the new address
            # is heard without waiting for the next round. One probe however
            # many links drop, and none with automatic discovery off. Only a
            # PROVEN link - an accept-then-drop every 10s must not become a
            # probe every 10s.
            Plugins::HQPlayerBridge::Discovery->probeNow;

            my $controller = eval { $client->controller };
            if ( $controller && !$controller->onlyActivePlayer($client) ) {
                eval { $controller->playerInactive($client); 1 }
                    or $log->error( ( $b->{name} || $id ) . ": could not leave the sync group: $@" );
            }
        }
    }

    return;
}

# HQPlayer's FIRST REPLY on a link: the player is now connected as far as LMS
# is concerned (Player::connected reads the same flag). Always `client
# reconnect` - the constructor sent `new`, and _create marked the player
# disconnected straight after. Lyrion's Squeezebox::reconnect: a powered player
# rejoins its sync group's active set - after a drop took it out (_onLinkState),
# and at the first link too, since Client::startup's restoreSync ran while it
# read as disconnected. A solo player is already active and LMS returns at its
# "already active" guard. Forgetting is
# unchanged: Lyrion's 300s, via discovery (INSTANCE_TTL).
sub _onLinkProven {
    my $id = shift;

    my $b = $bridges{$id} or return;

    my $client = $b->{client} or return;

    # The flag and the announcement FIRST, so nothing below can lose them:
    # without the notification Material never re-lists the player.
    $client->disconnected(0);
    Slim::Control::Request::notifyFromArray( $client, [ 'client', 'reconnect' ] );

    # playerActive can run the whole _JumpToTime -> play() path when the group
    # is playing; a failure there is logged, not allowed to unwind the proof.
    my $controller = eval { $client->controller };
    if ( $controller && $client->power ) {
        eval { $controller->playerActive($client); 1 }
            or $log->error( ( $b->{name} || $id ) . ": could not rejoin the sync group: $@" );
    }

    return;
}

sub _teardown {
    my $id = shift;

    my $b = delete $bridges{$id} or return;

    if ( my $ctl = $b->{control} ) {
        $ctl->close;
        # These closures capture the client; clearing them lets a forgotten
        # player actually go away.
        delete $ctl->{onStatus};
        delete $ctl->{onState};
        delete $ctl->{onProven};
    }

    if ( my $client = $b->{client} ) {
        eval {
            $client->_stopPolling;

            # ONLY A CONTROLLER THIS PLAYER HAS TO ITSELF.  controller->stop is
            # StreamingController::_Stop, which stops EVERY player in a sync
            # group.  Sample-accurate sync is not offered, but a bridge player
            # joins and leaves a group as a Lyrion player does (CLAUDE.md,
            # `A PLAYER JOINS AND LEAVES A GROUP AS LYRION'S DO`), and removing
            # it must not silence another room: forgetClient below runs LMS's
            # own unsync first, which stops just
            # the one it removes and hands it a controller of its own - the
            # same path `client forget` takes.  A solo player is stopped here
            # exactly as before.
            my $ctl = $client->controller;
            $ctl->stop if $ctl && !( $ctl->can('allPlayers') && $ctl->allPlayers > 1 );
        };
        eval { $client->forgetClient };
    }

    return;
}

1;
