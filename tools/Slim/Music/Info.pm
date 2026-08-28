package Slim::Music::Info;
sub isRemoteURL {0}

# format code -> mime type, as the real one is keyed. Only what we look up.
our %types = ( flc => 'audio/x-flac', mp3 => 'audio/mpeg', aif => 'audio/x-aiff', pcm => 'audio/x-wav', wav => 'audio/x-wav', ogg => 'audio/ogg' );
1;
