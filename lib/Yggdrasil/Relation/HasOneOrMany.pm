package Yggdrasil::Relation::HasOneOrMany;
use Moo;
use Carp ();
use Scalar::Util qw(refaddr);
extends 'Yggdrasil::Relation';

has foreign_key => (is => 'ro', required => 1);   # column on the related table
has local_key   => (is => 'ro', required => 1);   # column on the parent

sub parent_value { $_[0]->parent->attributes->{$_[0]->local_key} }

sub add_constraints {
  my ($s, $q) = @_;
  my $v = $s->parent_value;
  defined $v ? $q->where($s->related->table . '.' . $s->foreign_key, $v) : $q->where_raw('0 = 1');
}

sub make {
  my ($s, $attrs) = @_;
  my $q = $s->_related_query;
  my $m = $q->manager->make_model($s->related, $attrs, using => $q->connection->name);
  $m->set_attribute($s->foreign_key, $s->parent_value);
  return $m;
}
sub create {
  my ($s, $attrs) = @_;
  Carp::croak('Yggdrasil: cannot create related rows on an unsaved parent') unless $s->parent->in_storage && defined $s->parent_value;
  return $s->make($attrs)->save;
}
sub save {
  my ($s, $m) = @_;
  Carp::croak('Yggdrasil: cannot save related rows on an unsaved parent') unless $s->parent->in_storage && defined $s->parent_value;
  my $q = $s->_related_query;
  if ($m->in_storage || $m->_bound_manager || $m->_bound_connection) {
    Carp::croak('Yggdrasil: cannot save a related model across connections')
      unless refaddr($m->connection) == refaddr($q->connection);
  }
  $m->_bound_manager($q->manager);
  $m->_bound_connection($q->connection);
  $m->using($q->connection->name);
  return $m->set_attribute($s->foreign_key, $s->parent_value)->save;
}

sub _group {
  my ($s, $models) = @_;
  my $keys = $s->_keys($models, $s->local_key);
  my $fk = $s->foreign_key;
  my %by;
  push @{$by{$_->attributes->{$fk}}}, $_ for @{$s->_fetch_in($s->related->table . ".$fk", $keys, $s->{_cb})};
  return \%by;
}

1;
