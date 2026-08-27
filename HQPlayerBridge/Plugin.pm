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
# No configuration.  Instances are found by multicast; the settings page is
# read-only status.

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Digest::MD5 qw(md5_hex);
# pack_sockaddr_in, NOT sockaddr_in: the latter switches on wantarray, so in a
# function-call argument list it is in LIST context, reads its two arguments as
# a request to UNPACK one, and croaks
# "usage: (port,iaddr) = sockaddr_in(sin_sv)".
use Socket qw(pack_sockaddr_in INADDR_LOOPBACK);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Control::Request;
use Slim::Display::NoDisplay;

use Plugins::HQPlayerBridge::Control;
use Plugins::HQPlayerBridge::Discovery;
use Plugins::HQPlayerBridge::Player;
use Plugins::HQPlayerBridge::UPnP;

use constant PLUGIN_VERSION => '0.2.3';

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.hqplayerbridge',
    'defaultLevel' => 'INFO',
    'description'  => 'PLUGIN_HQPLAYER_BRIDGE',
});

# id => { instance => {...}, control => $ctl, client => $client }
my %bridges;

sub getDisplayName { 'PLUGIN_HQPLAYER_BRIDGE' }

sub initPlugin {
    my $class = shift;

    $class->SUPER::initPlugin(@_);

    main::INFOLOG && $log->is_info && $log->info( 'HQPlayer Bridge v' . PLUGIN_VERSION . ' starting' );

    if (main::WEBUI) {
        require Plugins::HQPlayerBridge::Settings;
        Plugins::HQPlayerBridge::Settings->new;
    }

    Plugins::HQPlayerBridge::Discovery->start( \&_onInstances );

    return;
}

sub shutdownPlugin {
    Plugins::HQPlayerBridge::Discovery->stop;

    for my $id ( keys %bridges ) {
        _teardown($id);
    }

    return;
}

# Exposed to the settings page.
sub bridges { return \%bridges }
sub version { PLUGIN_VERSION }

# ---------------------------------------------------------------------------
# Reconcile the discovered instance list against the players we have made
# ---------------------------------------------------------------------------
sub _onInstances {
    my $instances = shift || [];

    my %seen;

    for my $inst (@$instances) {
        my $id = _idFor($inst);
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
                _create( $id, $inst );
            }
            else {
                $b->{instance} = $inst;
            }
        }
        else {
            _create( $id, $inst );
        }

        1 } or do {
            my $err = $@ || 'unknown error';
            $log->error("failed to set up '$inst->{name}' at $inst->{ip}: $err");
            _teardown($id);
        };
    }

    # Anything that has stopped answering goes away.
    for my $id ( keys %bridges ) {
        next if $seen{$id};
        $log->info( ( $bridges{$id}->{instance}->{name} || $id ) . ': no longer answering, removing player' );
        _teardown($id);
    }

    return;
}

# A stable synthetic MAC, derived from the instance name rather than its
# address so that a DHCP move does not orphan the player's prefs, playlist
# and sync group.  The 0x02 prefix marks it locally administered, so it can
# never collide with real Squeezebox hardware.
sub _idFor {
    my $inst = shift;

    my $key = $inst->{name} || $inst->{ip};
    my @o   = unpack( '(A2)5', substr( md5_hex($key), 0, 10 ) );

    return lc( '02:' . join( ':', @o ) );
}

sub _create {
    my ( $id, $inst ) = @_;

    my $name = $inst->{name} && $inst->{name} ne 'HQPlayer'
             ? "HQPlayer ($inst->{name})"
             : 'HQPlayer';

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

    # A literal 1, never a socket: this is what lets the rest of LMS treat the
    # player as connected without there being a SlimProto link to speak to.
    $client->tcpsock(1);

    $client->display( Slim::Display::NoDisplay->new($client) );

    eval { $client->init };
    if ($@) {
        $log->error("player init failed for $name: $@");
        eval { Slim::Player::Client::forgetClient($client) };
        return;
    }

    # Named after init, because init runs initPrefs - setting the playername
    # pref before the client's prefs exist risks it being reset by the defaults.
    eval { $client->name($name) };
    $log->warn("could not set player name for $id: $@") if $@;

    my $ctl = Plugins::HQPlayerBridge::Control->new(
        ip      => $inst->{ip},
        name    => $name,
        onState => sub {
            my ( $c, $up ) = @_;
            _onLinkState( $id, $up );
        },
        # Every Status message - the one we asked for and the ~1/s HQPlayer
        # pushes afterwards - drives the player's state machine.
        onStatus => sub {
            my ( $attrs, $raw ) = @_;
            $client->_onStatus( $attrs, $raw );
        },
    );

    # The UPnP renderer runs alongside the XML control link: it is the only
    # channel that carries metadata and artwork to HQPlayer, and the only one
    # that can set the volume.  See UPnP.pm for why both are needed.
    my $upnp = Plugins::HQPlayerBridge::UPnP->new(
        ip   => $inst->{ip},
        name => $name,
    );

    $client->hqControl($ctl);
    $client->hqUPnP($upnp);
    $client->hqInstance($inst);

    $upnp->describe;

    $bridges{$id} = {
        instance => $inst,
        control  => $ctl,
        client   => $client,
        name     => $name,
    };

    $ctl->connect;

    Slim::Control::Request::notifyFromArray( $client, [ 'client', 'new' ] );

    return;
}

sub _onLinkState {
    my ( $id, $up ) = @_;

    my $b = $bridges{$id} or return;

    if ($up) {
        my $client = $b->{client} or return;

        $client->refreshInfo;

        # Re-read the renderer description if it was not reachable earlier.
        my $upnp = $client->hqUPnP;
        $upnp->describe if $upnp && !$upnp->ready;
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
    }

    if ( my $client = $b->{client} ) {
        eval {
            $client->_stopPolling;
            $client->controller->stop if $client->controller;
        };
        eval { Slim::Player::Client::forgetClient($client) };
    }

    return;
}

1;
