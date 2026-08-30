package Slim::Music::Info;
# The real one asks Slim::Player::ProtocolHandlers whether the scheme is
# registered as remote.  Faithful enough here: anything with a scheme that is
# not file: is remote, which is what the tier split turns on.
sub isRemoteURL {
    my $url = shift;
    return 0 unless defined $url && length $url;
    return 0 if $url =~ m{^file://}i;
    return scalar( $url =~ m{^[a-z][a-z0-9+.-]*://}i ) ? 1 : 0;
}

# format code -> mime type, as the real one is keyed. Only what we look up.
our %types = ( flc => 'audio/x-flac', mp3 => 'audio/mpeg', aif => 'audio/x-aiff', pcm => 'audio/x-wav', wav => 'audio/x-wav', ogg => 'audio/ogg' );
1;
