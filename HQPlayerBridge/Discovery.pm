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
use constant LISTEN_TIME  => 1.5;   # seconds to collect replies after the last probe

# One datagram per round was one point of failure.  MEASURED against a live
# hqplayerd: of five rounds, it logged receiving only three - the probes at
# 17:47:49 (it was restarting) and 17:50:54 (it was initialising its audio
# engine) never arrived at all.  So each round now sends PROBE_BURST probes
# PROBE_GAP apart, which costs three ~80 byte datagrams and removes the whole
# class of "one lost packet, one wasted round".
use constant PROBE_BURST  => 3;
use constant PROBE_GAP    => 0.2;

# The three round periods.  Which one applies is decided in _schedule.
#
#   COLD_PERIOD  nothing is known, or something known is not connected.  This
#                is the "is it back yet?" state, and it wants to be quick.
#   ROUND_PERIOD everything known is connected - but see IDLE_PERIOD.  Kept
#                for the case where the link state cannot be established.
#   IDLE_PERIOD  everything known is connected.  There is nothing to find, so
#                stop asking: the control link is the liveness signal, and it
#                notices a loss long before a discovery round would.
use constant COLD_PERIOD  => 10;
use constant ROUND_PERIOD => 60;
use constant IDLE_PERIOD  => 10 * 60;

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
# So: probe hard until something answers, then settle down.  A silent round
# does not matter once an instance is known, because INSTANCE_TTL keeps the
# player alive across it.
use constant FIRST_BACKOFF => 2;

my $sock;         # live only for the duration of a round
my %found;        # ip => { ip, name, version, lastSeen }
my $onChange;     # caller's callback
my $linkUp;       # caller's per-ip "is the control link up?" predicate
my $running = 0;
my $backoff = 0;  # current cold-start retry interval, 0 once something answers
my $burst   = 0;  # probes left to send in the current round

sub start {
    my ( $class, $cb, $up ) = @_;

    $onChange = $cb;
    $linkUp   = $up;
    $running  = 1;
    $backoff  = 0;

    _round();

    return;
}

sub stop {
    $running = 0;
    $backoff = 0;
    $burst   = 0;
    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::killTimers( undef, \&_probe );
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

    # A round left half-sent - the plugin was stopped and restarted inside a
    # burst - must not fire into the new round's socket.
    Slim::Utils::Timers::killTimers( undef, \&_probe );
    Slim::Utils::Timers::killTimers( undef, \&_roundDone );

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

    Slim::Networking::Select::addRead( $sock, \&_reply );

    $burst = PROBE_BURST;

    _probe();

    return;
}

# One probe of the round's burst.
sub _probe {
    return unless $running && $sock;

    my $first = $burst == PROBE_BURST;

    my $dest = pack_sockaddr_in( MCAST_PORT, Socket::inet_aton( MCAST_ADDR ) );

    my $sent = send( $sock, PROBE_XML, 0, $dest );

    if ( !defined $sent ) {
        # Only the first failure is worth a line and an abandoned round; a
        # later one in the same burst has already been reported.
        if ($first) {
            $log->warn("discovery: multicast send failed: $! (is the network up?)");
            _closeSocket();
            return _schedule();
        }
    }

    # An instance we have already met does not need multicast at all, and
    # multicast is the part that goes missing.  VERIFIED live 2026-09-04
    # against hqplayerd 6.0.4: the SAME datagram sent straight to the
    # instance's address on 4321/udp is answered identically -
    #
    #   unicast   -> <discover name="HQPlayerEmbedded" result="OK" .../>
    #   multicast -> <discover name="HQPlayerEmbedded" result="OK" .../>
    #
    # - so a known instance can be reached down a path that does not depend on
    # group membership, IGMP snooping or which interface the kernel picked.
    for my $ip ( keys %found ) {
        send( $sock, PROBE_XML, 0,
              pack_sockaddr_in( MCAST_PORT, Socket::inet_aton($ip) ) );
    }

    if ( --$burst > 0 ) {
        Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + PROBE_GAP, \&_probe );
        return;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug(
        'discovery: ' . PROBE_BURST . ' probes sent, listening ' . LISTEN_TIME . 's' );

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

    my $isNew = !exists $found{$ip};

    $found{$ip} = {
        ip       => $ip,
        name     => $name,
        version  => $version,
        lastSeen => time(),
    };

    return unless $isNew;

    # Do not sit on it until the round ends.  The reply is the whole of what
    # we were waiting for, and holding it for the rest of LISTEN_TIME put a
    # flat 1.5s in front of every cold start for no reason.
    #
    # PARTIAL, and it matters: the second argument tells the caller that this
    # list is still being collected.  Without it the caller's reconcile would
    # read "not in the list" as "gone" and tear down every OTHER instance's
    # player - killing its playlist and sync group - simply because it had not
    # answered yet in this round.
    main::INFOLOG && $log->is_info && $log->info("discovery: found '$name' at $ip");

    $backoff = 0;

    $onChange->( instances(), 1 ) if $onChange;

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

# True when every instance we know about has a control link that is up.
#
# This is the whole basis for going quiet, so it is deliberately pessimistic:
# no predicate, no instances, or one instance the caller cannot vouch for all
# answer false, and false only ever means "keep looking".
sub _settled {
    return 0 unless $linkUp;
    return 0 unless scalar keys %found;

    for my $ip ( keys %found ) {
        return 0 unless $linkUp->($ip);
    }

    return 1;
}

sub _schedule {
    return unless $running;

    my $wait;

    if ( !scalar keys %found ) {
        # Nothing at all.  Climb the ladder, but cap it at COLD_PERIOD rather
        # than ROUND_PERIOD: an HQPlayer that has just been switched on should
        # be picked up in seconds, and the old 60s cap is exactly what made a
        # cold start take a measured 63s.
        $backoff = $backoff ? $backoff * 2 : FIRST_BACKOFF;
        $backoff = COLD_PERIOD if $backoff > COLD_PERIOD;
        $wait    = $backoff;

        main::DEBUGLOG && $log->is_debug && $log->debug(
            "discovery: nothing found yet, retrying in ${wait}s" );
    }
    elsif ( _settled() ) {
        # Everything known is connected.  Nothing a probe could tell us that
        # the control link will not tell us sooner, so stop filling HQPlayer's
        # log with a discovery request a minute.
        #
        # This is safe BECAUSE it is gated on the link: an instance that goes
        # away - powered off, moved by DHCP, or its host asleep - drops the
        # link, which puts us straight back on COLD_PERIOD below.  So a later
        # power-on is still found in seconds, not in IDLE_PERIOD.
        $backoff = 0;
        $wait    = IDLE_PERIOD;
    }
    else {
        # Known, but not connected.  Same "is it back yet?" state as an empty
        # list, so probe at the same rate - the address may have changed, and
        # a reply is what proves it.
        $backoff = 0;
        $wait    = $linkUp ? COLD_PERIOD : ROUND_PERIOD;
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
