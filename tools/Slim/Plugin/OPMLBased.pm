package Slim::Plugin::OPMLBased;
# Stub: OPMLBased extends Base and adds the app/menu registration.  The real
# one registers a CLI dispatch and a Jive/Material menu entry; nothing offline
# needs that, only that initPlugin accepts the arguments and does not die.
use base qw(Slim::Plugin::Base);
our %INIT_ARGS;
sub initPlugin { my ($class, %args) = @_; $INIT_ARGS{$class} = \%args; return; }
sub shutdownPlugin {}
1;
