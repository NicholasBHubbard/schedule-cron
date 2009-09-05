#!perl -w

use strict;
use warnings;
use Test::More;
use Schedule::Cron;

plan tests => 3;

my @refs = ( 
            [ "MET", 1256432100, 1256436000],
            [ "Europe/Berlin", 1256432100, 1256436000],
            [ "PST8PDT", 1257065700, 1257062400]
           );

my $cron = new Schedule::Cron(sub { });

for my $r (@refs) {
    $ENV{TZ} = $r->[0];
    my $next = $cron->get_next_execution_time("0-59/5 * * * *",$r->[1]);
    is($next,$r->[2],"Expected time for " . $r->[0] . "( Ref: " . scalar(localtime($r->[1])) . ", Calc: " . scalar(localtime($next)));
}

