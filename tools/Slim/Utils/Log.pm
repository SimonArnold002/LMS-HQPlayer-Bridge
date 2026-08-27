package Slim::Utils::Log;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(logger);
sub addLogCategory { return __PACKAGE__->_l }
sub logger { return __PACKAGE__->_l }
sub _l { my $o = bless {}, 'Slim::Utils::Log::Obj'; return $o }
package Slim::Utils::Log::Obj;
sub is_debug {0} sub is_info {0} sub is_warn {1}
sub debug {} sub info {} sub warn {} sub error {}
1;
