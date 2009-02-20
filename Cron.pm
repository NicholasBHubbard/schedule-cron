#!/usr/bin/perl -w

# $Id: Cron.pm,v 1.16 2006/11/27 13:42:52 roland Exp $

=head1 NAME

Cron - cron-like scheduler for Perl subroutines

=head1 SYNOPSIS

  use Schedule::Cron;

  # Subroutines to be called
  sub dispatcher { 
    print "ID:   ",shift,"\n"; 
    print "Args: ","@_","\n";
  }

  sub check_links { 
    # do something... 
  }

  # Create new object with default dispatcher
  my $cron = new Schedule::Cron(\&dispatcher);

  # Load a crontab file
  $cron->load_crontab("/var/spool/cron/perl");

  # Add dynamically  crontab entries
  $cron->add_entry("3 4  * * *",ROTATE => "apache","sendmail");
  $cron->add_entry("0 11 * * Mon-Fri",\&check_links);

  # Run scheduler 
  $cron->run(detach=>1);
                   

=head1 DESCRIPTION

This module provides a simple but complete cron like scheduler.  I.e this
modules can be used for periodically executing Perl subroutines.  The dates and
parameters for the subroutines to be called are specified with a format known
as crontab entry (L<"METHODS">, C<add_entry()> and L<crontab(5)>)

The philosophy behind C<Schedule::Cron> is to call subroutines periodically
from within one single Perl program instead of letting C<cron> trigger several
(possibly different) perl scripts. Everything under one roof.  Furthermore
C<Schedule::Cron> provides mechanism to create crontab entries dynamically,
which isn't that easy with C<cron>.

C<Schedule::Cron> knows about all extensions (well, at least all extensions I'm
aware of, i.e those of the so called "Vixie" cron) for crontab entries like
ranges including 'steps', specification of month and days of the week by name
or coexistence of lists and ranges in the same field.  And even a bit more
(like lists and ranges with symbolic names).

=head1 METHODS

=over 4

=cut

#'

package Schedule::Cron;

use Time::ParseDate;
use Data::Dumper;

use strict;
use vars qw($VERSION  $DEBUG);
use subs qw(dbg);

my $HAS_POSIX;

BEGIN {
  eval { 
    require POSIX;
    import POSIX ":sys_wait_h";
  };
  $HAS_POSIX = $@ ? 0 : 1;
}


$VERSION = 0.97;

our $DEBUG = 0;
my %STARTEDCHILD = ();

my @WDAYS = qw(
                 Sunday
                 Monday
                 Tuesday
                 Wednesday
                 Thursday
                 Friday
                 Saturday
                 Sunday
                );

my @ALPHACONV = (
                 { },
                 { },
                 { },
                 { qw(jan 1 feb 2 mar 3 apr 4 may 5 jun 6 jul 7 aug 8
                      sep 9 oct 10 nov 11 dec 12) },
                 { qw(sun 0 mon 1 tue 2 wed 3 thu 4 fri 5 sat 6)},
                 {  }
                );
my @RANGES = ( 
              [ 0,59 ],
              [ 0,23 ],
              [ 0,31 ],
              [ 0,12 ],
              [ 0,7  ],
              [ 0,60 ]
             );

my @LOWMAP = ( 
              {},
              {},
              { 0 => 1},
              { 0 => 1},
              { 7 => 0},
              {},
             );

sub REAPER {
    if ($HAS_POSIX)
    {
        # Only on platforms supporting POSIX semantisc
        foreach my $pid (keys %STARTEDCHILD) {
            my $res = $HAS_POSIX ? waitpid($pid, WNOHANG) : waitpid($pid,0);
            if ($res > 0) {
                # We reaped a truly running process
                delete $STARTEDCHILD{$pid};
            }
        }
    } 
    else
    {
        my $waitedpid = 0;
        while($waitedpid != -1) {
            $waitedpid = wait;
        }
    }
}

=item $cron = new Schedule::Cron($dispatcher,[extra args])

Creates a new C<Cron> object.  C<$dispatcher> is a reference to a subroutine,
which will be called by default.  C<$dispatcher> will be invoked with the
arguments parameter provided in the crontab entry if no other subroutine is
specified. This can be either a single argument containing the argument
parameter literally has string (default behavior) or a list of arguments when
using the C<eval> option described below.

The date specifications must be either provided via a crontab like file or
added explicitly with C<add_entry()> (L<"add_entry">).

I<extra_args> can be a hash or hash reference for additional arguments.  The
following parameters are recognized:

=over

=item file => <crontab>  


Load the crontab entries from <crontab>

=item eval =>  1

Eval the argument parameter in a crontab entry before calling the subroutine
(instead of literally calling the dispatcher with the argument parameter as
string)

=item nofork => 1

Don't fork when starting the scheduler. Instead, the jobs are executed within
current process. In your executed jobs, you have full access to the global
variables of your script and hence might influence other jobs running at a
different time. This behaviour is fundamentally different to the 'fork' mode,
where each jobs gets its own process and hence a B<copy> of the process space,
independent of each other job and the main process. This is due to the nature
of the  C<fork> system call. 

=item skip => 1

Skip any pending jobs whose time has passed. This option is only useful in
combination with C<nofork> where a job might block the execution of the
following jobs for quite some time. By default, any pending job is executed
even if its scheduled execution time has already passed. With this option set
to true all pending which would have been started in the meantime are skipped. 

=item catch => 1

Catch any exception raised by a job. This is especially useful in combination with
the C<nofork> option to avoid stopping the main process when a job raises an
exception (dies).

=item log => \&log_sub

Install a logging subroutine. The given subroutine is called for several events
during the lifetime of a job. This method is called with two arguments: A log
level of 0 (info),1 (warning) or 2 (error) depending on the importance of the
message and the message itself.

For example, you could use I<Log4Perl> (L<http://log4perl.sf.net>) for logging
purposes for example like in the following code snippet:

   use Log::Log4perl;
   use Log::Log4perl::Level;

   my $log_method = sub {
      my ($level,$msg) = @_;
      my $DBG_MAP = { 0 => $INFO, 1 => $WARN, 2 => $ERROR };

      my $logger = Log::Log4Perl->get_logger("My::Package");
      $logger->log($DBG_MAP->{$level},$msg);
   }
  
   my $cron = new Schedule::Cron(.... , log => $log_method);

=item processprefix => <name>

Cron::Schedule sets the process' name (i.e. C<$0>) to contain some informative
messages like when the next job executes or with which arguments a job is
called. By default, the prefix for this labels is C<Schedule::Cron>. With this
option you can set it to something different. You can e.g. use C<$0> to include
the original process name.

=back

=cut

sub new 
{
    my $class = shift;
    my $dispatcher = shift || die "No dispatching sub provided";
    die "Dispatcher not a ref to a subroutine" unless ref($dispatcher) eq "CODE";
    my $cfg = ref($_[0]) eq "HASH" ? $_[0] : {  @_ };
    $cfg->{processprefix} = "Schedule::Cron" unless $cfg->{processprefix};
    my $self = { 
                cfg => $cfg,
                dispatcher => $dispatcher,
                queue => [ ],
                map => { }
             };
    bless $self,(ref($class) || $class);
    
    $self->load_crontab if $cfg->{file};
    $self;
}

=item $cron->load_crontab($file)

=item $cron->load_crontab(file=>$file,[eval=>1])

Loads and parses the crontab file C<$file>. The entries found in this file will
be B<added> to the current time table with C<$cron-E<gt>add_entry>.

The format of the file consists of cron commands containing of lines with at
least 5 columns, whereas the first 5 columns specify the date.  The rest of the
line (i.e columns 6 and greater) contains the argument with which the
dispatcher subroutine will be called.  By default, the dispatcher will be
called with one single string argument containing the rest of the line
literally.  Alternatively, if you call this method with the optional argument
C<eval=E<gt>1> (you must then use the second format shown above), the rest of
the line will be evaled before used as argument for the dispatcher.

For the format of the first 5 columns, please see L<"add_entry">.

Blank lines and lines starting with a C<#> will be ignored. 

There's no way to specify another subroutine within the crontab file.  All
calls will be made to the dispatcher provided at construction time.

If    you   want    to    start   up    fresh,    you   should    call
C<$cron-E<gt>clean_timetable()> before.

Example of a crontab fiqw(le:)

   # The following line runs on every Monday at 2:34 am
   34 2 * * Mon  "make_stats"
   # The next line should be best read in with an eval=>1 argument
   *  * 1 1 *    { NEW_YEAR => '1',HEADACHE => 'on' }

=cut

#'

sub load_crontab 
{
  my $self = shift;
  my $cfg = shift;

  if ($cfg) 
  {
      if (@_) 
      {
          $cfg = ref($cfg) eq "HASH" ? $cfg : { $cfg,@_ };
      } 
      elsif (!ref($cfg)) 
      {
          my $new_cfg = { };
          $new_cfg->{file} = $cfg;
          $cfg = $new_cfg;
      }
  }
  
  my $file = $cfg->{file} || $self->{cfg}->{file} || die "No filename provided";
  my $eval = $cfg->{eval} || $self->{cfg}->{eval};
  
  open(F,$file) || die "Cannot open schedule $file : $!";
  my $line = 0;
  while (<F>) 
  {
      $line++;
      next if /^$/;
      next if /^\s*#/;
      chomp;
      s/\s*(.*)\s*$/$1/;
      my ($min,$hour,$dmon,$month,$dweek,$rest) = split (/\s+/,$_,6);
      
      my $time = [ $min,$hour,$dmon,$month,$dweek ];

      # Try to check, whether an optional 6th column specifying seconds 
      # exists: 
      my $args;
      if ($rest)
      {
          my ($col6,$more_args) = split(/\s+/,$rest,2);
          if ($col6 =~ /^[\d\-\*\,\/]+$/)
          {
              push @$time,$col6;
              dbg "M: $more_args";
              $args = $more_args;
          }
          else
          {
              $args = $rest;
          }
      }
      $self->add_entry($time,{ 'args' => $args, 'eval' => $eval});
  }
  close F;
}

=item $cron->add_entry($timespec,[arguments])

Adds a new entry to the list of scheduled cron jobs.

B<Time and Date specification>

C<$timespec> is the specification of the scheduled time in crontab format
(L<crontab(5)>) which contains five mandatory time and date fields and an
optional 6th column. C<$timespec> can be either a plain string, which contains
a whitespace separated time and date specification.  Alternatively,
C<$timespec> can be a reference to an array containing the five elements for
the date fields.

The time and date fields are (taken mostly from L<crontab(5)>, "Vixie" cron): 

   field          values
   =====          ======
   minute         0-59
   hour           0-23
   day of month   1-31 
   month          1-12 (or as names)
   day of week    0-7 (0 or 7 is Sunday, or as names )
   seconds        0-59 (optional)

 A field may be an asterisk (*), which always stands for
 ``first-last''.

 Ranges of numbers are  allowed.  Ranges are two numbers
 separated  with  a  hyphen.   The  specified  range  is
 inclusive.   For example, 8-11  for an  ``hours'' entry
 specifies execution at hours 8, 9, 10 and 11.

 Lists  are allowed.   A list  is a  set of  numbers (or
 ranges)  separated by  commas.   Examples: ``1,2,5,9'',
 ``0-4,8-12''.

 Step  values can  be used  in conjunction  with ranges.
 Following a range with ``/<number>'' specifies skips of
 the  numbers value  through the  range.   For example,
 ``0-23/2'' can  be used in  the hours field  to specify
 command execution every  other hour (the alternative in
 the V7 standard is ``0,2,4,6,8,10,12,14,16,18,20,22'').
 Steps are  also permitted after an asterisk,  so if you
 want to say ``every two hours'', just use ``*/2''.

 Names can also  be used for the ``month''  and ``day of
 week''  fields.  Use  the  first three  letters of  the
 particular day or month (case doesn't matter).

 Note: The day of a command's execution can be specified
       by two fields  -- day of month, and  day of week.
       If both fields are restricted (ie, aren't *), the
       command will be run when either field matches the
       current  time.  For  example, ``30  4 1,15  * 5''
       would cause a command to be run at 4:30 am on the
       1st and 15th of each month, plus every Friday

Examples:

 "8  0 * * *"         ==> 8 minutes after midnight, every day
 "5 11 * * Sat,Sun"   ==> at 11:05 on each Saturday and Sunday
 "0-59/5 * * * *"     ==> every five minutes
 "42 12 3 Feb Sat"    ==> at 12:42 on 3rd of February and on 
                          each Saturday in February
 "32 11 * * * 0-30/2" ==> 11:32:00, 11:32:02, ... 11:32:30 every 
                          day

In addition, ranges or lists of names are allowed. 

An optional sixth column can be used to specify the seconds within the
minute. If not present, it is implicitely set to "0".

B<Command specification>

The subroutine to be executed when the the C<$timespec> matches can be
specified in several ways.

First, if the optional C<arguments> are lacking, the default dispatching
subroutine provided at construction time will be called without arguments.

If the second parameter to this method is a reference to a subroutine, this
subroutine will be used instead of the dispatcher.

Any additional parameters will be given as arguments to the subroutine to be
executed.  You can also specify a reference to an array instead of a list of
parameters.

You can also use a named parameter list provided as an hashref.  The named
parameters recognized are:

=over

=item subroutine      

=item sub 

Reference to subroutine to be executed

=item arguments

=item args

Reference to array containing arguments to be use when calling the subroutine

=item eval

If true, use the evaled string provided with the C<arguments> parameter.  The
evaluation will take place immediately (not when the subroutine is going to be
called)

=back

Examples:

   $cron->add_entry("* * * * *");
   $cron->add_entry("* * * * *","doit");
   $cron->add_entry("* * * * *",\&dispatch,"first",2,"third");
   $cron->add_entry("* * * * *",{'subroutine' => \&dispatch,
                                 'arguments'  => [ "first",2,"third" ]});
   $cron->add_entry("* * * * *",{'subroutine' => \&dispatch,
                                 'arguments'  => '[ "first",2,"third" ]',
                                 'eval'       => 1});

=cut 

sub add_entry 
{ 
    my $self = shift;
    my $time = shift;
    my $args = shift || []; 
    my $dispatch;
    
    #  dbg "Args: ",Dumper($time,$args);
    
    if (ref($args) eq "HASH") 
    {
        my $cfg = $args;
        $args = undef;
        $dispatch = $cfg->{subroutine} || $cfg->{sub};
        $args = $cfg->{arguments} || $cfg->{args} || [];
        if ($cfg->{eval} && $cfg) 
        {
            die "You have to provide a simple scalar if using eval" if (ref($args));
            my $orig_args = $args;
            dbg "Evaled args ",Dumper($args);
            $args = [ eval $args ];
            die "Cannot evaluate args (\"$orig_args\")"
              if $@;
        }
    } 
    elsif (ref($args) eq "CODE") 
    {
        $dispatch = $args;
        $args = shift || [];
    }
    if (ref($args) ne "ARRAY") 
    {
        $args = [ $args,@_ ];
    }

    $dispatch ||= $self->{dispatcher};


    my $time_array = ref($time) ? $time : [ split(/\s+/,$time) ];
    die "Invalid number of columns in time entry (5 or 6)\n"
      if ($#$time_array != 4 && $#$time_array !=5);
    $time = join ' ',@$time_array;

    #  dbg "Adding ",Dumper($time);
    push @{$self->{time_table}},
    {
     time => $time,
     dispatcher => $dispatch,
     args => $args
    };
    
    $self->{entries_changed} = 1;
    #  dbg "Added Args ",Dumper($self->{args});
    
    my $index = $#{$self->{time_table}};
    my $id = $args->[0];
    $self->{map}->{$id} = $index if $id;
    
    return $#{$self->{time_table}};
}

=item @entries = $cron->list_entries()

Return a list of cron entries. Each entry is a hash reference of the following
form:

  $entry = { 
             time => $timespec,
             dispatch => $dispatcher,
             args => $args_ref
           }

Here C<$timespec> is the specified time in crontab format as provided to
C<add_entry>, C<$dispatcher> is a reference to the dispatcher for this entry
and C<$args_ref> is a reference to an array holding additional arguments (which
can be an empty array reference). For further explanation of this arguments
refer to the documentation of the method C<add_entry>.

The order index of each entry can be used within C<update_entry>, C<get_entry>
and C<delete_entry>. But be aware, when you are deleting an entry, that you
have to refetch the list, since the order will have changed.

Note that these entries are returned by value and were opbtained from the
internal list by a deep copy. I.e. you are free to modify it, but this won't
influence the original entries. Instead use C<update_entry> if you need to
modify an exisiting crontab entry.

=cut

sub list_entries
{
    my ($self) = shift;
    
    my @ret;
    foreach my $entry (@{$self->{time_table}})
    {
        # Deep copy $entry
        push @ret,$self->deep_copy_entry($entry);
    }
    return @ret;
}


=item $entry = $cron->get_entry($idx)

Get a single entry. C<$entry> is either a hashref with the possible keys
C<time>, C<dispatch> and C<args> (see C<list_entries()>) or undef if no entry
with the given index C<$idx> exists.

=cut

sub get_entry
{
    my ($self,$idx) = @_;

    my $entry = $self->{time_table}->[$idx];
    if ($entry)
    {
        return $self->deep_copy_entry($entry);
    }
    else
    {
        return undef;
    }
}

=item $cron->delete_entry($idx)

Delete the entry at index C<$idx>. Returns the deleted entry on success,
C<undef> otherwise.

=cut

sub delete_entry
{
    my ($self,$idx) = @_;

    if ($idx <= $#{$self->{time_table}})
    {
        $self->{entries_changed} = 1;
        return splice @{$self->{time_table}},$idx,1;
    }
    else
    {
        return undef;
    }
}

=item $cron->update_entry($idx,$entry)

Updates the entry with index C<$idx>. C<$entry> is a hash ref as descibed in
C<list_entries()> and must contain at least a value C<$entry->{time}>. If no
C<$entry->{dispatcher}> is given, then the default dispatcher is used.  This
method returns the old entry on success, C<undef> otherwise.

=cut 

sub update_entry
{
    my ($self,$idx,$entry) = @_;

    die "No update entry given" unless $entry;
    die "No time specification given" unless $entry->{time};
    
    if ($idx <= $#{$self->{time_table}})
    {
        my $new_entry = $self->deep_copy_entry($entry);
        $new_entry->{dispatcher} = $self->{dispatcher} 
          unless $new_entry->{dispatcher};
        $new_entry->{args} = []
          unless $new_entry->{args};
        return splice @{$self->{time_table}},$idx,1,$new_entry;
    }
    else
    {
        return undef;
    }
}

=item $cron->run([options])

This method starts the scheduler.

When called without options, this method will never return and executes the
scheduled subroutine calls as needed.

Alternatively, you can detach the main scheduler loop from the current process
(daemon mode). In this case, the pid of the forked scheduler process will be
returned.

The C<options> parameter specifies the running mode of C<Schedule::Cron>.  It
can be either a plain list which will be interpreted as a hash or it can be a
reference to a hash. The following named parameters (keys of the provided hash)
are recognized:

=over

=item   detach    

If set to a true value the scheduler process is detached from the current
process (UNIX only).

=item  pid_file  

If running in daemon mode, name the optional file, in which the process id of
the scheduler process should be written. By default, no PID File will be
created.

=item nofork, skip, catch, log

See C<new()> for a description of these configuration parameters, which can be
provided here as well. Note, that the options given here overrides those of the
constructor.

=back


Examples:

   # Start  scheduler, detach  from current  process and
   # write  the  PID  of  the forked  scheduler  to  the
   # specified file
   $cron->run(detach=>1,pid_file=>"/var/run/scheduler.pid");

   # Start scheduler and wait forever.
   $cron->run();

=cut

sub run 
{ 
    my $self = shift;
    my $cfg = ref($_[0]) eq "HASH" ? $_[0] : {  @_ };
    $cfg = { %{$self->{cfg}}, %$cfg }; # Merge in global config;

    my $log = $cfg->{log};

    $self->build_initial_queue;
    delete $self->{entries_changed};
    die "Nothing in schedule queue" unless @{$self->{queue}};
    
    # Install reaper now.
    my $old_child_handler = $SIG{'CHLD'};
    $SIG{'CHLD'} = sub {
        &REAPER();
        if ($old_child_handler && ref $old_child_handler eq 'CODE')
        {
            &$old_child_handler();
        }
    };

    my $mainloop = sub 
    {
        while (42) 
        {
            my ($index,$time) = @{shift @{$self->{queue}}};
            my $now = time;
            my $sleep = 0;
            if ($time < $now)
            {
                if ($cfg->{skip})
                {
                    $log->(0,"Schedule::Cron - Skipping job $index")
                      if $log;
                    $self->update_queue($index);
                    next;
                }
            }
            else
            {
                $sleep = $time - $now;
            }
            $0 = $self->get_process_prefix()." MainLoop - next: ".scalar(localtime($time));
            die "No time found\n" unless $time;

            dbg "R: sleep = $sleep | ",scalar(localtime($time))," (",scalar(localtime($now)),")";
            while ($sleep > 0) 
            {
                sleep($sleep);
                $sleep = $time - time;
            }

            $self->execute($index,$cfg);

            if ($self->{entries_changed}) {
               dbg "rebuilding queue";
               $self->build_initial_queue;
               delete $self->{entries_changed};
            } else {
               $self->update_queue($index);
            }
        } 
    };

    if ($cfg->{detach}) 
    {
        defined(my $pid = fork) or die "Can't fork: $!";
        if ($pid) 
        {
            # Parent:
            if ($cfg->{pid_file}) 
            {
                if (open(P,">".$cfg->{pid_file})) 
                {
                    print P $pid,"\n";
                    close P;
                } 
                else 
                {
                    warn "Warning: Cannot open ",$cfg->{pid_file}," : $!\n";
                }
                
            }
            return $pid;
        } 
        else 
        {
            # Child:
            # Try to detach from terminal:
            chdir '/';
            open STDIN, '/dev/null' or die "Can't read /dev/null: $!";
            open STDOUT, '>/dev/null' or die "Can't write to /dev/null: $!";
            
            eval { require POSIX; };
            if ($@) 
            {
                #      if (1) {
                if (open(T,"/dev/tty")) 
                {
                    dbg "No setsid found, trying ioctl() (Error: $@)";
                    eval { require 'ioctl.ph'; };
                    if ($@) 
                    {
                        eval { require 'sys/ioctl.ph'; };
                        if ($@) 
                        {
                            die "No 'ioctl.ph'. Probably you have to run h2ph (Error: $@)";
                        }
                    }
                    my $notty = &TIOCNOTTY;
                    die "No TIOCNOTTY !" if $@ || !$notty;
                    ioctl(T,$notty,0) || die "Cannot issue ioctl(..,TIOCNOTTY) : $!";
                    close(T);
                };
            } 
            else 
            {
                &POSIX::setsid() || die "Can't start a new session: $!";
            }
            open STDERR, '>&STDOUT' or die "Can't dup stdout: $!";
            
            $0 = $self->get_process_prefix()." MainLoop";
            &$mainloop();
        }
    } 
    else 
    {
        &$mainloop(); 
    }
}


=item $cron->clean_timetable()

Remove all scheduled entries

=cut

sub clean_timetable 
{ 
    my $self = shift;
    $self->{entries_changed} = 1;
    $self->{time_table} = [];
}


=item $cron->check_entry($id)

Check, whether the given ID is already registered in the timetable. 
A ID is the first argument in the argument parameter of the 
a crontab entry.

Returns (one of) the index in the  timetable (can be 0, too) if the ID
could be found or C<undef> otherwise.

Example:

   $cron->add_entry("* * * * *","ROTATE");
   .
   .
   defined($cron->check_entry("ROTATE")) || die "No ROTATE entry !"

=cut 

sub check_entry 
{ 
    my $self = shift;
    my $id = shift;
    return $self->{map}->{$id};
}


=item $cron->get_next_execution_time($cron_entry,[$ref_time])

Well, this is mostly an internal method, but it might be useful on 
its own. 

The purpose of this method is to calculate the next execution time
from a specified crontab entry

Parameters:

=over

=item $cron_entry  

The crontab entry as specified in L<"add_entry">

=item $ref_time    

The reference time for which the next time should be searched which matches
C<$cron_entry>. By default, take the current time

=back

This method returns the number of epoch-seconds of the next matched 
date for C<$cron_entry>.

Since I suspect, that this calculation of the next execution time might
fail in some circumstances (bugs are lurking everywhere ;-) an
additional interactive method C<bug()> is provided for checking
crontab entries against your expected output. Refer to the
top-level README for additional usage information for this method.

=cut

sub get_next_execution_time 
{ 
  my $self = shift;
  my $cron_entry = shift;
  my $time = shift;
  
  $cron_entry = [ split /\s+/,$cron_entry ] unless ref($cron_entry);

  # Expand and check entry:
  # =======================
  die "Exactly 5 or 6 columns has to be specified for a crontab entry ! (not ",
    scalar(@$cron_entry),")"
      if ($#$cron_entry != 4 && $#$cron_entry != 5);
  
  my @expanded;
  my $w;
  
  for my $i (0..$#$cron_entry) 
  {
      my @e = split /,/,$cron_entry->[$i];
      my @res;
      my $t;
      while (defined($t = shift @e)) {
          # Subst "*/5" -> "0-59/5"
          $t =~ s|^\*(/.+)$|$RANGES[$i][0]."-".$RANGES[$i][1].$1|e; 
          
          if ($t =~ m|^([^-]+)-([^-/]+)(/(.*))?$|) 
          {
              my ($low,$high,$step) = ($1,$2,$4);
              $step = 1 unless $step;
              if ($low !~ /^(\d+)/) 
              {
                  $low = $ALPHACONV[$i]{lc $low};
              }
              if ($high !~ /^(\d+)/) 
              {
                  $high = $ALPHACONV[$i]{lc $high};
              }
              if (! defined($low) || !defined($high) ||  $low > $high || $step !~ /^\d+$/) 
              {
                  die "Invalid cronentry '",$cron_entry->[$i],"'";
              }
              my $j;
              for ($j = $low; $j <= $high; $j += $step) 
              {
                  push @e,$j;
              }
          } 
          else 
          {
              $t = $ALPHACONV[$i]{lc $t} if $t !~ /^(\d+|\*)$/;
              $t = $LOWMAP[$i]{$t} if exists($LOWMAP[$i]{$t});
              
              die "Invalid cronentry '",$cron_entry->[$i],"'" 
                if (!defined($t) || ($t ne '*' && ($t < $RANGES[$i][0] || $t > $RANGES[$i][1])));
              push @res,$t;
          }
      }
      push @expanded, ($#res == 0 && $res[0] eq '*') ? [@res] : [ sort { $a <=> $b} @res];
  }
  
  # Calculating time:
  # =================
  my $now = $time || time;

  if ($expanded[2]->[0] ne '*' && $expanded[4]->[0] ne '*') 
  {
      # Special check for which time is lower (Month-day or Week-day spec):
      my @bak = @{$expanded[4]};
      $expanded[4] = [ '*' ];
      my $t1 = $self->calc_time($now,\@expanded);
      $expanded[4] = \@bak;
      $expanded[2] = [ '*' ];
      my $t2 = $self->calc_time($now,\@expanded);
      dbg "MDay : ",scalar(localtime($t1))," -- WDay : ",scalar(localtime($t2));
      return $t1 < $t2 ? $t1 : $t2;
  } 
  else 
  {
      # No conflicts possible:
      return $self->calc_time($now,\@expanded);
  }
}

# ==================================================
# PRIVATE METHODS:
# ==================================================

# Build up executing queue and delete any
# existing entries
sub build_initial_queue 
{ 
    my $self = shift;
    $self->{queue} = [ ];
    #  dbg "TT: ",$#{$self->{time_table}};
    for my $id (0..$#{$self->{time_table}}) 
    {
        $self->update_queue($id);
    }
}

# deeply copy an entry in the time table
sub deep_copy_entry
{
    my ($self,$entry) = @_;

    my $args = [ @{$entry->{args}} ];
    my $copied_entry = { %$entry };
    $copied_entry->{args} = $args;
    return $copied_entry;
}

# Execute a subroutine whose time has come
sub execute 
{ 
  my $self = shift;
  my $index = shift;
  my $cfg = shift || $self->{cfg};
  my $entry = $self->get_entry($index) 
    || die "Internal: No entry with index $index found in ",Dumper([$self->list_entries()]);

  my $pid;


  my $log = $cfg->{log};

  unless ($cfg->{nofork})
  {
      if ($pid = fork) 
      {
          # Parent
          $log->(0,"Schedule::Cron - Forking child PID $pid") if $log;
          # Register PID
          $STARTEDCHILD{$pid} = 1;
          return;
      } 
  }
  
  # Child
  my $dispatch = $entry->{dispatcher};
  die "No subroutine provided with $dispatch" 
    unless ref($dispatch) eq "CODE";
  my $args = $entry->{args};
  
  my @args = ();
  if (defined($args) && defined($args->[0])) 
  {
      push @args,@$args;
  }


  my $args_label = @args ? "with (".join(",",$self->prepare_args(@args)).")" : "";
  $0 = $self->get_process_prefix()." Dispatch $args_label"
    unless $cfg->{nofork};
  $log->(0,"Schedule::Cron - Starting job $index $args_label")
    if $log;

  if ($cfg->{catch})
  {
      # Evaluate dispatcher
      eval
      {
          &$dispatch(@args);
      };
      if ($@)
      {
          $log->(2,"Schedule::Cron - Error within job $index: $@")
            if $log;
      }
  }
  else
  {
      # Let dispatcher die if needed.
      &$dispatch(@args);
  }

  $log->(0,"Schedule::Cron - Finished job $index") if $log;
  exit unless $cfg->{nofork};
}

# Udate the scheduler queue with a new entry
sub update_queue 
{ 
    my $self = shift;
    
    my $index = shift;
    
    my $entry = $self->get_entry($index);
    
    my $new_time = $self->get_next_execution_time($entry->{time});
    dbg "Updating Queue: ",scalar(localtime($new_time));
    $self->{queue} = [ sort { $a->[1] <=> $b->[1] } @{$self->{queue}},[$index,$new_time] ];
    #  dbg "Queue now: ",Dumper($self->{queue});
}


# The heart of the module.
# calulate the next concrete date
# for execution from a cronta entry
sub calc_time 
{ 
    my $self = shift;
    my $now = shift;
    my $expanded = shift;

    my $offset = ($expanded->[5] ? 1 : 60);
    my ($now_sec,$now_min,$now_hour,$now_mday,$now_mon,$now_wday,$now_year) = 
      (localtime($now+$offset))[0,1,2,3,4,6,5];
    $now_mon++; 
    $now_year += 1900;

    # Notes on variables set:
    # $now_... : the current date, fixed at call time
    # $dest_...: date used for backtracking. At the end, it contains
    #            the desired lowest matching date
    
    my ($dest_mon,$dest_mday,$dest_wday,$dest_hour,$dest_min,$dest_sec,$dest_year) = 
      ($now_mon,$now_mday,$now_wday,$now_hour,$now_min,$now_sec,$now_year);
    
    while ($dest_year <= $now_year + 1) 
    { # Airbag...
        dbg "Parsing $dest_hour:$dest_min:$dest_sec $dest_year/$dest_mon/$dest_mday";
        
        
        # Check month:
        if ($expanded->[3]->[0] ne '*') 
        {
            unless (defined ($dest_mon = $self->get_nearest($dest_mon,$expanded->[3]))) 
            {
                $dest_mon = $expanded->[3]->[0];
                $dest_year++;
            } 
        } 
  
        # Check for day of month:
        if ($expanded->[2]->[0] ne '*') 
        {           
            if ($dest_mon != $now_mon) 
            {      
                $dest_mday = $expanded->[2]->[0];
            } 
            else 
            {
                unless (defined ($dest_mday = $self->get_nearest($dest_mday,$expanded->[2]))) 
                {
                    # Next day matched is within the next month. ==> redo it
                    $dest_mday = $expanded->[2]->[0];
                    $dest_mon++;
                    if ($dest_mon > 12) 
                    {
                        $dest_mon = 1;
                        $dest_year++;
                    }
                    dbg "Backtrack mday: $dest_mday/$dest_mon/$dest_year";
                    next;
                }
            }
        } 
        else 
        {
            $dest_mday = ($dest_mon == $now_mon ? $dest_mday : 1);
        }
  
        # Check for day of week:
        if ($expanded->[4]->[0] ne '*') 
        {
            $dest_wday = $self->get_nearest($dest_wday,$expanded->[4]);
            $dest_wday = $expanded->[4]->[0] unless $dest_wday;
    
            my ($mon,$mday,$year);
            #      dbg "M: $dest_mon MD: $dest_mday WD: $dest_wday Y:$dest_year";
            $dest_mday = 1 if $dest_mon != $now_mon;
            my $t = parsedate(sprintf("%4.4d/%2.2d/%2.2d",$dest_year,$dest_mon,$dest_mday));
            ($mon,$mday,$year) =  
              (localtime(parsedate("$WDAYS[$dest_wday]",PREFER_FUTURE=>1,NOW=>$t-1)))[4,3,5]; 
            $mon++;
            $year += 1900;
            
            dbg "$mday/$mon/$year";
            if ($mon != $dest_mon || $year != $dest_year) {
                dbg "backtracking";
                $dest_mon = $mon;
                $dest_year = $year;
                $dest_mday = 1;
                $dest_wday = (localtime(parsedate(sprintf("%4.4d/%2.2d/%2.2d",
                                                          $dest_year,$dest_mon,$dest_mday))))[6];
                next;
            }
            
            $dest_mday = $mday;
        } 
        else 
        {
            unless ($dest_mday) 
            {
                $dest_mday = ($dest_mon == $now_mon ? $dest_mday : 1);
            }
        }
  
        # Check for hour
        if ($expanded->[1]->[0] ne '*') 
        {
            if ($dest_mday != $now_mday) 
            {
                $dest_hour = $expanded->[1]->[0];
            } 
            else 
            {
#       dbg "Checking for next hour $dest_hour";
                unless (defined ($dest_hour = $self->get_nearest($dest_hour,$expanded->[1]))) 
                {
                    # Hour to match is at the next day ==> redo it
                    $dest_hour = $expanded->[1]->[0];
                    my $t = parsedate(sprintf("%2.2d:%2.2d:%2.2d %4.4d/%2.2d/%2.2d",
                                              $dest_hour,$dest_min,$dest_sec,$dest_year,$dest_mon,$dest_mday));
                    ($dest_mday,$dest_mon,$dest_year,$dest_wday) = 
                      (localtime(parsedate("+ 1 day",NOW=>$t)))[3,4,5,6];
                    $dest_mon++; 
                    $dest_year += 1900;
                    next; 
                }
            }
        } 
        else 
        {
            $dest_hour = ($dest_mday == $now_mday ? $dest_hour : 0);
        }
    
        # Check for minute
        if ($expanded->[0]->[0] ne '*') 
        {
            if ($dest_hour != $now_hour) 
            {
                $dest_min = $expanded->[0]->[0];
            } 
            else 
            {
                unless (defined ($dest_min = $self->get_nearest($dest_min,$expanded->[0]))) 
                {
                    # Minute to match is at the next hour ==> redo it
                    $dest_min = $expanded->[0]->[0];
                    my $t = parsedate(sprintf("%2.2d:%2.2d:%2.2d %4.4d/%2.2d/%2.2d",
                                              $dest_hour,$dest_min,$dest_sec,$dest_year,$dest_mon,$dest_mday));
                    ($dest_hour,$dest_mday,$dest_mon,$dest_year,$dest_wday) = 
                      (localtime(parsedate(" + 1 hour",NOW=>$t)))  [2,3,4,5,6];
                    $dest_mon++;
                    $dest_year += 1900;
                    next;
                }
            }
        } 
        else 
        {
            $dest_min = ($dest_hour == $now_hour ? $dest_min : 0);
        }

        # Check for seconds
        if ($expanded->[5])
        {
            if ($expanded->[5]->[0] ne '*')
            {
                if ($dest_min != $now_min) 
                {
                    $dest_sec = $expanded->[5]->[0];
                } 
                else 
                {
                    unless (defined ($dest_sec = $self->get_nearest($dest_sec,$expanded->[5]))) 
                    {
                        # Second to match is at the next minute ==> redo it
                        $dest_sec = $expanded->[5]->[0];
                        my $t = parsedate(sprintf("%2.2d:%2.2d:%2.2d %4.4d/%2.2d/%2.2d",
                                                  $dest_hour,$dest_min,$dest_sec,
                                                  $dest_year,$dest_mon,$dest_mday));
                        ($dest_min,$dest_hour,$dest_mday,$dest_mon,$dest_year,$dest_wday) = 
                          (localtime(parsedate(" + 1 minute",NOW=>$t)))  [1,2,3,4,5,6];
                        $dest_mon++;
                        $dest_year += 1900;
                        next;
                    }
                }
            } 
            else 
            {
                $dest_sec = ($dest_min == $now_min ? $dest_sec : 0);
            }
        }
        else
        {
            $dest_sec = 0;
        }

        
        # We did it !!
        my $date = sprintf("%2.2d:%2.2d:%2.2d %4.4d/%2.2d/%2.2d",
                           $dest_hour,$dest_min,$dest_sec,$dest_year,$dest_mon,$dest_mday);
        dbg "Next execution time: $date ",
          $WDAYS[$dest_wday];
        return parsedate($date);
    }
}

# get next entry in list or 
# undef if is the highest entry found
sub get_nearest 
{ 
  my $self = shift;
  my $x = shift;
  my $to_check = shift;
  foreach my $i (0 .. $#$to_check) 
  {
      if ($$to_check[$i] >= $x) 
      {
          return $$to_check[$i] ;
      }
  }
  return undef;
}


# prepare a list of object for pretty printing e.g. in the process list
sub prepare_args {
    my $self = shift;
    my @args = @_;
    my @ret = ();
    for my $arg (@args)
    {
        if (ref($arg) eq 'HASH') 
        {
            my $val = "{";
            foreach my $key (keys %{$arg}) 
            {
                $val .= "$key=>".$args[0]->{$key}.", ";
            }
            if (length($val)>1)
            {
                chop $val; chop $val;
            }
            $val .= "}";
            push @ret,$val;
        } 
        else
        {
            push @ret,$arg;
        }         
    }
    return @ret;
}

# get the prefix to use when setting $0
sub get_process_prefix { 
    my $self = shift;
    my $prefix = $self->{cfg}->{processprefix} || "Schedule::Cron";
    return $prefix;
}

# our very own debugging routine
# ('guess everybody has its own style ;-)
sub dbg  
{
  if ($DEBUG) 
  {
      my $args = join('',@_) || "";
      my $caller = (caller(1))[0];
      my $line = (caller(0))[2];
      $caller ||= $0;
      if (length $caller > 22) 
      {
          $caller = substr($caller,0,10)."..".substr($caller,-10,10);
      }
      print STDERR sprintf ("%02d:%02d:%02d [%22.22s %4.4s]  %s\n",
                            (localtime)[2,1,0],$caller,$line,$args);
  }
}

# Helper method for reporting bugs concerning calculation
# of execution bug:
*bug = \&report_exectime_bug;   # Shortcut
sub report_exectime_bug 
{
  my $self = shift;
  my $endless = shift;
  my $time = time;
  my $inp;
  my $now = $self->time_as_string($time);
  my $email;

  do 
  {
      while (1) 
      {
          $inp = $self->get_input("Reference time\n(default: $now)  : ");
          if ($inp) 
          {
              parsedate($inp) || (print "Couldn't parse \"$inp\"\n",next);
              $now = $inp;
          }
          last;
      }
      my $now_time = parsedate($now);
    
      my ($next_time,$next);
      my @entries;
      while (1) 
      {
          $inp = $self->get_input("Crontab time (5 columns)            : ");
          @entries = split (/\s+/,$inp);
          if (@entries != 5) 
          {
              print "Invalid crontab entry \"$inp\"\n";
              next;
          }
          eval 
          { 
              local $SIG{ALRM} = sub {  die "TIMEOUT" };
              alarm(60);
              $next_time = Schedule::Cron->get_next_execution_time(\@entries,$now_time);
              alarm(0);
          };
          if ($@) 
          {
              alarm(0);
              if ($@ eq "TIMEOUT") 
              {
                  $next_time = -1;
              } else 
              {
                  print "Invalid crontab entry \"$inp\" ($@)\n";
                  next;
              }
          }
        
          if ($next_time > 0) 
          {
              $next = $self->time_as_string($next_time);
          } else 
          {
              $next = "Run into infinite loop !!";
          }
          last;
      }
    
      my ($expected,$expected_time);
      while (1) 
      {
          $inp = $self->get_input("Expected time                       : ");
          unless ($expected_time = parsedate($inp)) 
          {
              print "Couldn't parse \"$inp\"\n";
              next;
          } 
          $expected = $self->time_as_string($expected_time);
          last;
      }
    
      # Print out bug report:
      if ($expected eq $next) 
      {
          print "\nHmm, seems that everything's ok, or ?\n\n";
          print "Calculated time: ",$next,"\n";
          print "Expected time  : ",$expected,"\n";
      } else 
      {
          print <<EOT;
Congratulation, you hit a bug. 

EOT
          $email = $self->get_input("Your E-Mail Address (if available)  : ") 
            unless defined($email);
          $email = "" unless defined($email);
      
          print "\n","=" x 80,"\n";
          print <<EOT;
Please report the following lines
to roland\@cpan.org

EOT
          print "# ","-" x 78,"\n";
          print "Reftime: ",$now,"\n";
          print "# Reported by : ",$email,"\n" if $email;
          printf "%8s %8s %8s %8s %8s         %s\n",@entries,$expected;
          print "# Calculated  : \n";
          printf "# %8s %8s %8s %8s %8s         %s\n",@entries,$next;
          unless ($endless) 
          {
              require Config;
              my $vers = `uname -r 2>/dev/null` || $Config::Config{'osvers'} ;
              chomp $vers;
              my $osname = `uname -s 2>/dev/null` || $Config::Config{'osname'};
              chomp $osname;
              print "# OS: $osname ($vers)\n";
              print "# Perl-Version: $]\n";
              print "# Time::ParseDate-Version: ",$Time::ParseDate::VERSION,"\n";
          }
          print "# ","-" x 78,"\n";
      }
    
      print "\n","=" x 80,"\n";
  } while ($endless);
}

my ($input_initialized,$term);
sub get_input 
{ 
  my $self = shift;
  my $prompt = shift;
  use vars qw($term);

  unless (defined($input_initialized)) 
  {
      eval { require Term::ReadLine; };
    
      $input_initialized = $@ ? 0 : 1;
      if ($input_initialized) 
      {
          $term = new Term::ReadLine;
          $term->ornaments(0);
      }
  }
  
  unless ($input_initialized) 
  {
      print $prompt;
      my $inp = <STDIN>;
      chomp $inp;
      return $inp;
  } 
  else 
  {
      chomp $prompt;
      my @prompt = split /\n/s,$prompt;
      if ($#prompt > 0)
      {
          print join "\n",@prompt[0..$#prompt-1],"\n";
      }
      my $inp = $term->readline($prompt[$#prompt]);
      return $inp;
  }
}

sub time_as_string 
{ 
  my $self = shift;
  my $time = shift; 

  my ($min,$hour,$mday,$month,$year,$wday) = (localtime($time))[1..6];
  $month++;
  $year += 1900;
  $wday = $WDAYS[$wday];
  return sprintf("%2.2d:%2.2d %2.2d/%2.2d/%4.4d %s",
                 $hour,$min,$mday,$month,$year,$wday);
}

=back

=head1 TODO

=over 

=item *

Provide a C<reload()> method for reexaming the crontab file 

=back


=head1 COPYRIGHT

Copyright 1999-2006 Roland Huss.

This library is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 AUTHOR

                                                    ...roland

=cut

1;




