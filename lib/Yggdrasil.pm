package Yggdrasil;
use Moo;
use Carp ();
use Yggdrasil::Connection;

our $VERSION = '0.03';
my $INSTANCE;

has connections      => (is => 'rw', default => sub { +{} });
has default          => (is => 'rw', default => sub { 'default' });
has model_namespaces => (is => 'rw', default => sub { [] });
has migration_paths  => (is => 'rw', default => sub { +{} });
has seed_paths       => (is => 'rw', default => sub { +{} });
has logger           => (is => 'rw');
has _pool            => (is => 'ro', default => sub { +{} });
has _models          => (is => 'ro', default => sub { +{} });

sub init         { my $class = shift; my $m = $class->new(@_); $INSTANCE = $m; return $m }
sub set_instance { $INSTANCE = $_[1] }
sub instance     { $INSTANCE }

sub connection {
  my ($s, $name) = @_;
  $name //= $s->default;
  return $s->_pool->{$name} //= do {
    my $cfg = $s->connections->{$name}
      or Carp::croak(qq{Yggdrasil: unknown connection "$name"});
    Yggdrasil::Connection->new(name => $name, config => $cfg, logger => $s->logger);
  };
}
sub db { shift->connection(@_) }

sub table { my ($s, $t, $conn) = @_; $s->connection($conn)->table($t) }

sub schema {
  my ($s, $conn) = @_;
  require Yggdrasil::Schema::Builder;
  Yggdrasil::Schema::Builder->new(connection => $s->connection($conn));
}

sub migrator {
  my ($s, $conn, %o) = @_;
  require Yggdrasil::Migrator;
  $conn //= $s->default;
  my $p = $o{paths} // $s->migration_paths->{$conn} // [];
  $p = [$p] unless ref $p;
  Yggdrasil::Migrator->new(connection => $s->connection($conn), paths => $p);
}

sub transaction { my ($s, $cb, $conn) = @_; $s->connection($conn)->transaction($cb) }

sub seeder {
  my ($s, $conn, %o) = @_;
  require Yggdrasil::Seeder;
  $conn //= $s->default;
  my $paths = $o{paths} // $s->seed_paths->{$conn} // [];
  $paths = [$paths] unless ref $paths eq 'ARRAY';
  return Yggdrasil::Seeder->new(connection => $s->connection($conn), paths => $paths);
}

sub model {
  my ($s, $name) = @_;
  return $s->_models->{$name} //= $s->_resolve_model($name);
}

sub model_query {
  my ($s, $name, %opts) = @_;
  return $s->model($name)->query(%opts, manager => $s);
}

sub make_model {
  my ($s, $name, $attrs, %opts) = @_;
  my $row = $s->model($name)->make($attrs);
  my $conn = $s->connection($opts{using} // $row->using // $row->connection_name);
  $row->_bound_manager($s);
  $row->_bound_connection($conn);
  $row->using($conn->name);
  return $row;
}

sub create_model { shift->make_model(@_)->save }

sub _resolve_model {
  my ($s, $name) = @_;
  my @cand = $name =~ /::/ ? ($name) : map {"${_}::$name"} @{$s->model_namespaces};
  for my $c (@cand) {
    return $c if $c->isa('Yggdrasil::Model');
    (my $f = "$c.pm") =~ s{::}{/}g;
    if (eval { require $f; 1 }) { return $c if $c->isa('Yggdrasil::Model') }
    else { die $@ unless $@ =~ /^Can't locate \Q$f\E/ }
  }
  Carp::croak(qq{Yggdrasil: model "$name" not found (looked for: @cand)});
}

sub disconnect_all { $_->disconnect for values %{$_[0]->_pool}; return }

1;

=head1 NAME

Yggdrasil - Framework-independent Eloquent-style ORM for Perl and DBI

=head1 SYNOPSIS

  use Yggdrasil;
  my $orm = Yggdrasil->new(
    connections => { default => { driver => 'sqlite', database => 'app.db' } },
    model_namespaces => ['MyApp::Model'],
  );
  my $page = $orm->table('events')->cursor_page(size => 25, order => ['id']);
  my $user = $orm->model_query('User')->find(1);

=head1 DESCRIPTION

Provides a DBI query builder, Moo models, relationships, schema building and
migrations. Use C<new> and C<model_query>, C<make_model> or C<create_model>
for independent managers. C<init> also sets a legacy default for class methods.
See the distribution README for driver setup, pagination and migration examples.

=cut
