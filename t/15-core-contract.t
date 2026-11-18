use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

BEGIN {
  unshift @INC, sub { die "unexpected Mojolicious dependency: $_[1]" if $_[1] =~ /\A(?:Mojo|Mojolicious)(?:\.pm|\/)/; return };
}
use Yggdrasil;
use Yggdrasil::Collection;
use JSON::PP ();

{
  package Fixture::Model::Parent;
  use Moo;
  extends 'Yggdrasil::Model';
  sub table { 'parents' }
  sub timestamps { 0 }
  sub children { shift->has_many('Child', 'parent_id') }
  sub tags { shift->belongs_to_many('Tag', 'parent_tag', 'parent_id', 'tag_id') }
}
{
  package Fixture::Model::Child;
  use Moo;
  extends 'Yggdrasil::Model';
  with 'Yggdrasil::Role::SoftDeletes';
  sub table { 'children' }
  sub timestamps { 0 }
}
{
  package Fixture::Model::Tag;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
}

my $sqlite = { driver => 'sqlite', database => ':memory:' };
my @targets = (['SQLite', $sqlite]);
push @targets, ['PostgreSQL', { url => $ENV{YGGDRASIL_TEST_PG} }] if $ENV{YGGDRASIL_TEST_PG};
push @targets, ['MariaDB/MySQL', { url => $ENV{YGGDRASIL_TEST_MYSQL},
  options => $ENV{YGGDRASIL_TEST_MYSQL_TLS} ? { mysql_ssl => 1 } : {} }] if $ENV{YGGDRASIL_TEST_MYSQL};

sub manager { Yggdrasil->new(connections => { default => $_[0], alternate => $sqlite }, model_namespaces => ['Fixture::Model']) }
sub build_schema {
  my ($orm, $name) = @_;
  my $db = $orm->db($name);
  my $schema = $db->schema;
  $schema->drop_if_exists($_) for qw(parent_tag children parents tags);
  $schema->create('parents', sub { my $t = shift; $t->id; $t->string('name') });
  $schema->create('children', sub { my $t = shift; $t->id; $t->integer('parent_id'); $t->integer('rank'); $t->string('name'); $t->soft_deletes });
  $schema->create('tags', sub { my $t = shift; $t->id; $t->string('name') });
  $schema->create('parent_tag', sub {
    my $t = shift;
    $t->foreign_id('parent_id')->constrained('parents');
    $t->foreign_id('tag_id')->constrained('tags');
  });
}

subtest 'standalone API, isolated managers and collection' => sub {
  my ($left, $right) = (manager($sqlite), manager($sqlite));
  ok !Yggdrasil->instance, 'no implicit process-global context';
  build_schema($left);
  build_schema($right);
  build_schema($left, 'alternate');
  my $parent = $left->create_model('Parent', { name => 'A' });
  $left->create_model('Child', { name => 'a-child', rank => 1, parent_id => $parent->id });
  $left->create_model('Parent', { name => 'Alternate' }, using => 'alternate');
  $left->create_model('Child', { name => 'alt-child', rank => 1, parent_id => 1 }, using => 'alternate');
  $right->create_model('Parent', { name => 'B' });
  $right->create_model('Child', { name => 'b-child', rank => 1, parent_id => 1 });
  Yggdrasil->set_instance($right);
  my $row = $left->model_query('Parent')->include('children')->find(1);
  is $row->related('children')->first->name, 'a-child', 'eager relation is bound to its own manager';
  is $row->to_hash->{children}[0]{name}, 'a-child', 'collection serialized with nested models';
  is $parent->children->first->name, 'a-child', 'lazy relation uses parent manager';
  is $left->model_query('Parent', using => 'alternate')->first->children->first->name, 'alt-child', 'relation inherits named connection';
  $row->name('Changed')->save;
  is $row->fresh->name, 'Changed', 'fresh and save use originally bound connection';
  is $right->model_query('Parent')->find(1)->name, 'B', 'other database untouched';
  is $row->replicate->name('Copy')->save->fresh->name, 'Copy', 'replication preserves the binding';
  my $alt_parent = $left->model_query('Parent', using => 'alternate')->first;
  my $created = $alt_parent->children->create({ name => 'created-on-alt', rank => 1 });
  is $created->fresh->name, 'created-on-alt', 'relation create writes to the parent connection';
  is $left->model_query('Child')->count, 1, 'default connection unaffected by alternate relation creation';
  my $other_child = $right->model_query('Child')->first;
  eval { $alt_parent->children->save($other_child) };
  like $@, qr/across connections/, 'cannot move an existing model across databases via a relation';
  $row->set_attribute(id => 2);
  eval { $row->delete };
  like $@, qr/cannot change the primary key/, 'editing an instance primary key cannot redirect a delete';
  is $left->model_query('Parent')->find(2)->name, 'Copy', 'other row remains intact';
  my $c = Yggdrasil::Collection->new(2, 3, 2, 1);
  isa_ok $left->table('parents')->get, 'Yggdrasil::Collection';
  is_deeply $c->uniq->sort(sub { $a <=> $b })->map(sub { $_ * 2 })->to_array, [2, 4, 6], 'chainable array collection';
  is_deeply(Yggdrasil::Collection->new([1, [2]], 3)->flatten->to_array, [1, 2, 3], 'flatten nested arrays');
  is $c->first(sub { $_ == 3 }), 3, 'first predicate';
  is(JSON::PP->new->convert_blessed->encode($c), '[2,3,2,1]', 'collection JSON representation');
  ok !(grep { /\A(?:Mojo|Mojolicious)(?:\.pm|\/)/ } keys %INC), 'no Mojo modules loaded';
  Yggdrasil->set_instance(undef);
};

for my $target (@targets) {
  my ($label, $config) = @$target;
  subtest "$label: keysets, filters and atomic writes" => sub {
    my $orm = manager($config);
    build_schema($orm);
    my $p = $orm->create_model('Parent', { name => 'parent' });
    my $other = $orm->create_model('Parent', { name => 'other' });
    my $db = $orm->db;
    $orm->table('children')->insert([
      { id => 1, parent_id => $p->id, rank => 4, name => 'a' },
      { id => 2, parent_id => $p->id, rank => 4, name => 'b' },
      { id => 3, parent_id => $p->id, rank => 3, name => 'c' },
      { id => 4, parent_id => $p->id, rank => 3, name => 'deleted', deleted_at => '2026-01-01 00:00:00' },
      { id => 5, parent_id => $other->id, rank => 2, name => 'other' },
      { id => 6, parent_id => $p->id, rank => 1, name => 'f' },
    ]);
    my $q = $orm->model_query('Child')->where(parent_id => $p->id)->or_where(name => 'deleted');
    my $order = [[rank => 'desc'], 'id'];
    $db->enable_query_log;
    my $page = $q->cursor_page(size => 2, order => $order);
    is_deeply [map { 0 + $_->id } @{$page->items}], [1, 2], 'descending key and ascending tiebreaker';
    is_deeply [map { 0 + $_ } @{$page->next_cursor}], [4, 2], 'continuation is the last visible tuple';
    is scalar @{$db->query_log}, 1, 'one query and no count for a simple cursor page';
    like $db->query_log->[0]{query}, qr/limit 3\z/, 'bounded lookahead';
    my $next = $q->cursor_page(size => 2, order => $order, after => $page->next_cursor);
    is_deeply [map { 0 + $_->id } @{$next->items}], [3, 6], 'continuation respects OR and soft-delete scope';
    ok !defined $next->next_cursor, 'exact cut at end has no cursor';
    ok !defined $q->get_limit, 'query is reusable';
    ok !defined $q->find(4), 'primary-key lookup cannot bypass previous filters or soft deletes';
    is $p->children->where(name => 'a')->or_where(name => 'other')->count, 1, 'OR cannot escape a relationship';
    is $q->update({ rank => 9 }), 4, 'scoped write affects only matching active rows';
    is $orm->table('children')->where(id => 4)->value('rank'), 3, 'trashed row was not updated';
    for my $guard (
      [sub { $q->cursor_page(order => ['id'], after => []) }, qr/cursor values/],
      [sub { $q->cursor_page(order => ['id'], size => 1001) }, qr/must not exceed/],
      [sub { $q->clone->select('name')->cursor_page(size => 2, order => ['id']) }, qr/select all cursor/],
      [sub { $orm->table('children')->limit(1)->update({ rank => 0 }) }, qr/update cannot use/],
      [sub { $orm->table('children')->offset(1)->delete }, qr/delete cannot use/],
      [sub { $orm->table('children')->where(id => 1)->truncate }, qr/unfiltered/],
      [sub { $orm->table('children')->where(id => 1)->increment('rank', 'Inf') }, qr/finite/],
      [sub { $q->paginate(0, 1) }, qr/positive integer/],
    ) { eval { $guard->[0]->() }; like $@, $guard->[1] }
    $orm->table('children')->where(id => 1)->increment('rank', 3);
    is $orm->table('children')->where(id => 1)->value('rank'), 12, 'bound increment works';
    my $offset_page = $q->clone->order_by('id')->limit(1)->paginate(2, 4);
    is $offset_page->total, 4, 'offset pagination replaces prior limits consistently';
    ok !defined $offset_page->from && !defined $offset_page->to, 'empty page has no range';
    my $tag = $orm->create_model('Tag', { name => 'tag' });
    $p->tags->attach($tag);
    eval { $p->tags->sync([19999]) };
    ok $@, 'invalid sync is rejected by foreign key';
    is $p->tags->count, 1, 'prior pivot link survives failed sync';
    $db->disable_query_log;
    $orm->disconnect_all;
  };
}

subtest 'driver and transaction lifecycle' => sub {
  my @logs;
  my $conn = manager($sqlite)->db;
  $conn->logger(sub { push @logs, [@_] });
  is $conn->select_one('select ? as value', 'private-value')->{value}, 'private-value', 'one-row read returns data';
  unlike $logs[0][0], qr/private-value/, 'logger redacts bindings by default';
  is_deeply $logs[0][2], [], 'logger callback does not receive private bindings by default';
  my @contexts;
  $conn->transaction(sub { push @contexts, defined wantarray ? 1 : 0 });
  is_deeply \@contexts, [0], 'transaction respects void context';
  my $nested = $conn->pretend(sub {
    $conn->statement('outer');
    my $inner = $conn->pretend(sub { $conn->statement('inner') });
    is $inner->[0]{query}, 'inner', 'nested pretend records its own statements';
    $conn->statement('outer again');
  });
  is_deeply [map { $_->{query} } @$nested], ['outer', 'outer again'], 'outer pretend is restored';
  eval { $conn->transaction(sub { $conn->disconnect }) };
  like $@, qr/during a transaction/, 'disconnect cannot silently lose an active transaction';
  is $conn->select_one('select 1 as n')->{n}, 1, 'connection remains usable';

  $conn->statement('create table tx_parent (id integer primary key)');
  $conn->statement('create table tx_child (id integer references tx_parent(id) deferrable initially deferred)');
  eval { $conn->transaction(sub { $conn->statement('insert into tx_child values (999)') }) };
  like $@, qr/FOREIGN KEY constraint failed/i, 'commit-time failure propagates';
  is $conn->table('tx_child')->count, 0, 'commit-time failure rolled back';

  my $maria = manager({url => 'mariadb://localhost/db'})->db;
  my ($dsn) = $maria->_connect_info;
  like $dsn, qr/\Adbi:MariaDB:/, 'mariadb URI chooses DBD::MariaDB';
};

subtest 'migration previews never create the repository' => sub {
  my $orm = manager($sqlite);
  my $dir = tempdir('migration files XXXX', TMPDIR => 1, CLEANUP => 1);
  my $m = $orm->migrator(undef, paths => [$dir]);
  $m->make('make_widgets', create => 'widgets');
  is scalar @{$m->status}, 1, 'status sees file in directory with spaces';
  is scalar @{$m->run(pretend => 1)}, 1, 'preview reports pending SQL';
  is_deeply $m->rollback(pretend => 1), [], 'preview rollback of a fresh database is empty';
  ok !$orm->schema->has_table($m->table), 'no migration repository written';
  ok !$orm->schema->has_table('widgets'), 'no app DDL executed';
  $m->run;
  eval { $m->fresh(pretend => 1) };
  like $@, qr/does not support pretend/, 'destructive unsupported preview is refused';
  ok $orm->schema->has_table('widgets'), 'data schema untouched';
};

done_testing;
