package Yggdrasil;
use Moo;
use Carp ();
use Yggdrasil::Connection;

our $VERSION = '0.05';
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

sub schema_importer {
  my ($s, $conn) = @_;
  require Yggdrasil::Schema::Importer;
  return Yggdrasil::Schema::Importer->new(connection => $s->connection($conn));
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

sub first_or_create_model  { my $s = shift; $s->_atomic_model_write(0, @_) }
sub update_or_create_model { my $s = shift; $s->_atomic_model_write(1, @_) }

sub _atomic_model_write {
  my ($s, $update, $name, $identity, $values, %opts) = @_;
  $values //= {};
  Carp::croak('Yggdrasil: atomic write needs identity and values hashrefs')
    unless ref $identity eq 'HASH' && keys %$identity && ref $values eq 'HASH';
  my @keys = sort keys %$identity;
  Carp::croak('Yggdrasil: atomic identity must use named columns and non-null scalar values')
    if grep { !/\A[A-Za-z_][A-Za-z_0-9]*\z/ || !defined $identity->{$_} || ref $identity->{$_} } @keys;
  Carp::croak('Yggdrasil: provide identity columns only in the identity hash')
    if grep { exists $values->{$_} } @keys;
  my $row = $s->make_model($name, $values, %opts)->force_fill($identity);
  Carp::croak('Yggdrasil: managed timestamps cannot be atomic identity columns')
    if $row->timestamps && (exists $identity->{$row->created_at_column} || exists $identity->{$row->updated_at_column});
  my $db = $row->connection;
  my $table = $row->table;
  my %changes = %{$row->attributes};
  my %match = map { $_ => $changes{$_} } @keys;
  Carp::croak('Yggdrasil: identity values must stay non-null scalars after casts and mutators')
    if grep { !defined $_ || ref $_ } values %match;
  my @change_cols = grep { !exists $identity->{$_} } keys %changes;
  my %pk = map { $_ => 1 } $row->key_columns;
  Carp::croak('Yggdrasil: atomic update cannot change primary key columns')
    if $update && grep { $pk{$_} } @change_cols;
  my %insert = %changes;
  if ($row->timestamps) {
    my $now = $row->now;
    $insert{$_} //= $now for $row->created_at_column, $row->updated_at_column;
  }
  return $db->transaction(sub {
    my $q = $db->table($table);
    my $g = $db->grammar;
    my @bind;
    my $sql;
    my ($inserted, $duplicate);
    if ($db->driver eq 'mysql') {
      my $schema;
      ($schema, my $base) = $table =~ /\A([A-Za-z_]\w*)\.([A-Za-z_]\w*)\z/;
      my @metadata = @{$db->select_all(
        'select index_name as idx, column_name as col, sub_part as prefix_len from information_schema.statistics '
        . 'where table_schema = coalesce(?, database()) and table_name = ? and non_unique = 0', $schema, $base // $table)};
      my %indices;
      push @{$indices{$_->{idx}}}, defined $_->{prefix_len} ? '' : ($_->{col} // '') for @metadata;
      my $wanted = join "\0", @keys;
      Carp::croak('Yggdrasil: atomic identity must match an entire unique index')
        unless grep { (join "\0", sort @$_) eq $wanted } values %indices;
      $sql = $g->compile_insert($q, [\%insert], \@bind);
      # Error 1062 alone can enter the conflict path. An actual INSERT avoids
      # triggering UPDATE hooks on a different row with another unique index.
      my $ok = eval {
        $inserted = $db->_run($sql, \@bind, sub {
          my $dbh = shift;
          my $result;
          my $ok = eval { $result = $dbh->do($sql, undef, @bind); 1 };
          if (!$ok) {
            my $err = $@;
            $duplicate = ($dbh->err // 0) == 1062;
            die $err;
          }
          return $result;
        }, 0);
        1;
      };
      die $@ if !$ok && !$duplicate;
    } else {
      $sql = $g->compile_upsert($q, [\%insert], \@bind, \@keys, []);
      $inserted = $db->statement($sql, @bind);
    }
    my $query = $row->query->where(\%match)->lock_for_update;
    my $found = $query->first
      // Carp::croak('Yggdrasil: atomic write found no visible row for the requested identity (unrelated conflict or soft-deleted row)');
    if (!$inserted && $update && @change_cols) {
      my %set = map { $_ => $changes{$_} } @change_cols;
      $set{$row->updated_at_column} //= $row->now if $row->timestamps;
      $found->_stored_query->update(\%set);
      return $found->refresh;
    }
    return $found;
  });
}

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
