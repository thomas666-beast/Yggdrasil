package Yggdrasil::Relation::HasOneOrMany;
use Moo;
use Carp ();
use Scalar::Util qw(refaddr);
extends 'Yggdrasil::Relation';

has foreign_key => (is => 'ro', required => 1);   # column on the related table
has local_key   => (is => 'ro', required => 1);   # column on the parent

sub _pair { $_[0]->_key_pair($_[0]->foreign_key, $_[0]->local_key) }
sub BUILD { shift->_pair }
sub _existence_link {
  my ($s, $q, $inner, $outer) = @_;
  my ($foreign, $local) = $s->_pair;
  $q->where_column("$inner.$foreign->[$_]", "$outer.$local->[$_]") for 0 .. $#$foreign;
}

sub parent_value {
  my $s = shift;
  my (undef, $local) = $s->_pair;
  my $tuple = $s->_tuple($s->parent, $local) // return undef;
  return @$tuple == 1 ? $tuple->[0] : $tuple;
}

sub add_constraints {
  my ($s, $q) = @_;
  my ($foreign, $local) = $s->_pair;
  return $s->_where_tuple($q, [map { $s->related->table . ".$_" } @$foreign], $s->_tuple($s->parent, $local));
}

sub _assign_parent {
  my ($s, $m) = @_;
  my ($foreign, $local) = $s->_pair;
  $m->set_attribute($foreign->[$_], $s->parent->attributes->{$local->[$_]}) for 0 .. $#$foreign;
  return $m;
}

sub make {
  my ($s, $attrs) = @_;
  my $q = $s->_related_query;
  my $m = $q->manager->make_model($s->related, $attrs, using => $q->connection->name);
  return $s->_assign_parent($m);
}
sub create {
  my ($s, $attrs) = @_;
  Carp::croak('Yggdrasil: cannot create related rows on an unsaved parent') unless $s->parent->in_storage && defined $s->parent_value;
  $s->parent->_stored_key;
  return $s->make($attrs)->save;
}
sub save {
  my ($s, $m) = @_;
  Carp::croak('Yggdrasil: cannot save related rows on an unsaved parent') unless $s->parent->in_storage && defined $s->parent_value;
  $s->parent->_stored_key;
  my $q = $s->_related_query;
  if ($m->in_storage || $m->_bound_manager || $m->_bound_connection) {
    Carp::croak('Yggdrasil: cannot save a related model across connections')
      unless refaddr($m->connection) == refaddr($q->connection);
  }
  $m->_bound_manager($q->manager);
  $m->_bound_connection($q->connection);
  $m->using($q->connection->name);
  return $s->_assign_parent($m)->save;
}

sub _group {
  my ($s, $models, $cb) = @_;
  my ($foreign, $local) = $s->_pair;
  my %by;
  for my $child (@{$s->_fetch_tuples($models, $local, $foreign, $cb)}) {
    my $tuple = $s->_tuple($child, $foreign) // next;
    push @{$by{$s->_tuple_key($tuple)}}, $child;
  }
  return (\%by, $local);
}

sub _group_for {
  my ($s, $groups, $parent, $local) = @_;
  my $tuple = $s->_tuple($parent, $local) // return [];
  return $groups->{$s->_tuple_key($tuple)} // [];
}

1;
