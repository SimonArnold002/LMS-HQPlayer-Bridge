package Slim::Player::Source;
use strict; use warnings;

# The live playback position, which is NOT in the status result - that is why
# nowPlayingFor asks for it separately. Driven by the tests.
our $SONGTIME = 0;
sub songTime { return $SONGTIME }

1;
