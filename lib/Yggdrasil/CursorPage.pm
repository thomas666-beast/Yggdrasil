package Yggdrasil::CursorPage;
use Moo;

has items       => (is => 'ro', required => 1);
has next_cursor => (is => 'ro');
sub has_more_pages { defined $_[0]->next_cursor ? 1 : 0 }
sub TO_JSON { +{ data => $_[0]->items->to_array, next_cursor => $_[0]->next_cursor } }

1;
