package Yggdrasil::Relation::HasMany;
use Moo;
use Yggdrasil::Collection;
extends 'Yggdrasil::Relation::HasOneOrMany';

sub results { $_[0]->get }

sub eager_load {
  my ($s, $models, $name, $cb) = @_;
  my ($by, $local) = $s->_group($models, $cb);
  $_->set_relation($name, Yggdrasil::Collection->new(@{$s->_group_for($by, $_, $local)})) for @$models;
}

1;
