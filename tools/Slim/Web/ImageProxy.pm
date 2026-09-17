package Slim::Web::ImageProxy;

# Mirrors LMS 9.1's proxiedImage, not a pass-through: only an http(s) URL is
# proxied, the ext comes from the source URL (.png when it has none), and the
# URL is escaped with uri_escape_utf8.  A stub laxer than the real sub would let
# _remoteArt pass against a path shape LMS never produces.
use URI::Escape qw(uri_escape_utf8);

sub proxiedImage {
    my ( $url, $force ) = @_;

    return $url unless $force || ( $url && $url =~ /^https?:/ );

    my $ext = '.png';

    if ( $url =~ /(\.(?:jpg|jpeg|png|gif))/ ) {
        $ext = $1;
        $ext =~ s/jpeg/jpg/;
    }

    return '/imageproxy/' . uri_escape_utf8($url) . '/image' . $ext;
}

1;
