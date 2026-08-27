package Slim::Utils::Prefs;
use strict; use warnings;
use Exporter 'import';
our @EXPORT = qw(preferences);
sub preferences { return bless {}, 'Slim::Utils::Prefs::Obj' }
package Slim::Utils::Prefs::Obj;
sub get {} sub set {} sub setPlayerDefault {} sub init {} sub setChange {}
1;
