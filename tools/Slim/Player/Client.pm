package Slim::Player::Client;
use strict; use warnings;
use base qw(Slim::Utils::Accessor);
use Slim::Utils::Accessor;
__PACKAGE__->mk_accessor('rw', qw(
    id macaddress paddr revision deviceid uuid tcpsock udpsock
    display controller name songElapsedSeconds streamingsocket
    bufferReady readyToStream _tempVolume chunks
));
# The tier 4 endpoint resolves a url token by scanning the client list, so the
# stub has to have one.
our @REGISTRY;

sub new { my $class = shift; my $c = $class->SUPER::new; $c->id($_[0]); $c->chunks([]); push @REGISTRY, $c; return $c }
sub init {}

sub clients { return @REGISTRY }

# The real one delegates to Slim::Player::Source::nextChunk; the tier 4 tests
# only care that an override can see what it returns.  NOTE the client is a
# blessed ARRAY, so this cannot be stashed on the object.
our $NEXT_CHUNK;
sub nextChunk { return $NEXT_CHUNK }
sub getClient { my $id = shift; for (@REGISTRY) { return $_ if $_->id eq $id } return undef }
sub _resetRegistry { @REGISTRY = () }
sub execute {}
sub forgetClient {}

sub maxVolume { 100 }
sub minVolume { 0 }

# Faithful to Slim::Player::Client::volume, because the plugin depends on both
# halves of it: a temporary level is NOT persisted (LMS's pause ramp arrives
# that way), and a temporary level is returned in preference to the real one.
sub volume {
    my ( $client, $volume, $temp ) = @_;

    my $prefs = Slim::Utils::Prefs::preferences('server')->client($client);

    if ( defined $volume ) {
        $volume = $client->maxVolume if $volume > $client->maxVolume;

        if ($temp) {
            $client->_tempVolume($volume);
        }
        else {
            $prefs->set( 'volume', $volume );
            $client->_tempVolume(undef);
        }
    }

    my $t = $client->_tempVolume;

    return defined $t ? $t : $prefs->get('volume');
}
1;
