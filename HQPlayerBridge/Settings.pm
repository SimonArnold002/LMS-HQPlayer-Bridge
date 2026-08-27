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
        };
    }

    $params->{hqp_bridges} = \@rows;
    $params->{hqp_version} = Plugins::HQPlayerBridge::Plugin::version();

    return $class->SUPER::handler( $client, $params, $callback, @args );
}

1;
