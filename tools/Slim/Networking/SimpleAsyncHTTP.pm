package Slim::Networking::SimpleAsyncHTTP;
sub new { my $c=shift; return bless { cb=>$_[0], ecb=>$_[1], p=>$_[2] }, $c }
sub get {} sub post {} sub content {''}
1;
