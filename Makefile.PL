use ExtUtils::MakeMaker;


my %args = (
  NAME => 'AnyEvent::Task',
  VERSION_FROM => 'lib/AnyEvent/Task.pm',
  LIBS => [''],
  INC => '-I lib/',
  PREREQ_PM => {
    'common::sense' => 0,
    'AnyEvent' => 0,
    'RPC::Pipelined' => 0,
    'Guard' => 0,
    'Callback::Frame' => 0,
    'Log::Defer' => '0.300',
  },
  LICENSE => 'perl',
  dist => {
    PREOP => 'perldoc -uT $(VERSION_FROM) > README.pod; pod2text README.pod > $(DISTVNAME)/README',
  },
);


my $eummv = eval ($ExtUtils::MakeMaker::VERSION);
if ($eummv >= 6.45) {
    $args{META_MERGE} = {
        resources => {
            repository => 'git://github.com/hoytech/AnyEvent-Task.git',
            bugtracker => 'https://github.com/hoytech/AnyEvent-Task/issues',
        },
    };
}

WriteMakefile(%args);
