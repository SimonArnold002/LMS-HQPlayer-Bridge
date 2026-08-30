package Slim::Player::ReplayGain;

# Stands in for the real class, which decides album vs track gain by comparing
# a song's playlist neighbours.  Player.pm only ever calls fetchGainMode as the
# fallback for a track that has not started yet, so the stub just hands back
# whatever a test has parked here.
my %G;
sub fetchGainMode { return $G{gain} }
sub _setTestGain  { $G{gain} = $_[1] }
1;
