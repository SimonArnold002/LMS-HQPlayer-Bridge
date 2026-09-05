package Slim::Utils::Strings;
# Stub: the real one resolves a token against strings.txt for the client's
# language.  Offline there is no string table, so cstring returns the token -
# which is what makes an assertion on a feed row readable.
use Exporter 'import';
our @EXPORT_OK = qw(cstring string);
sub cstring { my (undef, $token) = @_; return $token }
sub string  { my ($token) = @_; return $token }
1;
