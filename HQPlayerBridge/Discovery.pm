package Plugins::HQPlayerBridge::Discovery;

# HQPlayer instance discovery, and the ROUND CLOCK the rest of the plugin
# keeps time by.
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
# in the payload.
#
# DISCOVERY FINDS, AND ANSWERS NOTHING ELSE (docs/discovery-simplification-
# plan.md, 2026-09-27). The control link is the proof of life - that is how
# Signalyst's own hqp-control and Roon treat HQPlayer - so this module never
# asks the link anything, and the link never waits for it:
#
#   - ONE multicast datagram a round, and no unicast. A known instance needs no
#     finding. (Until 2026-09-27 every known address was ALSO probed by unicast
#     each round, to feed the link's retry pace - a second line in HQPlayer's
#     log per instance per round, for instances whose link was already up.)
#   - the pace depends on this module's own state only - see _schedule.
#   - ONE socket for the life of the plugin. It used to be opened and closed
#     every round and live 1.5s of each, so a late reply was thrown away.
#   - a link going down asks for one probe NOW (probeNow) - an event, not a
#     pace. It keeps a DHCP move as fast as before.
#
# WITH AUTOMATIC DISCOVERY SWITCHED OFF (`udp => 0`) no socket is opened and
# nothing is sent, but the rounds still run: they are when the plugin checks
# the addresses typed into its settings (the `onRound` hook), and a round
# number is how a reply is judged live (Plugin::_liveOf).

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
use constant LISTEN_TIME  => 1.5;   # seconds before a round's list is judged complete

# How long to wait between rounds. HQPlayer never announces itself on its own
# protocol (0 announce verbs in Embedded 6.0.0 or Desktop 5.17.2), so looking
# is the only way a NEW one is ever found:
#
#   nothing found yet        FIRST_BACKOFF, doubling up to COLD_PERIOD
#   anything found           IDLE_PERIOD - a new HQPlayer appears within this
#   automatic discovery off  IDLE_PERIOD - only the typed addresses are checked
#
# Until 2026-09-27 the middle case asked the control link (a known instance not
# connected meant COLD_PERIOD), which is what made discovery and the link wait
# on each other. The link now keeps itself alive on its own ladder, capped at
# Control::BACKOFF_MAX (10s), which is the return time the 10s discovery round
# used to give it.
use constant FIRST_BACKOFF => 2;
use constant COLD_PERIOD   => 10;
use constant IDLE_PERIOD   => 15;

# How long an instance may stay silent before its entry goes, and with it -
# if its control link is not up either - its player.
#
# Five minutes is Lyrion's own figure: Slimproto.pm forgets a player that has
# been disconnected for `$forget_disconnected_time = 300` seconds. And like
# Lyrion, only a DISCONNECTED one: a player whose control link is still up is
# never removed over discovery alone (Plugin::_onInstances), because the link
# is the proof of life - its watchdog drops a silent peer within ~40s.
#
# Deliberately generous: HQPlayer restarts its server on configuration
# changes, and answers neither UDP nor TCP while it does. Expiring quickly
# would tear the player down over a blip and build it again moments later.
#
# KEPT when the unicast probe went (2026-09-27): a daemon that answers
# discovery but refuses control (an expired trial, a wedged daemon) sits
# quietly with its Restart row, rather than being forgotten and rebuilt every
# five minutes. Multicast alone refreshes it.

my $sock;          # the plugin's one UDP socket, while `udp` is on
my %found;         # ip => { ip, name, version, lastSeen, round }
my $onChange;      # caller's callback: ( \@instances, $partial )
my $onRound;       # caller's hook, called as a round STARTS: ( $roundNo )
my $running    = 0;
my $udp        = 0;    # automatic discovery on: a socket and a probe a round
my $collecting = 0;    # a round is listening - _roundDone is pending
my $backoff    = 0;    # the current wait while nothing has been found
my $quiet      = 0;    # a socket/send failure has been reported - see _trouble
my $roundNo    = 1;    # which round a reply answered - see `round` in _reply;
                       # moves on as each round ENDS, in _roundDone. Monotonic
                       # across stop/start, so stamps from before a restart
                       # can never read as current.

# start( $onChange, onRound => $cb, udp => 0|1 )
#
# `udp` defaults to ON. Restarting a running clock (the switch saved in the
# settings) stops it first.
sub start {
    my ( $class, $cb, %opts ) = @_;

    $class->stop if $running;

    $onChange = $cb;
    $onRound  = $opts{onRound};
    $udp      = exists $opts{udp} ? ( $opts{udp} ? 1 : 0 ) : 1;
    $running  = 1;
    $backoff  = 0;
    $quiet    = 0;

    _openSocket() if $udp;

    _round();

    return;
}

sub stop {
    $running    = 0;
    $udp        = 0;
    $collecting = 0;
    $backoff    = 0;
    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::killTimers( undef, \&_roundDone );
    _closeSocket();
    %found = ();

    return;
}

sub running   { $running }

# Is automatic discovery on - a socket, and a probe a round?
sub listening { $running && $udp ? 1 : 0 }

sub instances {
    return [ map { $found{$_} } sort keys %found ];
}

sub _socket { $sock }    # for the tests

# The round being collected now. An instance whose `round` equals it answered
# THIS round.
sub round { $roundNo }

# A control link has just gone down: look now rather than at the next round,
# so a DHCP move is followed as soon as the link notices it.
#
# ONE probe, however many links drop at once: a round that is already
# listening IS the probe, so this does nothing then. With automatic discovery
# off there is nothing to send, and nothing is sent.
sub probeNow {
    return unless $running && $udp;
    return if $collecting;

    main::DEBUGLOG && $log->is_debug && $log->debug('discovery: a link dropped - probing now');

    Slim::Utils::Timers::killTimers( undef, \&_round );
    _round();

    return;
}

# ---------------------------------------------------------------------------
# One round
# ---------------------------------------------------------------------------
sub _round {
    return unless $running;

    Slim::Utils::Timers::killTimers( undef, \&_roundDone );

    $collecting = 1;

    # The typed addresses are checked on the same clock, so a reply from one
    # and a reply from discovery carry comparable round numbers.
    if ($onRound) {
        eval { $onRound->($roundNo); 1 }
            or $log->error("discovery: round hook failed: $@");
    }

    _probe() if $udp;

    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + LISTEN_TIME, \&_roundDone );

    return;
}

# The round's one probe: the multicast datagram, and nothing else.
sub _probe {
    _openSocket() unless $sock;
    return unless $sock;

    my $sent = _sendTo( pack_sockaddr_in( MCAST_PORT, Socket::inet_aton(MCAST_ADDR) ) );

    if ( !defined $sent ) {
        _trouble("multicast send failed: $! (is the network up?)");

        # A fresh socket next round, in case this one is tied to an interface
        # that has gone.
        _closeSocket();
        return;
    }

    if ($quiet) {
        $quiet = 0;
        main::INFOLOG && $log->is_info && $log->info('discovery: sending again');
    }

    main::DEBUGLOG && $log->is_debug && $log->debug('discovery: probe sent');

    return;
}

# The one send(), as a sub so the tests can count datagrams without putting
# one on the network.
sub _sendTo {
    my $dest = shift;
    return send( $sock, PROBE_XML, 0, $dest );
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
    # reply landing after LISTEN_TIME - which the one long-lived socket now
    # accepts - carries the NEXT round's number, and is judged with it.
    $found{$ip} = {
        ip       => $ip,
        name     => $name,
        version  => $version,
        lastSeen => time(),
        round    => $roundNo,
    };

    return unless $isNew;

    # Do not sit on it until the round ends: the reply is the whole of what we
    # were waiting for.
    #
    # PARTIAL, and it matters: the second argument tells the caller that this
    # list is still being collected. Without it the caller's reconcile would
    # read "not in the list" as "gone" and tear down every OTHER instance's
    # player simply because it had not answered yet in this round.
    main::INFOLOG && $log->is_info && $log->info("discovery: found '$name' at $ip");

    $onChange->( instances(), 1 ) if $onChange;

    return;
}

sub _roundDone {
    $collecting = 0;

    # Drop anything silent for longer than INSTANCE_TTL, otherwise a vanished
    # instance would linger in %found forever and its player could never be
    # removed.
    my $cutoff = time() - INSTANCE_TTL;

    for my $ip ( keys %found ) {
        next if $found{$ip}->{lastSeen} >= $cutoff;
        main::INFOLOG && $log->is_info && $log->info("discovery: $ip stopped answering");
        delete $found{$ip};
    }

    if ( $udp && !scalar keys %found ) {
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

# The next round - see IDLE_PERIOD for the waits. Nothing but this module's
# own state goes into it.
sub _schedule {
    return unless $running;

    my $wait;

    if ( $udp && !scalar keys %found ) {
        $backoff = $backoff ? $backoff * 2 : FIRST_BACKOFF;
        $backoff = COLD_PERIOD if $backoff > COLD_PERIOD;
        $wait    = $backoff;
    }
    else {
        $backoff = 0;
        $wait    = IDLE_PERIOD;
    }

    main::DEBUGLOG && $log->is_debug && $log->debug("discovery: next round in ${wait}s");

    Slim::Utils::Timers::killTimers( undef, \&_round );
    Slim::Utils::Timers::setTimer( undef, Time::HiRes::time() + $wait, \&_round );

    return;
}

sub _openSocket {
    return $sock if $sock;

    $sock = IO::Socket::INET->new(
        Proto    => 'udp',
        Blocking => 0,
    );

    # BOUND NOW, to an ephemeral port. IO::Socket::INET does not bind for
    # `LocalPort => 0` (a false port is read as "none"), so the socket only
    # got a port at its first send - and a socket that has never sent has
    # nowhere for a reply to land.
    if ( $sock && !bind( $sock, pack_sockaddr_in( 0, Socket::INADDR_ANY() ) ) ) {
        CORE::close($sock);
        $sock = undef;
    }

    if ( !$sock ) {
        _trouble("cannot open UDP socket: $!");
        return;
    }

    # Reach instances one hop away where the platform lets us say so; the
    # default TTL of 1 still covers the ordinary same-subnet case.
    eval {
        setsockopt( $sock, Socket::IPPROTO_IP(), Socket::IP_MULTICAST_TTL(), pack( 'I', 4 ) );
    };

    Slim::Networking::Select::addRead( $sock, \&_reply );

    return $sock;
}

sub _closeSocket {
    return unless $sock;

    Slim::Networking::Select::removeRead($sock);
    CORE::close($sock);
    $sock = undef;

    return;
}

# One warning per spell of trouble, not one per round: with the network down
# a round comes every 2-10s.
sub _trouble {
    my $msg = shift;

    if ($quiet) {
        main::DEBUGLOG && $log->is_debug && $log->debug("discovery: $msg");
        return;
    }

    $quiet = 1;
    $log->warn("discovery: $msg - further failures are logged at debug");

    return;
}

1;
