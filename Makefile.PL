use ExtUtils::MakeMaker;

my $preop =
    'perldoc -uT $(VERSION_FROM) | tee $(DISTVNAME)/README.pod > README.pod;' .
    'pod2text README.pod | tee $(DISTVNAME)/README > README';

WriteMakefile(
  NAME => 'AnyEvent::Task',
  VERSION_FROM => 'lib/AnyEvent/Task.pm',
  LIBS => [''],
  INC => '-I lib/',
  PREREQ_PM => {
    'common::sense' => 0,
    'AnyEvent' => 0,
    'Callback::Frame' => 0,
  },
  dist => {
    PREOP => $preop,
  },
);
