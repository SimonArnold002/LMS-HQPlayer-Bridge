package Plugins::HQPlayerBridge::Discovery;

# HQPlayer instance discovery.
#
# Verified live against hqplayerd: a UDP datagram sent to the multicast group
# 239.192.0.199:4321 carrying
#
#     <?xml version="1.0" encoding="UTF-8"?><discover>hqplayer</discover>
#
# is answered by every instance on the segment with, e.g.
#
#     <discover name="HQPlayerEmbedded" result="OK"
#               version="Signalyst HQPlayer Embedded 6">hqplayer</discover>
#
# The instance's address is the datagram's sender address - it is not carried
# in the payload.  This is the whole of the plugin's zero-configuration story.

use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(inet_ntoa pack_sockaddr_in unpack_sockaddr_in);
use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

use Plugins::HQPlayerBridge::Control;

my $log = logger('plugin.hqplayerbridge');

use constant MCAST_ADDR   => '239.192.0.199';
use constant MCAST_PORT   => 4321;
use constant INSTANCE_TTL => 15 * 60;   # see the note above

use constant PROBE_XML    => '<?xml version="1.0" encoding="UTF-8"?><discover>hqplayer</discover>';
use constant LISTEN_TIME  => 1.5;   # seconds to collect replies per round
use constant ROUND_PERIOD => 60;    # seconds between rounds

# How long an instance may stay silent before we give up on it and let its
# player be removed.
#
# Deliberately generous.  Discovery only exists to FIND instances and to notice
# an address change - the control link is the real liveness signal, and it
# reconnects with backoff indefinitely.  HQPlayer restarts its server on
# configuration changes and when its NAA comes and goes, and during that window
# it answers neither UDP discovery nor TCP.  Expiring quickly would tear the LMS
# player down over a blip, losing its playlist, prefs and sync group, and then
# recreate it moments later.  Better to keep the player and let the control link
# reconnect - which is exactly what it did.

# Retry interval used while NOTHING has been found yet, doubling up to
# ROUND_PERIOD.
#
# The steady-state period is deliberately slow, but it used to apply to the
# cold start too, and that is a different problem: with an empty instance list
# there is no player at all, so a single lost probe costs a full minute of the
# plugin looking broken.  One multicast datagram is easy to lose - the probe
# went out at 09:48:49 while hqplayerd happened to be restarting, and the
# player did not appear until 09:49:49.
#
# So: probe hard until something answers, then settle down.  Once an instance
# is known this backs off to ROUND_PERIOD and stays there, and a silent round
# no longer matters because INSTANCE_TTL keeps the player alive across it.
use constant FIRST_BACKOFF => 2;

my $sock;         # live only for the duration of a round
my %found;        # ip => { ip, name, version, lastSeen }
my $onChange;     # caller's callback
my $running = 0;
my $backoff = 0;  # current cold-start retry interval, 0 once something answers

sub start {
    my ( $class, $cb ) = @_;

    $onChange = $cb;
    $running  = 1;
    $backoff  = 0;

    _round();

    return;
}

sub stop {
    $running = 0;
    $backoff = 0;
    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::killTimers( undef, \&_roundDone );
    _closeSocket();
    %found = ();

    return;
}

sub instances {
    return [ map { $found{$_} } sort keys %found ];
}

# ---------------------------------------------------------------------------
# One discovery round
# ---------------------------------------------------------------------------
sub _round {
    return unless $running;

    _closeSocket();

    $sock = IO::Socket::INET->new(
        Proto     => 'udp',
        Blocking  => 0,
        LocalPort => 0,
    );

    if ( !$sock ) {
        $log->warn("discovery: cannot open UDP socket: $!");
        return _schedule();
    }

    # Reach instances one hop away where the platform lets us say so; the
    # default TTL of 1 still covers the ordinary same-subnet case.
    eval {
        setsockopt( $sock, Socket::IPPROTO_IP(), Socket::IP_MULTICAST_TTL(), pack( 'I', 4 ) );
    };

    my $dest = pack_sockaddr_in( MCAST_PORT, Socket::inet_aton( MCAST_ADDR ) );

    my $sent = send( $sock, PROBE_XML, 0, $dest );

    if ( !defined $sent ) {
        $log->warn("discovery: multicast send failed: $! (is the network up?)");
        _closeSocket();
        return _schedule();
    }

    main::DEBUGLOG && $log->is_debug && $log->debug('discovery: probe sent, listening ' . LISTEN_TIME . 's');

    Slim::Networking::Select::addRead( $sock, \&_reply );

    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + LISTEN_TIME, \&_roundDone );

    return;
}

sub _reply {
    my $s = shift || $sock;
    return unless $s;

    my $from = recv( $s, my $buf, 4096, 0 );
    return unless defined $from && length $buf;

    my ( $port, $addr ) = unpack_sockaddr_in($from);
    my $ip = inet_ntoa($addr);

    return unless $buf =~ /<discover\b/;

    my $attrs = Plugins::HQPlayerBridge::Control::parseAttrs($buf);

    my $name    = Plugins::HQPlayerBridge::Control::pick( $attrs, 'name' )    || 'HQPlayer';
    my $version = Plugins::HQPlayerBridge::Control::pick( $attrs, 'version' ) || '';

    main::DEBUGLOG && $log->is_debug && $log->debug("discovery: $ip -> name='$name' version='$version'");

    $found{$ip} = {
        ip       => $ip,
        name     => $name,
        version  => $version,
        lastSeen => time(),
    };

    return;
}

sub _roundDone {
    _closeSocket();

    # Drop anything silent for longer than INSTANCE_TTL, otherwise a vanished
    # instance would linger in %found forever and its player could never be
    # removed.
    my $cutoff = time() - INSTANCE_TTL;

    for my $ip ( keys %found ) {
        next if $found{$ip}->{lastSeen} >= $cutoff;
        main::INFOLOG && $log->is_info && $log->info("discovery: $ip stopped answering");
        delete $found{$ip};
    }

    if ( !scalar keys %found ) {
        main::INFOLOG && $log->is_info && $log->info(
            'discovery: no HQPlayer instances answered on ' . MCAST_ADDR . ':' . MCAST_PORT
        );
    }

    $onChange->( instances() ) if $onChange;

    _schedule();

    return;
}

sub _schedule {
    return unless $running;

    my $wait = ROUND_PERIOD;

    if ( scalar keys %found ) {
        # Something answered - settle into the steady-state period.
        $backoff = 0;
    }
    else {
        $backoff = $backoff ? $backoff * 2 : FIRST_BACKOFF;
        $backoff = ROUND_PERIOD if $backoff > ROUND_PERIOD;
        $wait    = $backoff;

        main::DEBUGLOG && $log->is_debug && $log->debug(
            "discovery: nothing found yet, retrying in ${wait}s" );
    }

    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $wait, \&_round );

    return;
}

sub _closeSocket {
    return unless $sock;

    Slim::Networking::Select::removeRead($sock);
    CORE::close($sock);
    $sock = undef;

    return;
}

1;
