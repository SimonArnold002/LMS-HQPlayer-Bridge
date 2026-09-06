package Slim::Control::Request;
use strict; use warnings;

sub subscribe {} sub unsubscribe {} sub notifyFromArray {} sub addDispatch {}

# executeRequest is how nowPlayingFor reads the player's status. The stub hands
# back whatever the test staged, so the REAL resolution logic (remoteMeta
# fallbacks, the artwork order, the negative-coverid rule) is what gets
# exercised - not a re-statement of it.
#
# $ERROR lets a test drive the failure branch, which must yield an empty
# snapshot rather than a set of blank strings.
our $RESULTS = {};
our $ERROR   = 0;
our @CALLS;

sub executeRequest {
    my ( $client, $args ) = @_;
    push @CALLS, $args;
    return bless { }, __PACKAGE__;
}

sub isStatusError { return $ERROR }
sub getResults    { return $RESULTS }

sub _reset { $RESULTS = {}; $ERROR = 0; @CALLS = (); return }

1;
