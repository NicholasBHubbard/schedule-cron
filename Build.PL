#!/usr/bin/perl
use Module::Build;
my $build = Module::Build->new
  (
   module_name => "Schedule::Cron",
   dist_author => 'Roland Huss (roland@cpan.org)',
   abstract => 'Cron-like scheduler for Perl subroutines',
   distribution_type => 'module',
   installdirs => 'site',

   license => "perl",
   
   requires => {
                "Time::ParseDate" => "99.00",
                "Data::Dumper" => "0"
               },
   
   build_requires => {
                      "Test::More" => "0",
                      "Test" => "0"
                     },                       
   recommends => {
                  "ioctl.ph" => 0,
                  "sys::ioctl.ph" => 0,
                  "Module::Build" => 0
                 },
   keywords => [  "Cron", "Scheduler", "Jon" ],
   provides => {
                "Schedule::Cron" => {
                               file =>  "lib/Schedule/Cron.pm"
                              }
               }
  );
$build->create_build_script;
