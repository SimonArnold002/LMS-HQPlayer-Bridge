package Slim::Utils::Accessor;
# Faithful-enough stand-in for LMS's accessor base.  The important property,
# and the whole reason this stub exists, is that objects are BLESSED ARRAYS
# with numbered slots - so $obj->{field} dies exactly as it does on a real
# server, instead of silently working and hiding the bug until runtime.
use strict; use warnings;
my %SLOTS;   # class => { field => index }
my %NEXT;    # class => next free index

sub new { my $class = shift; return bless [], $class }

sub _slotFor {
    my ($class, $field) = @_;
    for my $c (_isaChain($class)) { return $SLOTS{$c}{$field} if exists $SLOTS{$c}{$field} }
    return undef;
}
sub _isaChain {
    my $class = shift; my @out = ($class);
    no strict 'refs';
    push @out, _isaChain($_) for @{"${class}::ISA"};
    return @out;
}
sub _nextSlot {
    my $class = shift;
    my $max = 0;
    for my $c (_isaChain($class)) { $max = $NEXT{$c} if ($NEXT{$c}||0) > $max }
    return $max;
}

sub mk_accessor {
    my ($class, $type, @fields) = @_;
    shift @fields if $type =~ /default/;      # skip the default value
    my $n = _nextSlot($class);
    no strict 'refs';
    for my $f (@fields) {
        my $slot = $n++;
        $SLOTS{$class}{$f} = $slot;
        *{"${class}::${f}"} = sub {
            return $_[0]->[$slot] if @_ == 1;
            return $_[0]->[$slot] = $_[1] if @_ == 2;
        };
    }
    $NEXT{$class} = $n;
    return 1;
}

sub init_accessor {
    my $self = shift;
    while (@_) { my ($f,$v) = (shift, shift); $self->$f($v) }
    return $self;
}
1;
