package Yggdrasil::Relation::BelongsTo;
use Moo;
extends 'Yggdrasil::Relation';

has foreign_key => (is => 'ro', required => 1);   # column on the parent
has owner_key   => (is => 'ro', required => 1);   # column on the related table

sub _pair { $_[0]->_key_pair($_[0]->foreign_key, $_[0]->owner_key) }
sub BUILD { shift->_pair }
sub _existence_link {
  my ($s, $q, $inner, $outer) = @_;
  my ($foreign, $owner) = $s->_pair;
  $q->where_column("$inner.$owner->[$_]", "$outer.$foreign->[$_]") for 0 .. $#$foreign;
}

sub add_constraints {
  my ($s, $q) = @_;
  my ($foreign, $owner) = $s->_pair;
  return $s->_where_tuple($q, [map { $s->related->table . ".$_" } @$owner], $s->_tuple($s->parent, $foreign));
}

sub results { $_[0]->first }

sub associate {
  my ($s, $model) = @_;
  my ($foreign, $owner) = $s->_pair;
  $s->parent->set_attribute($foreign->[$_], $model ? $model->attributes->{$owner->[$_]} : undef) for 0 .. $#$foreign;
  return $s->parent;
}
sub dissociate { $_[0]->associate(undef) }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my ($foreign, $owner) = $s->_pair;
  my %by;
  for my $row (@{$s->_fetch_tuples($models, $foreign, $owner, $cb)}) {
    my $tuple = $s->_tuple($row, $owner) // next;
    $by{$s->_tuple_key($tuple)} = $row;
  }
  for my $row (@$models) {
    my $tuple = $s->_tuple($row, $foreign);
    $row->set_relation($name, defined $tuple ? $by{$s->_tuple_key($tuple)} : undef);
  }
}

1;
