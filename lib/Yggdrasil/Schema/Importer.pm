package Yggdrasil::Schema::Importer;
use Moo;
use Carp ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Path ();
use File::Spec ();
use Yggdrasil::Util qw(snake_case);

has connection => (is => 'ro', required => 1);

sub describe { $_[0]->_describe($_[1], 0) }

sub _describe {
  my ($s, $table, $listed) = @_;
  my $db = $s->connection;
  Carp::croak('Yggdrasil: schema import requires a simple table name')
    unless defined $table && $table =~ /\A[A-Za-z_][A-Za-z_0-9]*\z/;
  Carp::croak("Yggdrasil: table '$table' was not found in the current schema")
    unless $listed || grep { $_ eq $table } $db->schema->get_tables;
  my ($columns, $primary, $fk, $auto);
  if ($db->driver eq 'sqlite') {
    my $id = $db->grammar->wrap_segment($table);
    my @meta = @{$db->select_all("pragma table_info($id)")};
    $columns = [map { $_->{name} } @meta];
    my @pk = sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} } @meta;
    $primary = [map { $_->{name} } @pk];
    my $ddl = $db->select_one('select sql from sqlite_master where type = ? and name = ?', 'table', $table);
    my $indexed = grep { ($_->{origin} // '') eq 'pk' } @{$db->select_all("pragma index_list($id)")};
    $auto = @pk == 1 && uc($pk[0]{type} // '') eq 'INTEGER' && !$indexed
      && ($ddl->{sql} // '') !~ /\bwithout\s+rowid\b/i;
    $fk = [map { +{ id => $_->{id}, seq => $_->{seq}, col => $_->{from}, target => $_->{table}, remote => $_->{to} } }
      @{$db->select_all("pragma foreign_key_list($id)")}];
  } elsif ($db->driver eq 'pg') {
    my $meta = $db->select_all(q{
      select column_name as name, is_identity as generated_id, column_default as default_expr
        from information_schema.columns where table_schema = current_schema() and table_name = ? order by ordinal_position
    }, $table);
    $columns = [map { $_->{name} } @$meta];
    $primary = [map { $_->{name} } @{$db->select_all(q{
      select k.column_name as name from information_schema.table_constraints c
        join information_schema.key_column_usage k on k.constraint_schema = c.constraint_schema
          and k.constraint_name = c.constraint_name and k.table_name = c.table_name and k.table_schema = c.table_schema
        where c.table_schema = current_schema() and c.table_name = ? and c.constraint_type = 'PRIMARY KEY'
        order by k.ordinal_position
    }, $table)}];
    $auto = @$primary == 1 && grep { $_->{name} eq $primary->[0]
      && ($_->{generated_id} eq 'YES' || ($_->{default_expr} // '') =~ /\Anextval\(/) } @$meta;
    # pg_constraint uses ordered arrays of attribute numbers for both sides.
    $fk = $db->select_all(q{
      select c.oid as id, i.n as seq, f.attname as col, r.relname as target, p.attname as remote
      from pg_constraint c
      join pg_class l on l.oid = c.conrelid join pg_namespace ln on ln.oid = l.relnamespace
      join pg_class r on r.oid = c.confrelid join pg_namespace rn on rn.oid = r.relnamespace
      cross join lateral generate_subscripts(c.conkey, 1) as i(n)
      join pg_attribute f on f.attrelid = l.oid and f.attnum = c.conkey[i.n]
      join pg_attribute p on p.attrelid = r.oid and p.attnum = c.confkey[i.n]
      where c.contype = 'f' and ln.nspname = current_schema() and rn.nspname = current_schema() and l.relname = ?
    }, $table);
  } else {
    my $meta = $db->select_all(q{
      select column_name as name, extra as extra_info from information_schema.columns
      where table_schema = database() and table_name = ? order by ordinal_position
    }, $table);
    $columns = [map { $_->{name} } @$meta];
    $primary = [map { $_->{name} } @{$db->select_all(q{
      select column_name as name from information_schema.key_column_usage
      where table_schema = database() and table_name = ? and constraint_name = 'PRIMARY' order by ordinal_position
    }, $table)}];
    $auto = @$primary == 1 && grep {
      $_->{name} eq $primary->[0] && ($_->{extra_info} // '') =~ /\bauto_increment\b/i
    } @$meta;
    $fk = $db->select_all(q{
      select constraint_name as id, ordinal_position as seq, column_name as col,
        referenced_table_name as target, referenced_column_name as remote
      from information_schema.key_column_usage
      where table_schema = database() and table_name = ? and referenced_table_schema = database()
    }, $table);
  }
  my %groups;
  push @{$groups{$_->{id}}}, $_ for @$fk;
  my @relations;
  for my $rows (values %groups) {
    my @r = sort { $a->{seq} <=> $b->{seq} } @$rows;
    my @remote = map { $_->{remote} } @r;
    if ($db->driver eq 'sqlite' && !(grep { defined $_ && length $_ } @remote)) {
      my $target = $db->grammar->wrap_segment($r[0]{target});
      @remote = map { $_->{name} } sort { $a->{pk} <=> $b->{pk} } grep { $_->{pk} }
        @{$db->select_all("pragma table_info($target)")};
    }
    next unless @remote == @r && !(grep { !defined $_ || !length $_ } @remote);
    push @relations, { table => $r[0]{target}, local => [map { $_->{col} } @r], remote => \@remote };
  }
  @relations = sort { join(',', @{$a->{local}}) cmp join(',', @{$b->{local}}) } @relations;
  return { table => $table, columns => $columns, primary => $primary, incrementing => $auto ? 1 : 0,
    foreign_keys => \@relations };
}

sub _class {
  my $name = shift;
  return join '', map { ucfirst lc $_ } grep { length } split /_+/, snake_case($name);
}

sub _literal {
  my $v = shift;
  $v =~ s/(['\\])/\\$1/g;
  return "'$v'";
}

sub _key_code { @{$_[0]} == 1 ? _literal($_[0][0]) : '[qw(' . join(' ', @{$_[0]}) . ')]' }

sub generate {
  my ($s, %opts) = @_;
  my $namespace = $opts{namespace} // Carp::croak('Yggdrasil: model namespace required');
  my $directory = $opts{directory} // Carp::croak('Yggdrasil: model directory required');
  Carp::croak('Yggdrasil: invalid model namespace') unless $namespace =~ /\A[A-Za-z_]\w*(?:::[A-Za-z_]\w*)*\z/a;
  my @tables = defined $opts{table} ? ($opts{table}) : sort $s->connection->schema->get_tables;
  my (%classes, @out);
  for my $table (@tables) {
    next if !defined $opts{table} && ($table eq 'migrations' || $table !~ /\A[A-Za-z_][A-Za-z_0-9]*\z/);
    my $info = $s->_describe($table, !defined $opts{table});
    my $base = _class($table);
    if (!@{$info->{primary}} || $base !~ /\A[A-Za-z][A-Za-z_0-9]*\z/
        || grep { !/\A[A-Za-z_][A-Za-z_0-9]*\z/ } @{$info->{primary}}) {
      Carp::croak("Yggdrasil: '$table' needs a supported primary key to generate a model") if defined $opts{table};
      push @out, { table => $table, skipped => 1 };
      next;
    }
    my $class = "$namespace\::$base";
    Carp::croak("Yggdrasil: schema tables map to the same class '$class'") if $classes{$class}++;
    my $file = File::Spec->catfile($directory, split(/::/, $namespace), "$base.pm");
    my @source = ("package $class;", 'use Moo;', "extends 'Yggdrasil::Model';", '',
      '# Review generated model and add an explicit fillable list before exposing writes.',
      'sub table { ' . _literal($table) . ' }',
      'sub primary_key { ' . _key_code($info->{primary}) . ' }',
      'sub incrementing { ' . $info->{incrementing} . ' }',
      'sub timestamps { 0 }', q{sub guarded { ['*'] }});
    push @source, 'sub connection_name { ' . _literal($s->connection->name) . ' }' if $opts{pin_connection};
    my %used;
    for my $r (@{$info->{foreign_keys}}) {
      next if grep { !/\A[A-Za-z_][A-Za-z_0-9]*\z/ } ($r->{table}, @{$r->{local}}, @{$r->{remote}});
      my $target = _class($r->{table});
      next unless $target =~ /\A[A-Za-z][A-Za-z_0-9]*\z/;
      my $method = 'related_' . snake_case($r->{table});
      $method .= '_' . join('_', @{$r->{local}}) if $used{$method}++;
      next if grep { /^\Qsub $method\E / } @source;
      push @source, 'sub ' . $method . ' { $_[0]->belongs_to(' . _literal("$namespace\::$target")
        . ', ' . _key_code($r->{local}) . ', ' . _key_code($r->{remote}) . ') }';
    }
    push @out, { table => $table, file => $file, source => join("\n", @source, '', '1;', '') };
  }
  return \@out if $opts{pretend};
  for my $item (grep { !$_->{skipped} } @out) {
    Carp::croak("Yggdrasil: '$item->{file}' already exists") if -e $item->{file};
  }
  for my $item (grep { !$_->{skipped} } @out) {
    my (undef, $dir) = File::Spec->splitpath($item->{file});
    File::Path::make_path($dir);
    sysopen my $fh, $item->{file}, O_WRONLY | O_CREAT | O_EXCL or Carp::croak("Yggdrasil: cannot create '$item->{file}': $!");
    print {$fh} $item->{source} or Carp::croak("Yggdrasil: cannot write '$item->{file}': $!");
    close $fh or Carp::croak("Yggdrasil: cannot write '$item->{file}': $!");
  }
  return \@out;
}

1;
