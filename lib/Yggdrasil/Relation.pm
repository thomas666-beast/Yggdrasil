package Yggdrasil::Relation;
use Moo;
use Carp ();
use Scalar::Util qw(blessed refaddr);

our $AUTOLOAD;

has parent  => (is => 'ro', required => 1);
has related => (is => 'ro', required => 1);        # related model class
has query   => (is => 'lazy');

sub _build_query {
  my $s = shift;
  my $q = $s->_related_query;
  $q->_and_constraint(sub { $s->add_constraints($_[0]) }) unless $s->parent->_relation_probe;
  return $q;
}

sub _related_query {
  my $s = shift;
  my $parent = $s->parent;
  my $related = $s->related;
  return $related->query(manager => $parent->manager,
    using => $related->connection_name // $parent->connection->name);
}

sub add_constraints { }
sub _existence_link { Carp::croak('Yggdrasil: where_has does not support this relation type') }
sub _post { }                     # hook: post-process loaded models (arrayref)

sub get {
  my $s = shift;
  my $c = $s->query->get(@_);
  $s->_post([@$c]);
  return $c;
}

sub first {
  my $s = shift;
  my $m = $s->query->first(@_);
  $s->_post([$m]) if $m;
  return $m;
}

# fetch related models whose $column is in @keys (in chunks, to keep placeholder counts sane)
sub _fetch_in {
  my ($s, $column, $keys, $cb, $prepare) = @_;
  my @all;
  my @k = @$keys;
  while (my @chunk = splice @k, 0, 500) {
    my $q = $s->_related_query;
    $prepare->($q) if $prepare;
    $q->_and_constraint(sub { $_[0]->where_in($column, \@chunk) });
    $cb->($q) if $cb;
    push @all, @{$q->_eager_batch([$column], scalar @chunk)};
  }
  return \@all;
}

sub _keys {
  my ($s, $models, $attr) = @_;
  my %seen;
  return [grep { defined $_ && !$seen{$_}++ } map { $_->attributes->{$attr} } @$models];
}

sub _key_pair {
  my ($s, $left, $right) = @_;
  my @pair = map { ref $_ eq 'ARRAY' ? [@$_] : [$_] } ($left, $right);
  for my $cols (@pair) {
    my %seen;
    Carp::croak('Yggdrasil: relationship keys must name distinct columns')
      if !@$cols || grep { !defined $_ || ref $_ || !/\A[A-Za-z_][A-Za-z_0-9]*\z/ || $seen{$_}++ } @$cols;
  }
  Carp::croak('Yggdrasil: relationship needs matching foreign and local key columns')
    unless @{$pair[0]} == @{$pair[1]};
  return @pair;
}

sub _tuple {
  my ($s, $model, $cols) = @_;
  my @values = @{$model->attributes}{@$cols};
  return undef if grep { !defined $_ || ref $_ } @values;
  return \@values;
}

# Length prefixes prevent collisions between tuples with delimiter-like values.
sub _tuple_key { CORE::join('', map { length($_) . ':' . $_ } @{$_[1]}) }

sub _where_tuple {
  my ($s, $q, $cols, $tuple) = @_;
  return $q->where_raw('0 = 1') unless defined $tuple;
  $q->where($cols->[$_], $tuple->[$_]) for 0 .. $#$cols;
  return $q;
}

sub _fetch_tuples {
  my ($s, $models, $from, $to, $cb, $prepare, $target) = @_;
  $target //= $s->related->table;
  my @qualified = map { "$target.$_" } @$to;
  if (@qualified == 1) {
    return $s->_fetch_in($qualified[0], $s->_keys($models, $from->[0]), $cb, $prepare);
  }
  my (@tuples, %seen, @all);
  for my $model (@$models) {
    my $tuple = $s->_tuple($model, $from) // next;
    push @tuples, $tuple unless $seen{$s->_tuple_key($tuple)}++;
  }
  my $batch = int(500 / @qualified) || 1;
  $batch = 100 if $batch > 100;
  while (my @part = splice @tuples, 0, $batch) {
    my $q = $s->_related_query;
    $prepare->($q) if $prepare;
    $q->_and_constraint(sub {
      my $filter = shift;
      for my $tuple (@part) {
        $filter->or_where(sub { $s->_where_tuple($_[0], \@qualified, $tuple) });
      }
    });
    $cb->($q) if $cb;
    push @all, @{$q->_eager_batch(\@qualified, scalar @part)};
  }
  return \@all;
}

sub AUTOLOAD {
  my $s = shift;
  (my $n = $AUTOLOAD) =~ s/.*:://;
  return if $n eq 'DESTROY';
  my $q = $s->query;
  Carp::croak(qq{Can't locate method "$n" on } . ref $s)
    unless $q->can($n) || $s->related->can("scope_$n");
  my $r = $q->$n(@_);
  return blessed $r && refaddr $r == refaddr $q ? $s : $r;
}

{
  no strict 'refs'; no warnings 'redefine';
  *{__PACKAGE__ . '::with'} = sub { my $s = shift; $s->include(@_) };   # Moo exports `with`; forward to the query instead
}

1;
