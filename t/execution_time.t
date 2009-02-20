#!perl -w

use Test::More;
use Schedule::Cron;
use Time::ParseDate;

my $time;

while (defined($_=<DATA>) && $_ !~ /end/i) {
  chomp;
  if (/^Reftime:\s*(.*)$/) {
    $time = $1;
    $time =~ s/\#.*$//;
    $time = parsedate($time,UK=>1);
    next;
  }
  s/^\s*(.*)\s*/$1/;
  next if /^\#/ || /^$/;
  my @args = split(/\s+/,$_,6);
  my $date;

  my $rest = pop @args;
  my ($col6,$more_args) = split(/\s+/,$rest,2);
  if ($col6 =~ /^[\d\-\*\,\/]+$/)
  {
      push @args,$col6;
      $date = $more_args;
  }
  else
  {
      $date = $rest;
  }

  push @entries,[$time, \@args];
  my $res_date = parsedate($date,UK=>1);
  die "Internal error" unless $res_date;
  push @results,$res_date;
}

my $cron = new Schedule::Cron(sub {});

plan tests => scalar(@entries);

my $i;
for ($i=0;$i<=$#entries;$i++) 
{
    my $t = $cron->get_next_execution_time($entries[$i]->[1],$entries[$i]->[0]);
    print "# Cron-Entry: ",join(" ",@{$entries[$i]->[1]}),"\n";
    print "# Ref-Time:   ",scalar(localtime($entries[$i]->[0])),"\n";
    print "# Calculated: ",scalar(localtime($t)),"\n";
    print "# Expected:   ",scalar(localtime($results[$i])),"\n";
    ok($t == $results[$i]);
} 
__DATA__
Reftime: Mon Dec 27 20:14:14 1999

# Minutes:
# ========

      *      *     *     *     *     0      20:15 27/12/1999 Monday
     20      *     *     *     *            20:20 27/12/1999 Monday
  10-50      *     *     *     *            20:15 27/12/1999 Monday
13-30/4      *     *     *     *            20:17 27/12/1999 Monday
     10      *     *     *     *            21:10 27/12/1999 Monday
  18,20      *     *     *     *            20:18 27/12/1999 Monday

# Hours:
# ======

     *      21     *     *     *            21:00 27/12/1999 Monday
     *      19     *     *     *            19:00 28/12/1999 Tuesday
     * 10-23/5     *     *     *            20:15 27/12/1999 Monday
     * 10-23/7     *     *     *            10:00 28/12/1999 Tuesday

# Days-of-Month:
# ==============

        *        *       29        2        *         00:00 29/02/2000 Tuesday
       23        4  23-30/3        *        *         04:23 29/12/1999 Wednesday
       12       21       27        *        *         21:12 27/12/1999 Monday
       12       19       27        *        *         19:12 27/01/2000 Thursday
        *       18  21,15,8        *        *         18:00 08/01/2000 Saturday

# Months:
# =======

       *        *        *       11        *         00:00 01/11/2000 Wednesday
       *        *        *       12        *         20:15 27/12/1999 Monday
       *        *        *        0        *         00:00 01/01/2000 Saturday
      42        0        4  Jan-Dec        *         00:42 04/01/2000 Tuesday
      42       21        4 Jan-Dec/2       *         21:42 04/01/2000 Tuesday
      42       21        * Feb-Dec/2       *         21:42 27/12/1999 Monday
      42       19        * Feb-Dec/2       *         19:42 28/12/1999 Tuesday
      42       19       27 Feb-Dec/2       *         19:42 27/02/2000 Sunday

# Days-of-Week:
# =============

       14       15        *  Dec,Jan        0         15:14 02/01/2000 Sunday
       14       15        *  Dec,Jan        7         15:14 02/01/2000 Sunday
        0       12        *        *  Mon-Fri         12:00 28/12/1999 Tuesday
        *        *        *        *      Mon         20:15 27/12/1999 Monday
        0       21        *        *      Mon         21:00 27/12/1999 Monday
        0       19        *        *      Mon         19:00 03/01/2000 Monday
       13       14        *        * Sun-Sat/2        14:13 28/12/1999 Tuesday

# Seconds
      *      *     *     *     *   *        20:14:15 27/12/1999 Monday
      *      *     *     *     *   5-10     20:15:05 27/12/1999 Monday
      *      *     *     *     *   13-30/4  20:14:17 27/12/1999 Monday
      *      *     *     *     *   18       20:14:18 27/12/1999 Monday
 
# Horrible combinations ;-):
# ==========================

        0       21       27        *      Wed         21:00 27/12/1999 Monday
        0       19       27        *      Wed         19:00 29/12/1999 Wednesday
        0    19,21       27        *      Wed         21:00 27/12/1999 Monday
20-30/5,17   19,21       27        *      Wed         21:17 27/12/1999 Monday

# Check for parsedate-normalization
# (thanx to Lars Holokowo)
# =================================

        1        3       30        6        *         03:01 30/06/2000 Monday
        0       03       30        6        *         03:00 30/06/2000 Monday
       00        3       30        6        *         03:00 30/06/2000 Monday
        0        3       30        6        *         03:00 30/06/2000 Monday

# Bug reported by Loic Paillotin
# ==============================
        5,10,25,30,35,40,45,50,55 *   *  * 	*         20:25 27/12/1999 Monday
	    5,10,25,30,35,40,45,50,55 * * * *             20:25 27/12/1999 Monday
        */5                       *   *  * 	*         20:15 27/12/1999 Monday

end










