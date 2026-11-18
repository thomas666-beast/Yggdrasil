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
  $q->_and_constraint(sub { $s->add_constraints($_[0]) });
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
    push @all, @{$q->get};
  }
  return \@all;
}

sub _keys {
  my ($s, $models, $attr) = @_;
  my %seen;
  return [grep { defined $_ && !$seen{$_}++ } map { $_->attributes->{$attr} } @$models];
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
