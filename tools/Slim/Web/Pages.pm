package Slim::Web::Pages;
use strict; use warnings;

# Stub. The real one ties %rawFunctions to Tie::RegexpHash, so a lookup by PATH
# matches a key registered as a REGEX. That behaviour is the whole reason the
# tier 4 endpoint can register a prefix, so the stub reproduces it rather than
# storing the key literally.
our @RAW;

sub addPageFunction {}
sub addRawDownload  {}

sub addRawFunction {
    my ( $class, $regex, $code ) = @_;
    push @RAW, { regex => $regex, code => $code };
    return;
}

sub getRawFunction {
    my ( $class, $path ) = @_;
    for my $r (@RAW) {
        return $r->{code} if $path =~ $r->{regex};
    }
    return undef;
}

sub _reset { @RAW = () }

1;
