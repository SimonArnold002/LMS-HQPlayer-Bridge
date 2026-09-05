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

# OPMLBased, not Base, for ONE reason: it is what registers a top-level app
# entry, and that entry is the only way to reach this plugin's settings from
# Material without going through the server settings menu.  The feed it serves
# is the settings shortcut plus read-only status - see topLevel.
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
use Slim::Control::Request;
use Slim::Display::NoDisplay;
use Slim::Utils::Strings qw(cstring);

use Plugins::HQPlayerBridge::Control;
use Plugins::HQPlayerBridge::Discovery;
use Plugins::HQPlayerBridge::Player;
use Plugins::HQPlayerBridge::Stream;

# The version is READ from install.xml, never restated here.  A second copy is
# a copy that goes stale: this was a hand-maintained constant sitting at 0.2.3
# while install.xml and repo.xml were at 0.2.7, so the startup log and the
# settings page both reported a build that had not been running for months.
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

# id => { instance => {...}, control => $ctl, client => $client }
my %bridges;

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

    if (main::WEBUI) {
        require Plugins::HQPlayerBridge::Settings;
        Plugins::HQPlayerBridge::Settings->new;
    }

    # The tier 4 audio endpoint.  Registered before discovery so that a player
    # created by the very first probe reply already has somewhere to point.
    Plugins::HQPlayerBridge::Stream->init;

    # The settings page polls this. Registered here rather than in Settings.pm
    # because Settings.pm is only required under main::WEBUI.
    Slim::Control::Request::addDispatch(
        [ 'hqplayerbridge', 'signalpath' ], [ 0, 1, 0, \&_signalPathQuery ] );

    Plugins::HQPlayerBridge::Discovery->start( \&_onInstances, \&_linkUpFor );

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

# ---------------------------------------------------------------------------
# The Material/Apps feed.  READ-ONLY, and deliberately shallow: one settings
# shortcut and the same status the settings page shows.
#
# WHY IT EXISTS AT ALL: the settings page is otherwise reachable only through
# LMS's server settings menu, which is several taps deep in Material. A
# `weblink` item opens that page in Material's own iframe dialog - the pattern
# LMS-Listen-to-Later and LMS-ListenBrainz-New-Releases both use.
#
# The settings row is FIRST, because an action row belongs at the top of the
# section it acts on.
#
# Everything below it is `type => 'text'`: these are facts to read, not things
# to open. A non-playable item with no action still gets an `addAction` forced
# onto it by XMLBrowser, which is how a "divider" ends up navigating somewhere
# when tapped - `text` avoids that entirely.
# ---------------------------------------------------------------------------
use constant ICON_SETTINGS => 'plugins/HQPlayerBridge/html/images/HQPlayerBridgeIcon.png';

sub topLevel {
    my ( $client, $callback, $args ) = @_;

    my @items = ( {
        name    => cstring( $client, 'PLUGIN_HQPLAYER_SETTINGS' ),
        type    => 'link',
        weblink => '/plugins/HQPlayerBridge/settings/basic.html',
        image   => ICON_SETTINGS,
    } );

    # A browse page is a SNAPSHOT. Material renders it once and never polls,
    # so the numbers below freeze at whatever they were when the page opened -
    # the feed itself is live and uncached (verified: two calls 3s apart
    # returned 33.3x then 30.8x). This is the standard LMS idiom for that:
    # an EMPTY response plus `nextWindow => 'refresh'` re-renders THIS page
    # inline, which re-runs topLevel and picks up current values.
    #
    # It sits under Settings and above the status it acts on - an action row
    # belongs at the top of its section.
    push @items, {
        name        => cstring( $client, 'PLUGIN_HQPLAYER_REFRESH' ),
        type        => 'link',
        nextWindow  => 'refresh',
        passthrough => [ {} ],
        url         => sub {
            my ( $c, $cb ) = @_;
            $cb->( { items => [] } );
        },
    } if %bridges;

    for my $id ( sort keys %bridges ) {
        my $b = $bridges{$id} or next;

        push @items, { name => $b->{name}, type => 'text' };

        my $p = signalPathFor( $client, $b );

        # Every row is `text`: these are facts to read. A non-playable item
        # with no action gets an addAction FORCED onto it by XMLBrowser, which
        # is how a feed "divider" ends up navigating when tapped.
        push @items, { name => $p->{connected}, type => 'text' } if $p->{connected};

        for my $f ( [ source => 'PLUGIN_HQPLAYER_SOURCE' ],
                    [ output => 'PLUGIN_HQPLAYER_OUTFORMAT' ],
                    [ processing => 'PLUGIN_HQPLAYER_PROCESSING' ] ) {
            my ( $key, $label ) = @$f;
            push @items, {
                name => cstring( $client, $label ) . ': ' . $p->{$key},
                type => 'text',
            } if $p->{$key};
        }
    }

    $callback->( { items => \@items } );

    return;
}

# audio/x-flac -> FLAC.  HQPlayer reports the source container as a MIME type;
# the bare subtype is what a listener recognises.
#
# It lives HERE, not in Settings.pm, because BOTH surfaces need it and
# Settings.pm is only required under main::WEBUI - calling it from the feed
# would die on a headless build.
sub _shortMime {
    my $mime = shift or return undef;

    $mime =~ s{^audio/}{}i;
    $mime =~ s{^x-}{}i;

    return uc $mime;
}

# ---------------------------------------------------------------------------
# The query the settings page polls.
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

        for my $k (qw( connected source output processing tier )) {
            $request->addResultLoop( 'bridges_loop', $i, $k, $p->{$k} ) if defined $p->{$k};
        }

        $i++;
    }

    $request->addResult( 'count', $i );
    $request->setStatusDone();

    return;
}

# ---------------------------------------------------------------------------
# THE SIGNAL PATH, FORMATTED ONCE.
#
# THREE surfaces show these strings - the Apps feed, the settings page, and the
# `signalpath` query the settings page polls - and they must never disagree
# about what "Processing" reads like. So the formatting lives HERE and each
# surface renders what it is given. The template does no formatting at all.
#
# Returns display strings, already localised, with a key ABSENT rather than
# empty when HQPlayer has not reported it: a caller can then test the key and
# skip the row instead of drawing a label with nothing after it.
# ---------------------------------------------------------------------------
sub signalPathFor {
    my ( $client, $b ) = @_;

    my $c = $b->{client} or return {};

    my %out;

    $out{connected} = cstring( $client,
        ( $b->{control} && $b->{control}->connected )
            ? 'PLUGIN_HQPLAYER_CONNECTED' : 'PLUGIN_HQPLAYER_DISCONNECTED' )
        . ' - ' . ( $b->{instance}->{ip} || '?' ) . ':4321';

    # SOURCE is off the <metadata/> child; OUTPUT off the <Status/> root. See
    # _onStatus in Player.pm for why they are different elements.
    my $src = _fmtFormat( $c->hqRate, $c->hqBits, _shortMime( $c->hqMime ) );
    my $dst = _fmtFormat( $c->hqPath->{active_rate}, $c->hqPath->{active_bits},
                          $c->hqPath->{active_mode} );

    $out{source} = $src if $src;
    $out{output} = $dst if $dst;

    my @proc;
    push @proc, cstring( $client, 'PLUGIN_HQPLAYER_FILTER' ) . ' ' . $c->hqPath->{active_filter}
        if $c->hqPath->{active_filter};
    push @proc, cstring( $client, 'PLUGIN_HQPLAYER_SHAPER' ) . ' ' . $c->hqPath->{active_shaper}
        if $c->hqPath->{active_shaper};
    push @proc, sprintf( '%.1f%s', $c->hqPath->{process_speed},
                         cstring( $client, 'PLUGIN_HQPLAYER_SPEED' ) )
        if $c->hqPath->{process_speed};

    $out{processing} = join( ' - ', @proc ) if @proc;

    my $tier = $c->hqTier;

    $out{tier} = cstring( $client,
          $tier == 1 ? 'PLUGIN_HQPLAYER_TIER1'
        : $tier == 3 ? 'PLUGIN_HQPLAYER_TIER3'
        : $tier == 5 ? 'PLUGIN_HQPLAYER_TIER5'
        :              'PLUGIN_HQPLAYER_TIER4' ) if $tier;

    return \%out;
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
# Discovery asks this before it decides how hard to keep probing: an instance
# whose control link is up needs no finding.  An instance that has been
# discovered but has no bridge yet is deliberately NOT settled - the player is
# still being built.
sub _linkUpFor {
    my $ip = shift or return 0;

    for my $b ( values %bridges ) {
        next unless $b->{instance} && ( $b->{instance}->{ip} || '' ) eq $ip;
        return $b->{control} && $b->{control}->connected ? 1 : 0;
    }

    return 0;
}

# $partial is set when discovery is announcing a reply mid-round, before the
# rest of the instances have had their chance to answer.  Such a list is
# additive only: see the removal pass at the end.
sub _onInstances {
    my ( $instances, $partial ) = @_;

    $instances ||= [];

    my %seen;

    my $ids = _idsFor($instances);

    for my $inst (@$instances) {
        my $id   = $ids->{ $inst->{ip} }->{id};
        my $name = $ids->{ $inst->{ip} }->{name};

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
# build it again 60 seconds later, killing playback every time.  (A DHCP move
# is the same shape - the old address lingers in the discovery table for
# INSTANCE_TTL, so for that window the instance appears twice under one name.)
#
# So a name that more than one live instance answers to is not usable on its
# own, and those instances are told apart by address.  A name only one instance
# answers to - the ordinary case, and the only one where the prefs actually
# matter - keeps the plain name-derived id and its DHCP immunity.
sub _idsFor {
    my $instances = shift || [];

    my %byName;

    for my $inst (@$instances) {
        push @{ $byName{ $inst->{name} || $inst->{ip} } }, $inst;
    }

    my %id;

    for my $name ( keys %byName ) {
        my $group = $byName{$name};

        if ( @$group == 1 ) {
            my $inst = $group->[0];
            $id{ $inst->{ip} } = {
                id   => _idFor($name),
                name => _nameFor( $inst, 0 ),
            };
            next;
        }

        $log->warn( scalar(@$group) . " instances answer to '$name' ("
            . join( ', ', map { $_->{ip} } @$group )
            . ') - identifying them by address instead' );

        for my $inst (@$group) {
            $id{ $inst->{ip} } = {
                id   => _idFor( $name . '@' . $inst->{ip} ),
                name => _nameFor( $inst, 1 ),
            };
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

    # Also after init, for the same reason: the client's prefs have to exist
    # before we can tell an unset bitrate cap from a chosen one.  Without this
    # LMS transcodes every streamed track to MP3 320 - see initBitrateLimit.
    eval { $client->initBitrateLimit };
    $log->warn("could not set the bitrate limit for $id: $@") if $@;

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

    $client->hqControl($ctl);
    $client->hqInstance($inst);

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

    my $client = $b->{client} or return;

    if ($up) {
        $client->refreshInfo;

        # The status subscription is armed HERE, not at a track load.  It is
        # the plugin's only liveness signal for a peer that goes quiet without
        # closing the socket, and discovery reads that link state to decide how
        # hard to keep probing - see _statusWatchdog in Player.pm.
        $client->_startPolling;
    }
    else {
        $client->_stopPolling;
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
