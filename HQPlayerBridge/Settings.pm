package Plugins::HQPlayerBridge::Settings;

# Read-only status page: which HQPlayer instances were found, whether the
# control link to each is up, and which NAA that instance is feeding.
#
# There are deliberately no editable preferences.  Everything the plugin
# needs it discovers for itself.
#
# Note that Material loads plugin settings in an iframe and never surfaces
# $params->{warning}, so all state is rendered as page content instead.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;

use Plugins::HQPlayerBridge::Plugin;

my $log = logger('plugin.hqplayerbridge');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_HQPLAYER_BRIDGE') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/HQPlayerBridge/settings/basic.html') }

sub handler {
    my ( $class, $client, $params, $callback, @args ) = @_;

    my $bridges = Plugins::HQPlayerBridge::Plugin::bridges();

    my @rows;

    for my $id ( sort keys %$bridges ) {
        my $b    = $bridges->{$id};
        my $inst = $b->{instance} || {};
        my $c    = $b->{client};

        push @rows, {
            id        => $id,
            name      => $b->{name},
            ip        => $inst->{ip},
            version   => $inst->{version},
            connected => ( $b->{control} && $b->{control}->connected ) ? 1 : 0,
            transport => $c ? $c->hqTransport : undef,
            rate      => $c ? $c->hqRate      : undef,
            bits      => $c ? $c->hqBits      : undef,
            tier      => $c ? $c->hqTier      : undef,
            # Tidied HERE, not in the template: a Template::Toolkit vmethod
            # that throws takes the whole settings page with it, and a broken
            # settings page is one of the quieter failures in LMS.
            mime      => $c ? _shortMime( $c->hqMime ) : undef,

            # THE SIGNAL PATH.  The input half is rate/bits/mime above, off the
            # <metadata/> child; these are the root attributes of the same
            # <Status/> push and describe what HQPlayer is feeding the NAA
            # after its DSP.  Nothing here costs a round trip - see _onStatus.
            outrate   => $c ? $c->hqPath->{active_rate}    : undef,
            outbits   => $c ? $c->hqPath->{active_bits}    : undef,
            outmode   => $c ? $c->hqPath->{active_mode}    : undef,
            filter    => $c ? $c->hqPath->{active_filter}  : undef,
            shaper    => $c ? $c->hqPath->{active_shaper}  : undef,
            speed     => $c && $c->hqPath->{process_speed}
                       ? sprintf( '%.1f', $c->hqPath->{process_speed} ) : undef,

            # The volume range explains the whole feel of the slider - it is
            # HQPlayer's own setting, and the plugin reads it rather than
            # assuming one, so it is worth showing what was found.
            volmin    => $c ? $c->hqVolMin : undef,
            volmax    => $c ? $c->hqVolMax : undef,
            voldb     => $c ? $c->hqVolDb  : undef,
            volstep   => $c && $c->hqVolMin ? sprintf( '%.2f', $c->_volStep ) : undef,
        };
    }

    $params->{hqp_bridges} = \@rows;
    $params->{hqp_version} = Plugins::HQPlayerBridge::Plugin::version();

    return $class->SUPER::handler( $client, $params, $callback, @args );
}

# audio/x-flac -> FLAC.  HQPlayer reports the source container as a MIME type;
# the bare subtype is what a listener recognises.
sub _shortMime {
    my $mime = shift or return undef;

    $mime =~ s{^audio/}{}i;
    $mime =~ s{^x-}{}i;

    return uc $mime;
}

1;
