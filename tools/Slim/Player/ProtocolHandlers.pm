package Slim::Player::ProtocolHandlers;
my %H;
sub handlerForURL { return $H{handler} }
sub _setTestHandler { $H{handler} = $_[1] }
1;
