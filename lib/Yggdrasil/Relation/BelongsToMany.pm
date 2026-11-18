package Yggdrasil::Relation::BelongsToMany;
use Moo;
use Carp ();
use Scalar::Util qw(blessed refaddr);
use Yggdrasil::Util qw(uniq);
use Yggdrasil::Collection;
extends 'Yggdrasil::Relation';

has pivot_table       => (is => 'ro', required => 1);
has foreign_pivot_key => (is => 'ro', required => 1);   # pivot column pointing at the parent
has related_pivot_key => (is => 'ro', required => 1);   # pivot column pointing at the related model
has parent_key        => (is => 'ro', required => 1);
has related_key       => (is => 'ro', required => 1);
has pivot_columns     => (is => 'ro', default => sub { [] });

my $PFX = 'yggdrasil_pivot_';

sub _parent_pair { $_[0]->_key_pair($_[0]->foreign_pivot_key, $_[0]->parent_key) }
sub _related_pair { $_[0]->_key_pair($_[0]->related_pivot_key, $_[0]->related_key) }

sub BUILD {
  my $s = shift;
  $s->_parent_pair;
  $s->_related_pair;
}

sub with_pivot { my $s = shift; push @{$s->pivot_columns}, @_; $s }

sub _pivot_selects {
  my $s = shift;
  my $p = $s->pivot_table;
  my ($f) = $s->_parent_pair;
  my ($r) = $s->_related_pair;
  return map { "$p.$_ as $PFX$_" } uniq(@$f, @$r, @{$s->pivot_columns});
}

sub _join_pivot {
  my ($s, $q) = @_;
  my $p = $s->pivot_table;
  my ($rp, $rk) = $s->_related_pair;
  my $table = $s->related->table;
  $q->select($s->related->table . '.*', $s->_pivot_selects)
    ->join($p, sub {
      my $on = shift;
      $on->on("$table.$rk->[$_]", "$p.$rp->[$_]") for 0 .. $#$rp;
    });
}

sub _build_query {
  my $s = shift;
  my $q = $s->_related_query;
  return $q if $s->parent->_relation_probe;
  $s->_join_pivot($q);
  my ($pivot, $key) = $s->_parent_pair;
  my $table = $s->pivot_table;
  $q->_and_constraint(sub {
    $s->_where_tuple($_[0], [map { "$table.$_" } @$pivot], $s->_tuple($s->parent, $key));
  });
  return $q;
}

sub _existence_link {
  my ($s, $q, $inner, $outer) = @_;
  my ($rp, $rk) = $s->_related_pair;
  my ($fp, $pk) = $s->_parent_pair;
  my $alias = '__yggdrasil_pivot_link';
  $q->join($s->pivot_table . " as $alias", sub {
    my $on = shift;
    $on->on("$inner.$rk->[$_]", "$alias.$rp->[$_]") for 0 .. $#$rp;
  });
  $q->where_column("$alias.$fp->[$_]", "$outer.$pk->[$_]") for 0 .. $#$fp;
}

sub _extract_pivot {
  my ($s, $m) = @_;
  my %p;
  for my $k (grep { index($_, $PFX) == 0 } keys %{$m->attributes}) {
    $p{substr $k, length $PFX} = CORE::delete $m->attributes->{$k};
    CORE::delete $m->original->{$k};
  }
  $m->pivot(\%p);
  return \%p;
}

sub _post { my ($s, $models) = @_; $s->_extract_pivot($_) for @$models }

sub results { $_[0]->get }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my ($pivot, $local) = $s->_parent_pair;
  my $rows = $s->_fetch_tuples($models, $local, $pivot, $cb, sub { $s->_join_pivot($_[0]) }, $s->pivot_table);
  my %by;
  for my $m (@$rows) {
    my $p = $s->_extract_pivot($m);
    my @tuple = @{$p}{@$pivot};
    Carp::croak('Yggdrasil: eager-loading projection must include the pivot keys') if grep { !defined $_ } @tuple;
    push @{$by{$s->_tuple_key(\@tuple)}}, $m;
  }
  for my $model (@$models) {
    my $tuple = $s->_tuple($model, $local);
    $model->set_relation($name, Yggdrasil::Collection->new(@{($tuple ? $by{$s->_tuple_key($tuple)} : undef) // []}));
  }
}

# ---- pivot management -------------------------------------------------------------------

sub _pq {
  my $s = shift;
  my $parent_db = $s->parent->connection;
  Carp::croak('Yggdrasil: pivot relations require both models on the same connection')
    if refaddr($parent_db) != refaddr($s->_related_query->connection);
  return $parent_db->table($s->pivot_table);
}

sub _parent_pivot {
  my $s = shift;
  $s->parent->_stored_key;
  my ($cols, $keys) = $s->_parent_pair;
  my $tuple = $s->_tuple($s->parent, $keys)
    // Carp::croak('Yggdrasil: pivot write requires every parent key value');
  return ($cols, $tuple);
}

sub _normalize_ids {
  my ($s, $ids) = @_;
  my ($pivot, $keys) = $s->_related_pair;
  my %out;
  my @entries;
  if (@$keys == 1 && ref $ids eq 'HASH') {
    @entries = map { [$_, $ids->{$_} // {}] } sort keys %$ids;
  } else {
    @entries = map { [$_, {}] } (ref $ids eq 'ARRAY' ? @$ids : ($ids));
  }
  for my $entry (@entries) {
    my ($id, $extra) = @$entry;
    Carp::croak('Yggdrasil: pivot attributes must be a hashref') unless ref $extra eq 'HASH';
    my @tuple;
    if (blessed($id) && $id->isa($s->related)) {
      Carp::croak('Yggdrasil: related pivot model must be stored on the same connection')
        unless $id->in_storage && refaddr($id->connection) == refaddr($s->parent->connection);
      $id->_stored_key;
      @tuple = @{$id->attributes}{@$keys};
    } elsif (@$keys > 1 && ref $id eq 'HASH' && keys(%$id) == @$keys) {
      @tuple = @{$id}{@$keys};
    } elsif (@$keys == 1) { @tuple = ($id) }
    Carp::croak('Yggdrasil: pivot requires all related key values')
      if @tuple != @$keys || grep { !defined $_ || ref $_ } @tuple;
    my $index = @$keys == 1 ? $tuple[0] : $s->_tuple_key(\@tuple);
    $out{$index} = [\@tuple, $extra];
  }
  return ($pivot, $keys, \%out);
}

sub _pairs_hash {
  my ($cols, $values) = @_;
  my %out;
  @out{@$cols} = @$values;
  return \%out;
}

sub _insert_links {
  my ($s, $parent_cols, $parent, $related_cols, $entries, $attrs) = @_;
  my @rows;
  my $fixed = _pairs_hash($parent_cols, $parent);
  for my $entry (@$entries) {
    my ($tuple, $extra) = @$entry;
    my $related = _pairs_hash($related_cols, $tuple);
    for my $col (keys %$related) {
      Carp::croak("Yggdrasil: conflicting values for shared pivot column '$col'")
        if exists $fixed->{$col} && $fixed->{$col} ne $related->{$col};
    }
    push @rows, { %{$attrs // {}}, %$extra, %$fixed, %$related };
  }
  $s->_pq->insert(\@rows) if @rows;
  return scalar @rows;
}

sub attach {
  my ($s, $ids, $attrs) = @_;
  my ($parent_cols, $parent) = $s->_parent_pivot;
  my ($cols, undef, $n) = $s->_normalize_ids($ids);
  return $s->_insert_links($parent_cols, $parent, $cols, [map { $n->{$_} } sort keys %$n], $attrs);
}

sub detach {
  my ($s, $ids) = @_;
  my ($parent_cols, $parent) = $s->_parent_pivot;
  return $s->_pq->where(_pairs_hash($parent_cols, $parent))->delete unless defined $ids;
  my ($cols, undef, $n) = $s->_normalize_ids($ids);
  return $s->_delete_links($parent_cols, $parent, $cols, [map { $n->{$_}[0] } sort keys %$n]);
}

sub _delete_links {
  my ($s, $parent_cols, $parent, $cols, $tuples) = @_;
  my @pending = @$tuples;
  return 0 unless @pending;
  my $max = int(400 / @$cols) || 1;
  $max = 100 if $max > 100;
  return $s->parent->connection->transaction(sub {
    my $n = 0;
    while (my @batch = splice @pending, 0, $max) {
      my $q = $s->_pq->where(_pairs_hash($parent_cols, $parent));
      $q->_and_constraint(sub {
        my $f = shift;
        if (@$cols == 1) { $f->where_in($cols->[0], [map { $_->[0] } @batch]) }
        else { $f->or_where(_pairs_hash($cols, $_)) for @batch }
      });
      $n += $q->delete;
    }
    return $n;
  });
}

sub sync {
  my ($s, $ids) = @_;
  return $s->parent->connection->transaction(sub { $s->_sync($ids) });
}

sub _sync {
  my ($s, $ids) = @_;
  my ($parent_cols, $parent) = $s->_parent_pivot;
  my ($cols, $keys, $want) = $s->_normalize_ids($ids);
  my $current = $s->_pq->where(_pairs_hash($parent_cols, $parent))->get(@$cols);
  my %have = map {
    my @tuple = @{$_}{@$cols};
    (@$keys == 1 ? $tuple[0] : $s->_tuple_key(\@tuple)) => \@tuple;
  } @$current;
  my @detach = grep { !exists $want->{$_} } sort keys %have;
  my @attach = grep { !$have{$_} } sort keys %$want;
  $s->_delete_links($parent_cols, $parent, $cols, [map { $have{$_} } @detach]);
  $s->_insert_links($parent_cols, $parent, $cols, [map { $want->{$_} } @attach]);
  return { attached => \@attach, detached => \@detach } if @$keys == 1;
  return {
    attached => [map { _pairs_hash($keys, $want->{$_}[0]) } @attach],
    detached => [map { _pairs_hash($keys, $have{$_}) } @detach],
  };
}

1;
