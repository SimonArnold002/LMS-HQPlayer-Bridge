package Slim::Utils::Timers;
# A real enough scheduler for the tests: LMS's setTimer($obj, $when, $cb, @args)
# calls $cb->($obj, @args) - the object comes back as the FIRST argument, which
# is what every stepper in this plugin relies on.
use strict; use warnings;

my @timers;   # { obj, when, cb, args }

# LMS keys a timer on its object, and turns an undef object into '' - in
# _makeTimer, killTimers and firePendingTimer alike (8.0-9.1). So undef is ONE
# key, not a wildcard: killTimers(undef, $cb) kills only timers SET with undef,
# and the callback gets '' back. Matched here, or a test passes that LMS fails.
sub setTimer {
    my ( $obj, $when, $cb, @args ) = @_;
    $obj = '' unless defined $obj;
    push @timers, { obj => $obj, when => $when, cb => $cb, args => \@args };
    return $cb;
}

sub setHighTimer { goto &setTimer }

sub killTimers {
    my ( $obj, $cb ) = @_;
    return 0 unless $cb;                  # LMS: no sub, nothing killed
    $obj = '' unless defined $obj;
    my $before = @timers;
    @timers = grep { !( $_->{cb} == $cb && _same( $_->{obj}, $obj ) ) } @timers;
    return $before - @timers;
}

# LMS compares the object as a hash key, i.e. by its stringified form.
sub _same { return "$_[0]" eq "$_[1]" }

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
