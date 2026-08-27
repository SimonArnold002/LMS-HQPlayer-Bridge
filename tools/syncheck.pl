#!/usr/bin/perl
use strict; use warnings;
BEGIN {
    package main;
    use constant DEBUGLOG => 0;
    use constant INFOLOG  => 0;
    use constant WEBUI    => 1;
    use constant SLIM_SERVICE => 0;
    use constant ISWINDOWS => 0;
}
my $mod = shift or die "usage: syncheck.pl Module::Name\n";
eval "require $mod; 1" or do { print "FAIL $mod\n$@\n"; exit 1 };
print "OK   $mod\n";
