package Slim::Networking::SimpleAsyncHTTP;
# Records requests instead of making them; a test drives the callback itself.
our @REQ;
sub new { my ($c,$cb,$ecb,$p)=@_; return bless { cb=>$cb, ecb=>$ecb, p=>$p||{} }, $c }
sub get { my ($s,$url)=@_; push @REQ, { url=>$url, %{$s->{p}}, cb=>$s->{cb}, ecb=>$s->{ecb} }; return $s }
sub _reset { @REQ = () }
1;
