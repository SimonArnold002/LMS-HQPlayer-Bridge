package Plugins::HQPlayerBridge::Control;

# Async XML control client for a single HQPlayer instance (TCP port 4321).
#
# Protocol facts (verified against a live hqplayerd and against the working
# reference client zeropointnine/hqpwv):
#
#   * Each request is the literal string
#         <?xml version="1.0" encoding="UTF-8"?>
#     immediately followed by the command element.  No newline, no length
#     prefix, nothing else.
#   * Exactly ONE command may be in flight at a time.  Pipelining desyncs the
#     stream, so every request is queued and issued strictly in order.
#   * Unknown commands are answered with result="Error" and the text
#     "Unknown command", and the link SURVIVES - verified live 2026-08-26.
#     (An earlier note claiming HQPlayer closes the socket on unrecognised XML
#     came from a third-party client and is wrong.)  The %KNOWN whitelist below
#     is kept anyway: it costs nothing, keeps typos out of the wire, and means
#     a caller gets a clean failed callback instead of a puzzling Error reply.
#   * Every command answers with its OWN root tag, so replies are matched by
#     tag name.  Only an explicit result="Error" counts as failure.
#   * <Status/> IS A SUBSCRIBE.  Verified live: playing pushes nothing and
#     seeking pushes nothing, but once a single <Status/> has been sent
#     HQPlayer streams Status messages at roughly 1/s, unsolicited, for as long
#     as the link is up.  Several can therefore arrive in one read, and one can
#     land between a request and its reply.  So the reader below extracts one
#     complete message at a time and matches replies BY ROOT ELEMENT NAME
#     rather than assuming the next message is the answer.
#
# All socket IO here is non-blocking and driven from Slim::Networking::Select,
# so nothing in this module may ever block the LMS event loop.

use strict;
use warnings;

use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_ERROR inet_aton pack_sockaddr_in);
use Errno  qw(EINPROGRESS EWOULDBLOCK EAGAIN EINTR);

use Time::HiRes ();

use Slim::Networking::Select;
use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = logger('plugin.hqplayerbridge');

use constant HQP_PORT        => 4321;
use constant XML_DECL        => '<?xml version="1.0" encoding="UTF-8"?>';
use constant CONNECT_TIMEOUT => 5;
# PlaylistAdd makes HQPlayer fetch and probe the media before it answers, so
# the reply window has to cover a slow origin, not just a round trip.
use constant REPLY_TIMEOUT   => 30;
use constant BACKOFF_MIN     => 2;
use constant BACKOFF_MAX     => 60;

# The complete verified command vocabulary, extracted from the hqplayerd
# binary.  Anything not in here must not go on the wire - see the note about
# socket closes above.
# SetVolume/SetVolumeDB/GetVolume are deliberately ABSENT: they are UPnP
# RenderingControl action names that also appear in the binary, and the XML
# control API answers "Unknown command" to all three.
# NOTE on volume: the command is plain <Volume value="-53"/>, in dB, and the
# current level comes back on every <Status/> as volume="-53".  Probed against
# the live daemon 2026-08-27: SetVolume, SetVolumeDB and GetVolume are all
# "Unknown command" - an earlier guess from the binary's strings was wrong.
my %KNOWN = map { $_ => 1 } qw(
    Play Pause Stop Seek SelectTrack Status State GetInfo Volume
    PlaylistAdd PlaylistClear PlaylistGet
    GetTransport SetTransport GetInputs GetRates GetModes GetFilters
);

# Errors that are not failures.  VERIFIED live 2026-08-27: with an EMPTY
# playlist, every <Volume> answers result="Error" with an album-gain message -
# and applies the level anyway (GetVolumeDB confirms it to 1/256 dB).  It is
# HQPlayer recomputing replaygain for a playlist that has no tracks, not a
# rejection, so logging it as a failure would cry wolf on every volume change
# made while the player is idle.
my %BENIGN = ( Volume => qr/GetAlbumGain/i );

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        ip        => $args{ip},
        name      => $args{name} || $args{ip},
        onState   => $args{onState},      # called as $cb->($self, $connected)
        onStatus  => $args{onStatus},     # called as $cb->($attrs, $raw) for
                                          # EVERY Status message, pushed or not
        queue     => [],
        wbuf      => '',
        rbuf      => '',
        inflight  => undef,
        sock      => undef,
        connected => 0,
        connecting=> 0,
        backoff   => BACKOFF_MIN,
        closing   => 0,
    }, $class;

    return $self;
}

sub ip        { $_[0]->{ip} }
sub name      { $_[0]->{name} }
sub connected { $_[0]->{connected} }

# ---------------------------------------------------------------------------
# Public: queue a command.
#   $cmd is the bare element, e.g. '<Play/>' or '<Seek position="30"/>'
#   $cb  is called as $cb->($attrs_hashref, $raw_xml) on success,
#        or $cb->(undef, undef) if the command failed or the link dropped.
# ---------------------------------------------------------------------------
sub send {
    my ($self, $cmd, $cb) = @_;

    my ($verb) = $cmd =~ /^<([A-Za-z]\w*)/;
    if ( !$verb || !$KNOWN{$verb} ) {
        $log->error("refusing to send unverified command (would drop the link): $cmd");
        $cb->(undef, undef) if $cb;
        return;
    }

    push @{ $self->{queue} }, { cmd => $cmd, cb => $cb, verb => $verb };

    if ( !$self->{sock} && !$self->{connecting} ) {
        $self->connect;
    }
    else {
        $self->_pump;
    }

    return;
}

# ---------------------------------------------------------------------------
# Connection management
# ---------------------------------------------------------------------------
sub connect {
    my $self = shift;

    return if $self->{sock} || $self->{connecting} || $self->{closing};

    my $sock = IO::Socket::INET->new(
        Proto    => 'tcp',
        Blocking => 0,
    );

    if ( !$sock ) {
        $log->warn("$self->{name}: cannot create socket: $!");
        return $self->_scheduleReconnect;
    }

    my $addr = pack_sockaddr_in( HQP_PORT, inet_aton( $self->{ip} ) );

    $self->{sock}       = $sock;
    $self->{connecting} = 1;

    # Non-blocking connect: EINPROGRESS is the expected outcome.
    if ( !CORE::connect( $sock, $addr ) ) {
        my $err = $!;
        if ( $err != EINPROGRESS && $err != EWOULDBLOCK ) {
            $log->warn("$self->{name}: connect failed immediately: $err");
            return $self->_dropLink("connect: $err");
        }
    }

    # Writability signals that the connect has resolved (either way).
    Slim::Networking::Select::addWrite( $sock, sub { $self->_connectResolved } );
    Slim::Networking::Select::addError( $sock, sub { $self->_dropLink('select error during connect') } );

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + CONNECT_TIMEOUT, \&_connectTimeout );

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: connecting to $self->{ip}:" . HQP_PORT);

    return;
}

sub _connectResolved {
    my $self = shift;
    my $sock = $self->{sock} or return;

    Slim::Utils::Timers::killTimers( $self, \&_connectTimeout );
    Slim::Networking::Select::removeWrite($sock);

    # SO_ERROR carries the real outcome of a non-blocking connect.
    my $packed = getsockopt( $sock, SOL_SOCKET, SO_ERROR );
    my $err    = $packed ? unpack( 'I', $packed ) : 0;

    if ($err) {
        $! = $err;
        $log->warn("$self->{name}: connect refused: $!");
        return $self->_dropLink("connect: $!");
    }

    $self->{connecting} = 0;
    $self->{connected}  = 1;
    $self->{backoff}    = BACKOFF_MIN;

    main::INFOLOG && $log->is_info && $log->info("$self->{name}: control link up ($self->{ip})");

    Slim::Networking::Select::addRead( $sock, sub { $self->_readable } );

    $self->{onState}->( $self, 1 ) if $self->{onState};

    $self->_pump;

    return;
}

sub _connectTimeout {
    my $self = shift;
    $log->warn("$self->{name}: connect timed out after " . CONNECT_TIMEOUT . 's');
    $self->_dropLink('connect timeout');
}

sub _replyTimeout {
    my $self = shift;
    my $verb = $self->{inflight} ? $self->{inflight}->{verb} : '(none)';
    $log->warn("$self->{name}: no reply to <$verb> after " . REPLY_TIMEOUT . 's');
    $self->_dropLink('reply timeout');
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
sub _pump {
    my $self = shift;

    return unless $self->{connected} && $self->{sock};
    return if $self->{inflight};

    my $next = shift @{ $self->{queue} } or return;

    $self->{inflight} = $next;
    $self->{wbuf}    .= XML_DECL . $next->{cmd};

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: -> $next->{cmd}");

    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + REPLY_TIMEOUT, \&_replyTimeout );

    $self->_flush;

    return;
}

sub _flush {
    my $self = shift;

    my $sock = $self->{sock} or return;
    return unless length $self->{wbuf};

    my $wrote = syswrite( $sock, $self->{wbuf} );

    if ( !defined $wrote ) {
        return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
        return $self->_dropLink("write: $!");
    }

    substr( $self->{wbuf}, 0, $wrote, '' );

    # Only babysit writability while there is a remainder to push.
    if ( length $self->{wbuf} ) {
        Slim::Networking::Select::addWrite( $sock, sub { $self->_flush } );
    }
    else {
        Slim::Networking::Select::removeWrite($sock);
    }

    return;
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
sub _readable {
    my $self = shift;

    my $sock = $self->{sock} or return;

    my $got = sysread( $sock, my $chunk, 65536 );

    if ( !defined $got ) {
        return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
        return $self->_dropLink("read: $!");
    }

    if ( $got == 0 ) {
        my $verb = $self->{inflight} ? $self->{inflight}->{verb} : undef;
        return $self->_dropLink(
            $verb ? "HQPlayer closed the link while <$verb> was outstanding"
                  : 'HQPlayer closed the link'
        );
    }

    $self->{rbuf} .= $chunk;

    # Drain every complete message the read produced.  Because <Status/> is a
    # subscribe, a single read routinely contains several.
    while ( defined( my $raw = _extractMessage( \$self->{rbuf} ) ) ) {
        $self->_dispatch($raw);
    }

    return;
}

sub _dispatch {
    my ( $self, $raw ) = @_;

    my ($root) = $raw =~ /<([A-Za-z_][\w:.-]*)/;
    $root = '' unless defined $root;
    $root = '' if $root eq '?xml';

    # Skip a leading declaration when reading the root element name.
    if ( $raw =~ /<\?xml.*?\?>\s*<([A-Za-z_][\w:.-]*)/s ) {
        $root = $1;
    }

    my $attrs = parseAttrs($raw);
    my $req   = $self->{inflight};
    my $isErr = ( $attrs->{result} || '' ) eq 'Error';

    # Every Status goes to the status handler, whether it was asked for or
    # pushed - that is what drives the player's state machine.
    if ( $root eq 'Status' && $self->{onStatus} && !$isErr ) {
        eval { $self->{onStatus}->( $attrs, $raw ) };
        $log->error("$self->{name}: onStatus handler died: $@") if $@;
    }

    return unless $req;

    # Match the reply to the outstanding request by root element name.
    # VERIFIED with strict one-in-flight serialisation against a live daemon:
    # EVERY command answers with its own tag - <Pause/> answers <Pause>, and
    # <Stop/> answers <Stop>.  (An earlier note here claimed those two answer
    # with a full <Status/>; that was an artifact of reading a subscribed push
    # stream without framing it properly, and matching on it would let a pushed
    # Status resolve a Pause.)  So the rule is simply: same tag, or not a reply.
    return unless $root eq $req->{verb};

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: <- [$root] for <$req->{verb}>");

    delete $self->{inflight};
    Slim::Utils::Timers::killTimers( $self, \&_replyTimeout );

    if ($isErr) {
        my ($msg) = $raw =~ />([^<]*)</;

        my $benign = $BENIGN{ $req->{verb} };
        my $lvl    = ( $benign && defined $msg && $msg =~ $benign ) ? 'debug' : 'warn';

        $log->$lvl("$self->{name}: <$req->{verb}> failed: " . ( $msg || $raw ));
        $req->{cb}->( undef, $raw ) if $req->{cb};
    }
    else {
        $req->{cb}->( $attrs, $raw ) if $req->{cb};
    }

    $self->_pump;

    return;
}

# Pull exactly ONE complete message off the front of the buffer, consuming it.
# Returns undef (leaving the buffer untouched) when no complete message is
# present yet.
sub _extractMessage {
    my $bufref = shift;

    $$bufref =~ s/^\s+//;
    return undef unless length $$bufref;

    my $off = 0;
    $off = $+[0] if $$bufref =~ /^<\?xml.*?\?>/s;

    my $rest = substr( $$bufref, $off );
    return undef unless $rest =~ /^\s*<([A-Za-z_][\w:.-]*)/;
    my $tag = $1;

    # Self-closing root: no '>' may appear before the '/>'.
    if ( $rest =~ m{^\s*<\Q$tag\E\b[^>]*?/>}s ) {
        my $end = $off + $+[0];
        return substr( $$bufref, 0, $end, '' );
    }

    my $close = index( $$bufref, "</$tag>", $off );
    return undef if $close < 0;

    my $end = $close + length("</$tag>");

    return substr( $$bufref, 0, $end, '' );
}

# A response is one top-level element.  Complete when the root tag has either
# self-closed or been matched by its closing tag.
sub _completeResponse {
    my $buf = shift;

    my $body = $buf;
    $body =~ s/^\s*<\?xml.*?\?>\s*//s;

    return undef unless $body =~ /^<([A-Za-z_][\w:.-]*)/;
    my $tag = $1;

    return $buf if $body =~ m{^<\Q$tag\E\b[^>]*/>\s*$}s;
    return $buf if $body =~ m{</\Q$tag\E>\s*$}s;

    return undef;
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
sub _dropLink {
    my ( $self, $why ) = @_;

    my $wasUp = $self->{connected};

    Slim::Utils::Timers::killTimers( $self, \&_connectTimeout );
    Slim::Utils::Timers::killTimers( $self, \&_replyTimeout );

    if ( my $sock = delete $self->{sock} ) {
        Slim::Networking::Select::removeRead($sock);
        Slim::Networking::Select::removeWrite($sock);
        Slim::Networking::Select::removeError($sock);
        CORE::close($sock);
    }

    $self->{connected}  = 0;
    $self->{connecting} = 0;
    $self->{wbuf}       = '';
    $self->{rbuf}       = '';

    # Fail the outstanding command and everything queued behind it, so callers
    # are never left waiting on a callback that can no longer arrive.
    my $req = delete $self->{inflight};
    $req->{cb}->( undef, undef ) if $req && $req->{cb};

    while ( my $q = shift @{ $self->{queue} } ) {
        $q->{cb}->( undef, undef ) if $q->{cb};
    }

    $log->warn("$self->{name}: control link down - $why") if $wasUp || $log->is_debug;

    $self->{onState}->( $self, 0 ) if $wasUp && $self->{onState};

    $self->_scheduleReconnect unless $self->{closing};

    return;
}

sub _scheduleReconnect {
    my $self = shift;

    return if $self->{closing};

    my $delay = $self->{backoff};
    $self->{backoff} = $self->{backoff} * 2 > BACKOFF_MAX ? BACKOFF_MAX : $self->{backoff} * 2;

    main::DEBUGLOG && $log->is_debug && $log->debug("$self->{name}: reconnecting in ${delay}s");

    Slim::Utils::Timers::killTimers( $self, \&_reconnect );
    Slim::Utils::Timers::setTimer( $self, Time::HiRes::time() + $delay, \&_reconnect );

    return;
}

sub _reconnect {
    my $self = shift;
    $self->connect;
}

sub close {
    my $self = shift;

    $self->{closing} = 1;
    Slim::Utils::Timers::killTimers( $self, \&_reconnect );
    $self->_dropLink('shutting down');

    return;
}

# ---------------------------------------------------------------------------
# Tiny XML helpers.  These payloads are small, flat and machine-generated, so
# a full parser would be more dependency than the job needs.
# ---------------------------------------------------------------------------
sub parseAttrs {
    my $frag = shift or return {};

    # Attributes of the first (root) element only.
    my ($head) = $frag =~ /<[A-Za-z_][\w:.-]*\b([^>]*)>/s;
    return {} unless defined $head;

    my %a;
    while ( $head =~ /([\w:.-]+)\s*=\s*"([^"]*)"/g ) {
        $a{$1} = unescape($2);
    }

    return \%a;
}

# Return a list of attribute hashes for every <$tag .../> inside $frag.
sub parseChildren {
    my ( $frag, $tag ) = @_;
    return () unless $frag;

    my @out;
    while ( $frag =~ m{<\Q$tag\E\b([^>]*?)/?>}gs ) {
        my $head = $1;
        my %a;
        while ( $head =~ /([\w:.-]+)\s*=\s*"([^"]*)"/g ) {
            $a{$1} = unescape($2);
        }
        push @out, \%a;
    }

    return @out;
}

# HQPlayer's exact attribute spelling is not fully pinned down yet, so every
# read goes through here and accepts any of the plausible names.
sub pick {
    my ( $attrs, @names ) = @_;
    return undef unless ref $attrs eq 'HASH';

    for my $n (@names) {
        return $attrs->{$n} if defined $attrs->{$n} && $attrs->{$n} ne '';
        # case-insensitive fallback
        for my $k ( keys %$attrs ) {
            return $attrs->{$k} if lc($k) eq lc($n) && defined $attrs->{$k} && $attrs->{$k} ne '';
        }
    }

    return undef;
}

sub escape {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&apos;/g;
    return $s;
}

sub unescape {
    my $s = shift;
    return '' unless defined $s;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&apos;/'/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

1;
