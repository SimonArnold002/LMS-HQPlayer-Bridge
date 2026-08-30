package Slim::Player::ReplayGain;

# Stands in for the real class, which decides album vs track gain by comparing
# a song's playlist neighbours.  Player.pm only ever calls fetchGainMode as the
# fallback for a track that has not started yet, so the stub just hands back
# whatever a test has parked here.
my %G;
sub fetchGainMode { return $G{gain} }
sub _setTestGain  { $G{gain} = $_[1] }

# The real thing, verbatim from Slim/Player/ReplayGain.pm - the largest boost a
# peak permits is -20*log10(peak).
sub preventClipping {
    my ( $gain, $peak ) = @_;
    if ( defined $peak && defined $gain && $peak > 0 ) {
        my $noclip = -20 * ( log($peak) / log(10) );
        return $noclip if $noclip < $gain;
    }
    return $gain;
}
1;
