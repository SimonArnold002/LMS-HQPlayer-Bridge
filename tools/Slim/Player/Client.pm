package Slim::Player::Client;
use strict; use warnings;
use base qw(Slim::Utils::Accessor);
use Slim::Utils::Accessor;
__PACKAGE__->mk_accessor('rw', qw(
    id macaddress paddr revision deviceid uuid tcpsock udpsock
    display controller name songElapsedSeconds streamingsocket
    bufferReady readyToStream _tempVolume
));
sub new { my $class = shift; my $c = $class->SUPER::new; $c->id($_[0]); return $c }
sub init {}
sub execute {}
sub forgetClient {}
sub volume {}
1;
