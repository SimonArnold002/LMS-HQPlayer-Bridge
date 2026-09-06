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
# No configuration.  Instances are found by multicast, and there is no settings
# page at all - nothing here is configurable, so the only surfaces are the Apps
# feed and the live view (Live.pm).

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
use Slim::Control::Request;
use Slim::Player::Source;

use Plugins::HQPlayerBridge::Live;
use Slim::Display::NoDisplay;
use Slim::Utils::Strings qw(cstring);

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

    Plugins::HQPlayerBridge::Discovery->start( \&_onInstances, \&_linkUpFor );

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
    Plugins::HQPlayerBridge::Discovery->stop;

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

sub topLevel {
    my ( $client, $callback, $args ) = @_;

    # THE ONE ACTION, AND THERE IS NO SETTINGS PAGE BEHIND IT ANY MORE. Nothing
    # in this plugin is configurable, so a settings page was only ever a place
    # to read numbers from - and it could not keep them current.
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

    for my $id ( sort keys %bridges ) {
        my $b = $bridges{$id} or next;

        push @items, { name => $b->{name}, type => 'text' };

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

    # NOTHING DISCOVERED YET SAYS SO, rather than showing a bare link and
    # leaving the user to wonder whether the plugin is working. The wording
    # matches the live page's - waiting, not failed - because that is what it
    # is: discovery keeps probing, and an instance that is simply switched off
    # will appear on its own. The second row is the diagnostic, for the case
    # where it never does.
    if ( !keys %bridges ) {
        push @items,
            { name => cstring( $client, 'PLUGIN_HQPLAYER_LIVE_WAITING' ), type => 'text' },
            { name => cstring( $client, 'PLUGIN_HQPLAYER_NONE_DESC' ),    type => 'text' };
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

        for my $k (qw( connected source output filter shaper speed tier )) {
            $request->addResultLoop( 'bridges_loop', $i, $k, $p->{$k} ) if defined $p->{$k};
        }

        # Now playing rides the SAME poll - one round trip, and the page never
        # has to know which player id belongs to which bridge.
        my $np = nowPlayingFor( $b->{client} );

        for my $k (qw( title artist album artwork state position duration
                       volume muted volctl )) {
            $request->addResultLoop( 'bridges_loop', $i, "np_$k", $np->{$k} )
                if defined $np->{$k};
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
    delete @np{ qw( title artist album artwork duration position ) }
        unless length $np{title};

    return \%np;
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
