#!perl -w

use strict;
use warnings;
use Test::More;

eval { require Time::Mock };
if( $@ ) {
    plan skip_all => 'Time::Mock not installed';
}
else {
    plan tests => 1;
}

# TODO: Test for checking, whether Scheduling in the DST back flip works
ok(1);
