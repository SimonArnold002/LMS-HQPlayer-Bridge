package Slim::Utils::Prefs;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(preferences);

# One store per namespace, not a fresh object per call: the plugin takes its
# handle at module load and the tests take their own, and both have to see the
# same values - which is how the real thing behaves.
my %ns;

sub preferences {
    my $name = shift || '';
    return $ns{$name} ||= bless { store => {}, clients => {} }, 'Slim::Utils::Prefs::Obj';
}

package Slim::Utils::Prefs::Obj;

# Per-client prefs are real here rather than stubbed, because the volume sync
# reads the PERSISTED level back out (that is where Client::volume puts it, and
# where LMS itself reads it at the start of every track).
sub client {
    my ( $self, $client ) = @_;
    my $id = ref $client ? ( $client->id || "$client" ) : "$client";
    return $self->{clients}{$id} ||= bless { store => {}, clients => {} }, ref $self;
}

sub get { $_[0]->{store}{ $_[1] } }
sub set { $_[0]->{store}{ $_[1] } = $_[2] }

sub setPlayerDefault {} sub init {} sub setChange {}
1;
