package Plugins::HQPlayerBridge::UPnP;

# HQPlayer's UPnP MediaRenderer, used alongside the XML control API.
#
# Why both?  The XML API on 4321 is the better state channel - <Status/> is a
# subscribe and pushes ~1/s - but it cannot do two things that matter:
#
#   * METADATA AND ARTWORK.  <PlaylistAdd/> takes a bare uri; HQPlayer labels
#     anything fetched over http as "HTTP stream" and ignores title/artist/
#     album/song attributes entirely.  UPnP's SetAVTransportURI carries
#     DIDL-Lite, which HQPlayer does honour - verified live, including
#     <upnp:albumArtURI>.  HQPlayer then re-serves that cover from its own web
#     server at /cover/current, which is where an endpoint's display picks it
#     up.  This is exactly what the squeeze2upnp bridge was relying on.
#   * VOLUME.  SetVolume/SetVolumeDB/GetVolume all answer "Unknown command" on
#     the XML API - they exist only as UPnP RenderingControl actions.  And
#     RenderingControl speaks 0-100, which is LMS's own scale, so no dB mapping
#     is needed.
#
# Verified live 2026-08-26 against HQPlayer Embedded 6:
#   http://<ip>:8019/root.xml  ->  MediaRenderer:3
#     AVTransport:3      /control/av-transport
#     RenderingControl:3 /control/rendering-control
#
# All requests go through Slim::Networking::SimpleAsyncHTTP, so nothing here
# blocks the event loop.

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Time::HiRes ();

use Plugins::HQPlayerBridge::Control;

my $log = logger('plugin.hqplayerbridge');

use constant UPNP_PORT  => 8019;
use constant AV_SERVICE => 'urn:schemas-upnp-org:service:AVTransport:3';
use constant RC_SERVICE => 'urn:schemas-upnp-org:service:RenderingControl:3';

sub new {
    my ( $class, %args ) = @_;

    my $self = bless {
        ip      => $args{ip},
        port    => $args{port} || UPNP_PORT,
        name    => $args{name} || $args{ip},
        av      => undef,    # AVTransport control path
        rc      => undef,    # RenderingControl control path
        ready   => 0,
        backoff => 0,        # current describe retry interval
        epoch   => 0,        # bumped to abandon an in-flight Play retry loop
        closed  => 0,
    }, $class;

    return $self;
}

sub ready { $_[0]->{ready} }
sub base  { 'http://' . $_[0]->{ip} . ':' . $_[0]->{port} }

# The player is going away: drop every timer this object owns, and make sure
# nothing already scheduled comes back to life.
sub close {
    my $self = shift;

    $self->{closed} = 1;
    $self->{epoch}++;

    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );

    return;
}

# ---------------------------------------------------------------------------
# Read the device description to learn the control paths.  They are stable in
# practice, but reading them keeps us correct if HQPlayer ever moves them.
#
# This MUST keep retrying on its own.  Without a description there is no
# control path, and _queueTrack fails every track with PROBLEM_OPENING - the
# player exists but can never play anything.  The description is fetched when
# the player is created and again whenever the control link comes up, and
# neither of those recurs: LMS and hqplayerd starting together (a server
# reboot) is exactly the case where the first fetch fails and the control link
# then stays up, so no further attempt would ever be made.
# ---------------------------------------------------------------------------
use constant DESCRIBE_RETRY_MIN => 5;
use constant DESCRIBE_RETRY_MAX => 60;

sub describe {
    my ( $self, $cb ) = @_;

    return if $self->{closed};

    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );

    my $url = $self->base . '/root.xml';

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $body = shift->content || '';

            # Pair each serviceType with the controlURL that follows it.
            while ( $body =~ m{<serviceType>([^<]+)</serviceType>(.*?)</service>}gs ) {
                my ( $type, $rest ) = ( $1, $2 );
                my ($ctrl) = $rest =~ m{<controlURL>([^<]+)</controlURL>};
                next unless $ctrl;

                $self->{av} = $ctrl if $type =~ /:AVTransport:/;
                $self->{rc} = $ctrl if $type =~ /:RenderingControl:/;
            }

            if ( $self->{av} ) {
                $self->{ready}   = 1;
                $self->{backoff} = 0;
                main::INFOLOG && $log->is_info && $log->info(
                    "$self->{name}: UPnP renderer ready (av=$self->{av}"
                    . ( $self->{rc} ? ", rc=$self->{rc}" : '' ) . ')' );
            }
            else {
                # A reply that is not a MediaRenderer description is no more
                # usable than no reply at all - keep trying.
                $log->warn("$self->{name}: no AVTransport service in $url");
                $self->_scheduleDescribe;
            }

            $cb->( $self->{ready} ) if $cb;
        },
        sub {
            my ( $http, $err ) = @_;
            $log->warn("$self->{name}: cannot read $url: $err");
            $self->_scheduleDescribe;
            $cb->(0) if $cb;
        },
        { timeout => 10 },
    )->get($url);

    return;
}

sub _scheduleDescribe {
    my $self = shift;

    return if $self->{closed} || $self->{ready};

    my $wait = $self->{backoff} ? $self->{backoff} * 2 : DESCRIBE_RETRY_MIN;
    $wait = DESCRIBE_RETRY_MAX if $wait > DESCRIBE_RETRY_MAX;
    $self->{backoff} = $wait;

    main::INFOLOG && $log->is_info && $log->info(
        "$self->{name}: renderer not described yet, retrying in ${wait}s" );

    Slim::Utils::Timers::killTimers( $self, \&_describeRetry );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + $wait, \&_describeRetry );

    return;
}

# setTimer($obj, $when, $cb, @args) calls $cb->($obj, @args), so the object
# arrives as the first argument here.
sub _describeRetry {
    my $self = shift;

    $self->describe;

    return;
}

# ---------------------------------------------------------------------------
# SOAP
# ---------------------------------------------------------------------------
use constant SOAP_TIMEOUT => 15;

sub _soap {
    my ( $self, $service, $path, $action, $body, $cb, $timeout ) = @_;

    if ( !$path ) {
        $log->warn("$self->{name}: $action requested before the renderer was described");
        $cb->( undef, 'not ready' ) if $cb;
        return;
    }

    my $env =
        '<?xml version="1.0" encoding="utf-8"?>'
      . '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
      . ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      . "<u:$action xmlns:u=\"$service\">$body</u:$action>"
      . '</s:Body></s:Envelope>';

    my $url = $self->base . ( $path =~ m{^/} ? $path : "/$path" );

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: UPnP $action -> $url");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: UPnP $action ok");
            $cb->( $res->content, undef ) if $cb;
        },
        sub {
            my ( $http, $err ) = @_;
            # HQPlayer answers 701 "Transition not available" for a transport
            # verb issued in a state that does not allow it - noise, not a fault.
            my $lvl = ( $err && $err =~ /\b701\b/ ) ? 'debug' : 'warn';
            $log->$lvl("$self->{name}: UPnP $action failed: $err");
            $cb->( undef, $err ) if $cb;
        },
        { timeout => $timeout || SOAP_TIMEOUT },
    )->post(
        $url,
        'Content-Type' => 'text/xml; charset="utf-8"',
        'SOAPACTION'   => "\"$service#$action\"",
        $env,
    );

    return;
}

sub _av { my $self = shift; $self->_soap( AV_SERVICE, $self->{av}, @_ ) }
sub _rc { my $self = shift; $self->_soap( RC_SERVICE, $self->{rc}, @_ ) }

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------
sub setURI {
    my ( $self, $url, $didl, $cb ) = @_;

    my $e = \&Plugins::HQPlayerBridge::Control::escape;

    $self->_av(
        'SetAVTransportURI',
        '<InstanceID>0</InstanceID>'
        . '<CurrentURI>' . $e->($url) . '</CurrentURI>'
        . '<CurrentURIMetaData>' . $e->( $didl || '' ) . '</CurrentURIMetaData>',
        $cb,
    );

    return;
}

sub play  { $_[0]->_av( 'Play',  '<InstanceID>0</InstanceID><Speed>1</Speed>', $_[1], $_[2] ) }

# SetAVTransportURI returns as soon as it has accepted the URI, but HQPlayer
# then has to FETCH and probe the media before the transport actually holds
# anything.  Play issued too soon fails with UPnP 702 "no contents" - measured:
# ~0.5s after SetAVTransportURI it fails, ~1s later the identical call
# succeeds.  Nothing in GetMediaInfo reflects this (NrTracks already reads 1),
# so the only reliable approach is to retry.
# The retry is deliberately blind to WHICH error came back.  A UPnP fault is
# an HTTP 500 whose errorCode is in the body, not in the status line the async
# client hands us, so "is this the transient 702" is not reliably answerable
# from $err - and guessing wrong here would break the ordinary case, since a
# failed first Play is normal.
#
# What is bounded instead is the WAIT.  Retrying 8 times on a daemon that has
# stopped answering meant 8 x the 15s SOAP timeout - about two minutes of a
# player that looks like it is buffering before it admits the track failed.
# So: a short timeout per attempt, and a hard deadline across all of them.
# A healthy daemon answers Play in milliseconds and succeeds on attempt 2 or 3.
use constant PLAY_RETRIES  => 8;
use constant PLAY_BACKOFF  => 0.4;
use constant PLAY_TIMEOUT  => 5;    # per attempt
use constant PLAY_DEADLINE => 12;   # across all attempts

# Abandon an in-flight Play retry loop - the track it belongs to is no longer
# the one we want playing.
sub cancelPlay {
    my $self = shift;

    $self->{epoch}++;

    return;
}

sub playWhenReady {
    my ( $self, $cb, $attempt, $deadline, $epoch ) = @_;

    $attempt  ||= 1;
    $deadline ||= Time::HiRes::time() + PLAY_DEADLINE;
    $epoch      = $self->{epoch} unless defined $epoch;

    $self->play( sub {
        my ( $res, $err ) = @_;

        # A stop or a skip happened while this Play was in flight.
        if ( $epoch != $self->{epoch} ) {
            main::DEBUGLOG && $log->is_debug && $log->debug(
                "$self->{name}: Play answered for a cancelled track - dropping" );
            return;
        }

        return $cb->( $res, undef ) if $cb && !$err;
        return                      if !$err;

        my $out = Time::HiRes::time() + PLAY_BACKOFF >= $deadline;

        if ( $attempt >= PLAY_RETRIES || $out ) {
            $log->error( "$self->{name}: Play still failing after $attempt attempt(s)"
                . ( $out ? ' (gave up on time)' : '' ) . ": $err" );
            $cb->( undef, $err ) if $cb;
            return;
        }

        main::DEBUGLOG && $log->is_debug && $log->debug(
            "$self->{name}: Play attempt $attempt not ready yet, retrying" );

        Slim::Utils::Timers::setTimer(
            $self, Time::HiRes::time() + PLAY_BACKOFF,
            \&_playRetry, $cb, $attempt + 1, $deadline, $epoch,
        );
    }, PLAY_TIMEOUT );

    return;
}

sub _playRetry {
    my ( $self, $cb, $attempt, $deadline, $epoch ) = @_;

    # Cancelled while the backoff timer was pending.
    return if $epoch != $self->{epoch};

    $self->playWhenReady( $cb, $attempt, $deadline, $epoch );

    return;
}
sub pause { $_[0]->_av( 'Pause', '<InstanceID>0</InstanceID>',                 $_[1] ) }
sub stop  { $_[0]->_av( 'Stop',  '<InstanceID>0</InstanceID>',                 $_[1] ) }

sub seek {
    my ( $self, $seconds, $cb ) = @_;

    my $t = sprintf( '%d:%02d:%02d', int( $seconds / 3600 ), int( $seconds / 60 ) % 60, $seconds % 60 );

    $self->_av( 'Seek', "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>$t</Target>", $cb );

    return;
}

# RenderingControl speaks 0-100, the same scale LMS uses, so the player's
# volume passes straight through with no conversion.
sub setVolume {
    my ( $self, $vol, $cb ) = @_;

    $vol = 0   if !defined $vol || $vol < 0;
    $vol = 100 if $vol > 100;

    $self->_rc(
        'SetVolume',
        '<InstanceID>0</InstanceID><Channel>Master</Channel>'
        . '<DesiredVolume>' . int($vol) . '</DesiredVolume>',
        $cb,
    );

    return;
}

1;
