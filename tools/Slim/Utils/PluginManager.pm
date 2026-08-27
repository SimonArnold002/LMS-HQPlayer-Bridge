package Slim::Utils::PluginManager;
# Stub: the real one reads install.xml.  The checks read the same file so that
# the version reported at runtime is verifiably the one that ships.
use strict; use warnings;

my %data;

sub dataForPlugin {
    my ( $class, $plugin ) = @_;
    return $data{$plugin};
}

sub _setTestData { my ( $class, $plugin, $d ) = @_; $data{$plugin} = $d; return }

sub isEnabled { 1 }

1;
