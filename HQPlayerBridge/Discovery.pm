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
use constant INSTANCE_TTL => 5 * 60;    # see the note below IDLE_PERIOD

use constant PROBE_XML    => '<?xml version="1.0" encoding="UTF-8"?><discover>hqplayer</discover>';
use constant LISTEN_TIME  => 1.5;   # seconds to collect replies after the last probe

# ONE probe a round: the multicast datagram, plus the same datagram straight
# to every address already known (see _probe). hqplayerd writes a line to its
# log for every probe it receives, so each one is noise in the user's log.
#
# Until 2026-09-25 a round sent a BURST of three, 0.2s apart, after two probes
# were measured never arriving - one while hqplayerd was restarting, one while
# it was starting its audio engine. The burst could not cover that: all three
# land inside the same restart window (one was 27s long). What does cover it
# is the next round, and while anything is missing that is at most
# COLD_PERIOD away. With the burst at a 5s pace the Mac mini's log was 92%
# discovery lines (measured 2026-09-25, ~54 a minute).

# How long to wait between rounds. HQPlayer never announces itself, so looking
# is the only way a NEW one is ever found - but an instance whose control link
# is up needs no finding. So:
#
#   nothing found yet            FIRST_BACKOFF, doubling up to COLD_PERIOD
#   a known one not connected    COLD_PERIOD - it may be back, or moved
#   every known one connected    IDLE_PERIOD - only a NEW HQPlayer is left
#                                to find, and it appears within this long
#
# "Connected" is the caller's answer (Plugin::_linkUpFor), the same one
# Material shows. The idle period was ten minutes until 2026-09-23, which hid
# a second HQPlayer switched on while the first was connected for up to ten
# minutes; then a flat 5s, which filled HQPlayer's log. 15s, Simon's call
# 2026-09-25.
use constant FIRST_BACKOFF => 2;
use constant COLD_PERIOD   => 10;
use constant IDLE_PERIOD   => 15;

# How long an instance may stay silent before we give up on it and let its
# player be removed.
#
# Deliberately generous.  Discovery only exists to FIND instances and to notice
# an address change - the control link is the real liveness signal, and it
# reconnects with backoff indefinitely.  HQPlayer restarts its server on
# configuration changes, and during that window it answers neither UDP
# discovery nor TCP.  Expiring quickly would tear the LMS
# player down over a blip, losing its playlist, prefs and sync group, and then
# recreate it moments later.  Better to keep the player and let the control link
# reconnect - which is exactly what it did.
#
# Five minutes is Lyrion's own figure: Slimproto.pm forgets a player that has
# been disconnected for `$forget_disconnected_time = 300` seconds. And like
# Lyrion, only a DISCONNECTED one: a player whose control link is still up is
# never removed over discovery alone (Plugin::_onInstances), because the link
# is the proof of life - its watchdog drops a silent peer within ~40s. So a
# switched-off host's player goes ~5 minutes after it went quiet; it was 15.

my $sock;         # live only for the duration of a round
my %found;        # ip => { ip, name, version, lastSeen, round }
my $onChange;     # caller's callback
my $linkUp;       # caller's "is this address's control link connected?"
my $running = 0;
my $backoff = 0;  # the current wait while nothing has been found
my $roundNo = 1;  # which round a reply answered - see `round` in _reply;
                  # moves on as each round ENDS, in _roundDone

sub start {
    my ( $class, $cb, $linkCb ) = @_;

    $onChange = $cb;
    $linkUp   = $linkCb;
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

# The round being collected now. An instance whose `round` equals it answered
# THIS round - the caller uses that to tell "just heard" from "remembered".
sub round { $roundNo }

# ---------------------------------------------------------------------------
# One discovery round
# ---------------------------------------------------------------------------
sub _round {
    return unless $running;

    # A round left listening - the plugin was stopped and restarted inside
    # it - must not close the new round's socket.
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

    _probe();

    return;
}

# The round's one probe.
sub _probe {
    return unless $running && $sock;

    my $dest = pack_sockaddr_in( MCAST_PORT, Socket::inet_aton( MCAST_ADDR ) );

    my $sent = send( $sock, PROBE_XML, 0, $dest );

    if ( !defined $sent ) {
        $log->warn("discovery: multicast send failed: $! (is the network up?)");
        _closeSocket();
        return _schedule();
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

    main::DEBUGLOG && $log->is_debug && $log->debug(
        'discovery: probe sent, listening ' . LISTEN_TIME . 's' );

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

    # `round` says WHICH ROUND this reply answered. It is how the caller tells
    # an address the daemon has left from one that is still answering: two
    # replies in the same round are both live, whatever the clock says. A
    # timestamp cannot say that on its own - how stale a left-behind address
    # looks depends on the period between rounds, and the caller's allowance
    # for it silently broke when that period changed.
    $found{$ip} = {
        ip       => $ip,
        name     => $name,
        version  => $version,
        lastSeen => time(),
        round    => $roundNo,
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

    # Only now, after the complete list has been judged: every reply from here
    # on belongs to the next round.
    $roundNo++;

    _schedule();

    return;
}

# Every known instance has a connected control link. Nothing known is not
# settled, and neither is a caller that cannot say.
sub _settled {
    return 0 unless $linkUp && scalar keys %found;

    for my $ip ( keys %found ) {
        return 0 unless $linkUp->($ip);
    }

    return 1;
}

# The next round - see IDLE_PERIOD for the three waits.
sub _schedule {
    return unless $running;

    my $wait;

    if ( !scalar keys %found ) {
        $backoff = $backoff ? $backoff * 2 : FIRST_BACKOFF;
        $backoff = COLD_PERIOD if $backoff > COLD_PERIOD;
        $wait    = $backoff;
    }
    else {
        $backoff = 0;
        $wait    = _settled() ? IDLE_PERIOD : COLD_PERIOD;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug("discovery: next round in ${wait}s");

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
