package Slim::Utils::Timers;
# A real enough scheduler for the tests: LMS's setTimer($obj, $when, $cb, @args)
# calls $cb->($obj, @args) - the object comes back as the FIRST argument, which
# is what every stepper in this plugin relies on.
use strict; use warnings;

my @timers;   # { obj, when, cb, args }

sub setTimer {
    my ( $obj, $when, $cb, @args ) = @_;
    push @timers, { obj => $obj, when => $when, cb => $cb, args => \@args };
    return $cb;
}

sub setHighTimer { goto &setTimer }

sub killTimers {
    my ( $obj, $cb ) = @_;
    my $before = @timers;
    @timers = grep {
        !( ( !defined $obj || ( defined $_->{obj} && $_->{obj} == $obj ) )
           && ( !defined $cb || $_->{cb} == $cb ) )
    } @timers;
    return $before - @timers;
}

# --- test helpers ----------------------------------------------------------
sub _pending  { return scalar @timers }
sub _timers   { return [@timers] }
sub _reset    { @timers = (); return }

# Fire every pending timer, earliest first, regardless of its due time.
sub _fireAll {
    my $n = 0;
    while ( my @due = sort { $a->{when} <=> $b->{when} } @timers ) {
        my $t = shift @due;
        @timers = @due;
        $t->{cb}->( $t->{obj}, @{ $t->{args} } );
        last if ++$n > 100;   # a stepper that reschedules forever
    }
    return $n;
}

1;
