use ExtUtils::MakeMaker;
WriteMakefile
  (
   NAME => "Schedule::Cron",
   VERSION_FROM => "Cron.pm",
   ($] >= 5.005
      ? (ABSTRACT   => 'cron-like scheduler',
         AUTHOR     => 'Roland Huss (roland@consol.de)')
      : ()),
   PREREQ_PM => { "Time::ParseDate" => '99.00'},
   'dist' => {COMPRESS=>'gzip',SUFFIX=>'gz'}
  );
