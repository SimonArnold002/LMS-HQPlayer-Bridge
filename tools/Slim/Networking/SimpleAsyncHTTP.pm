package Slim::Networking::SimpleAsyncHTTP;
# Records requests instead of making them; a test drives the callback itself.
our @REQ;
sub new { my ($c,$cb,$ecb,$p)=@_; return bless { cb=>$cb, ecb=>$ecb, p=>$p||{} }, $c }
sub get { my ($s,$url)=@_; push @REQ, { method=>'GET', url=>$url, %{$s->{p}}, cb=>$s->{cb}, ecb=>$s->{ecb} }; return $s }
# LMS's post: ($url, header => value ..., $body) - an odd count means the last is the body
sub post { my ($s,$url,@a)=@_; my $body = @a % 2 ? pop @a : undef;
  push @REQ, { method=>'POST', url=>$url, headers=>{@a}, body=>$body, %{$s->{p}}, cb=>$s->{cb}, ecb=>$s->{ecb} }; return $s }
sub _reset { @REQ = () }
1;
