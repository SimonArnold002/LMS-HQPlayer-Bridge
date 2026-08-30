package Slim::Web::HTTP;
use strict; use warnings;
use Slim::Player::Client;

# Stub for the half of LMS's HTTP layer the tier 4 endpoint reaches into.
#
# These four are `our` in the real Slim::Web::HTTP, which is what makes the
# handover possible at all: %peerclient is how addStreamingResponse finds the
# player to attach the socket to. If a future LMS makes any of them lexical the
# endpoint stops working, so the names are asserted in t_stream.pl.
our %peerclient    = ();
our %keepAlives    = ();
our %metaDataBytes = ();
our %sendMetaData  = ();

# What the tests read back instead of a socket.
our @SENT;      # completed HTTP responses
our @STREAMS;   # sockets handed to the streaming machinery

sub addHTTPResponse {
    my ( $httpClient, $response, $body ) = @_;
    push @SENT, {
        socket => $httpClient,
        code   => $response->code,
        type   => scalar $response->content_type,
        head   => $response,
        body   => ( $response->request->method eq 'HEAD' ? '' : $$body ),
    };
    return;
}

sub addStreamingResponse {
    my ( $httpClient, $headers ) = @_;
    push @STREAMS, { socket => $httpClient, headers => $headers };

    # The real one attaches the socket to the player it finds in %peerclient.
    # The tier 4 tests turn on that attachment, so the stub has to do it too.
    if ( my $c = Slim::Player::Client::getClient( $peerclient{$httpClient} || '' ) ) {
        $c->streamingsocket($httpClient);
    }
    return;
}

sub _stringifyHeaders {
    my $response = shift;
    return sprintf( "HTTP/1.1 %s OK\015\012%s", $response->code, $response->headers_as_string("\015\012") );
}

sub closeHTTPSocket {}

# LMS's own transcoding download path, which the tier 3 route delegates to.
# The real one decides whether to chunk from $response->request->protocol, so
# the stub records what it was handed.  Returns false for a track that is not a
# local song, exactly as the real one does.
our @DOWNLOADS;
our %NOT_LOCAL;
sub downloadMusicFile {
    my ( $httpClient, $response, $id ) = @_;
    push @DOWNLOADS, {
        socket   => $httpClient,
        id       => $id,
        protocol => $response->request->protocol,
        uri      => $response->request->uri->path,
    };
    return 0 if $NOT_LOCAL{$id};
    return 1;
}

# The tier 4 endpoint closes a player's previous stream connection itself,
# because the two places LMS would do it are both gated on the player being a
# Slim::Player::Squeezebox.
our @CLOSED;
sub closeStreamingSocket {
    my $httpClient = shift;
    push @CLOSED, $httpClient;
    for my $c ( Slim::Player::Client::clients() ) {
        $c->streamingsocket(undef)
            if defined $c->streamingsocket && $c->streamingsocket == $httpClient;
    }
    return;
}

sub forgetClient {
    my $client = shift;
    closeStreamingSocket( $client->streamingsocket ) if defined $client->streamingsocket;
    return;
}

sub _reset { @SENT = (); @STREAMS = (); @CLOSED = (); @DOWNLOADS = (); %peerclient = (); %keepAlives = (); %metaDataBytes = () }

1;
