package Yggdrasil::Seeder;
use Moo;
use Carp ();
use File::Path ();
use File::Spec ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Yggdrasil::Util qw(snake_case);

has connection => (is => 'ro', required => 1);
has paths      => (is => 'ro', required => 1);

sub _name {
  my ($name) = @_;
  Carp::croak('Yggdrasil: invalid seeder name') unless defined $name && $name =~ /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/;
  $name =~ tr/-/_/;
  return snake_case($name);
}

sub files {
  my $s = shift;
  my %files;
  for my $dir (@{$s->paths}) {
    next unless -e $dir;
    opendir my $dh, $dir or Carp::croak("Yggdrasil: cannot read seed directory '$dir': $!");
    for my $entry (sort readdir $dh) {
      next unless $entry =~ /\A([a-z0-9][a-z0-9_]*)\.pl\z/;
      my $name = $1;
      my $file = File::Spec->rel2abs(File::Spec->catfile($dir, $entry));
      next unless -f $file;
      Carp::croak("Yggdrasil: duplicate seeder '$name'") if exists $files{$name} && $files{$name} ne $file;
      $files{$name} = $file;
    }
  }
  return \%files;
}

sub make {
  my ($s, $input) = @_;
  my $name = _name($input);
  my $dir = $s->paths->[0] // Carp::croak('Yggdrasil: no seed path configured');
  Carp::croak("Yggdrasil: seeder '$name' already exists") if exists $s->files->{$name};
  File::Path::make_path($dir);
  my $file = File::Spec->catfile($dir, "$name.pl");
  sysopen my $fh, $file, O_WRONLY | O_CREAT | O_EXCL or Carp::croak("Yggdrasil: cannot create '$file': $!");
  print {$fh} <<'SEED' or Carp::croak("Yggdrasil: cannot write '$file': $!");
use strict;
use warnings;

return sub {
  my ($db) = @_;
  # Repeatable example (requires a unique index on code):
  # $db->table('roles')->upsert([{code => 'viewer', name => 'Viewer'}], ['code'], ['name']);
};
SEED
  close $fh or Carp::croak("Yggdrasil: cannot write '$file': $!");
  return $file;
}

# Prepare before a destructive fresh. Seed files must only return callbacks at load time.
sub prepare {
  my ($s, $input) = @_;
  my $files = $s->files;
  my @names = defined $input ? (_name($input)) : sort keys %$files;
  Carp::croak('Yggdrasil: no seeders found') unless @names;
  my @jobs;
  for my $name (@names) {
    my $file = $files->{$name} // Carp::croak("Yggdrasil: seeder '$name' not found");
    local ($@, $!);
    my $cb = do $file;
    Carp::croak("Yggdrasil: error loading seeder '$name': $@") if $@;
    Carp::croak("Yggdrasil: cannot read seeder '$name': $!") if !defined $cb && $!;
    Carp::croak("Yggdrasil: seeder '$name' must return a code reference") unless ref $cb eq 'CODE';
    push @jobs, $cb;
  }
  my $db = $s->connection;
  return sub {
    $db->transaction(sub { for my $job (@jobs) { $job->($db) } });
    return [@names];
  };
}

sub run { shift->prepare(@_)->() }

1;
