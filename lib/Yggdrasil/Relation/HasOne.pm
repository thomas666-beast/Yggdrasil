package Yggdrasil::Relation::HasOne;
use Moo;
extends 'Yggdrasil::Relation::HasOneOrMany';

sub results { $_[0]->first }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my ($by, $local) = $s->_group($models, $cb);
  $_->set_relation($name, $s->_group_for($by, $_, $local)->[0]) for @$models;
}

1;
