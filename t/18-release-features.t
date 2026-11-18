use strict;
use warnings;
use File::Temp qw(tempdir);
use POSIX ();
use Test::More;
use Yggdrasil;
use Yggdrasil::Migrator;

{
  package ReleaseFixture::Post;
  use Moo;
  extends 'Yggdrasil::Model';
  with 'Yggdrasil::Role::SoftDeletes';
  sub table { 'release_posts' }
  sub timestamps { 0 }
  sub primary_key { [qw(tenant_id post_no)] }
  sub fillable { [qw(tenant_id post_no slug score)] }
  sub comments { $_[0]->has_many('Comment', [qw(tenant_id post_no)]) }
  sub scored { $_[0]->comments->where('rating', '>', 0) }
  sub tags {
    $_[0]->belongs_to_many('Tag', 'release_post_tag', [qw(tenant_id post_no)], [qw(tenant_id tag_no)])
      ->with_pivot('label');
  }
}
{
  package ReleaseFixture::Comment;
  use Moo;
  extends 'Yggdrasil::Model';
  with 'Yggdrasil::Role::SoftDeletes';
  sub table { 'release_comments' }
  sub timestamps { 0 }
  sub post { $_[0]->belongs_to('Post', [qw(tenant_id post_no)]) }
  sub replies { $_[0]->has_many('Comment', 'reply_to') }
}
{
  package ReleaseFixture::Tag;
  use Moo;
  extends 'Yggdrasil::Model';
  sub table { 'release_tags' }
  sub primary_key { [qw(tenant_id tag_no)] }
  sub timestamps { 0 }
}

my $dir = tempdir(CLEANUP => 1);
my @targets = (['SQLite', { driver => 'sqlite', database => "$dir/release.sqlite" }]);
push @targets, ['PostgreSQL', { url => $ENV{YGGDRASIL_TEST_PG} }] if $ENV{YGGDRASIL_TEST_PG};
push @targets, ['MariaDB/MySQL', { url => $ENV{YGGDRASIL_TEST_MYSQL},
  options => $ENV{YGGDRASIL_TEST_MYSQL_TLS} ? { mysql_ssl => 1 } : {} }] if $ENV{YGGDRASIL_TEST_MYSQL};
for my $target (@targets) {
  subtest $target->[0] => sub {
    my $make = sub { Yggdrasil->new(connections => { default => $target->[1] }, model_namespaces => ['ReleaseFixture']) };
    my $orm = $make->();
    my $db = $orm->db;
    my $schema = $orm->schema;
    my @tables = qw(release_post_tag release_comments release_tags release_posts);
    $schema->drop_if_exists($_) for @tables;
    $schema->create('release_posts', sub {
      my $t = shift;
      $t->integer($_) for qw(tenant_id post_no score);
      $t->string('slug')->unique;
      $t->primary([qw(tenant_id post_no)]);
      $t->soft_deletes;
    });
    $schema->create('release_comments', sub {
      my $t = shift;
      $t->id;
      $t->integer($_) for qw(tenant_id post_no rating);
      $t->big_integer('reply_to')->nullable;
      $t->foreign([qw(tenant_id post_no)])->references(qw(tenant_id post_no))->on('release_posts');
      $t->soft_deletes;
    });
    $schema->create('release_tags', sub {
      my $t = shift;
      $t->integer($_) for qw(tenant_id tag_no);
      $t->primary([qw(tenant_id tag_no)]);
    });
    $schema->create('release_post_tag', sub {
      my $t = shift;
      $t->integer($_) for qw(tenant_id post_no tag_no);
      $t->string('label')->nullable;
      $t->primary([qw(tenant_id post_no tag_no)]);
      $t->foreign([qw(tenant_id post_no)])->references(qw(tenant_id post_no))->on('release_posts');
      $t->foreign([qw(tenant_id tag_no)])->references(qw(tenant_id tag_no))->on('release_tags');
    });
    my $identity = sub { +{ tenant_id => $_[0], post_no => 7 } };
    my ($a, $b, $empty) = map { $orm->first_or_create_model('Post', $identity->($_), {slug => "post-$_", score => 1}) } 1 .. 3;
    my $posts = sub { $orm->model_query('Post') };
    for my $post ($a, $b) {
      $post->comments->create({ rating => 11 - $_ }) for 0 .. 11;
    }
    my $top = $a->comments->order_by_desc('rating')->first;
    $b->comments->create({ rating => -1, reply_to => $top->id });
    $b->comments->create({ rating => 99 })->delete;
    $db->enable_query_log;
    my $records = $posts->()->order_by('tenant_id')->with(comments => sub {
      $_[0]->order_by_desc('rating')->limit(10);
    })->get;
    is_deeply [map { $_->related('comments')->size } @$records], [10, 10, 0], 'limit ten per parent';
    is_deeply [map { $_->rating } @{$records->[1]->related('comments')}], [reverse 2 .. 11], 'order and soft-delete scope';
    is scalar @{$db->query_log}, 2, 'two queries for three posts';
    like $db->query_log->[1]{query}, qr/row_number\(\)/i, 'database limits related rows';
    $db->disable_query_log;
    my $paged = $posts->()->with('comments.post', comments => sub { $_[0]->order_by_desc('rating')->limit(2)->offset(2) })
      ->order_by('tenant_id')->get;
    is_deeply [map { $_->rating } @{$paged->[0]->related('comments')}], [9, 8], 'per-parent offset and nested load coexist';
    is $paged->[1]->related('comments')->first->related('post')->tenant_id, 2, 'nested relationship uses the right tenant';
    is $posts->()->with(comments => sub { $_[0]->limit(0) })->find($identity->(1))->related('comments')->size, 0, 'zero limit';
    is $posts->()->with(comments => sub { $_[0]->limit(1) })->find($identity->(1))->related('comments')->first->id, $top->id, 'single-parent default key order';

    is_deeply [map { $_->tenant_id } @{$posts->()->where_has('comments.replies', sub { $_[0]->where(rating => -1) })->get}],
      [1], 'nested and self relationships bind and correlate correctly';
    is $posts->()->where_has('scored', sub { $_[0]->where(rating => -1) })->count, 0, 'relationship filter preserved';
    is $posts->()->where_has('comments', sub { $_[0]->where(rating => 99) })->count, 0, 'exists respects soft deletes';
    is $posts->()->where_doesnt_have('comments')->first->tenant_id, 3, 'not exists';
    is $posts->()->where(slug => 'post-3')->or_where_has('comments', sub { $_[0]->where(rating => -1) })->count, 2, 'OR binds in order';
    eval { $posts->()->where_has('comments', sub { $_[0]->limit(1) }) };
    like $@, qr/does not accept/, 'unsupported existence query fails early';
    eval { $posts->()->where_has('create') };
    like $@, qr/not a relation/, 'existence filters do not invoke ORM methods as relations';
    eval { $posts->()->with('create')->get };
    like $@, qr/not a relation/, 'eager loads do not invoke ORM methods as relations';

    $db->table('release_tags')->insert([map { +{ tenant_id => $_->[0], tag_no => $_->[1] } } [1, 1], [1, 2], [2, 1]]);
    $a->tags->attach([{tenant_id => 1, tag_no => 1}, {tenant_id => 1, tag_no => 2}], {label => 'public'});
    my $tag = $orm->model_query('Tag')->find({tenant_id => 2, tag_no => 1});
    $b->tags->attach($tag, {label => 'private'});
    is $a->tags->count, 2, 'direct pivot query';
    is $a->tags->first->pivot->{label}, 'public', 'lazy pivot payload';
    my $tagged = $posts->()->where_has('tags')->with(tags => sub { $_[0]->order_by_desc('release_tags.tag_no')->limit(1) })
      ->order_by('tenant_id')->get;
    is_deeply [map { $_->related('tags')->first->get_key } @$tagged],
      [{tenant_id => 1, tag_no => 2}, {tenant_id => 2, tag_no => 1}], 'limited compound pivots isolate parents';
    is $tagged->[1]->related('tags')->first->pivot->{label}, 'private', 'eager pivot payload';
    eval { $a->tags->attach($tag) };
    like $@, qr/conflicting values/, 'cannot link different tenants through a shared pivot column';
    is $a->tags->detach({tenant_id => 1, tag_no => 2}), 1, 'detach uses exact tuple';
    my $change = $a->tags->sync([{tenant_id => 1, tag_no => 2}]);
    is $a->tags->first->tag_no, 2, 'sync updates links';
    is $b->tags->count, 1, 'other tenant untouched';

    is $orm->first_or_create_model('Post', $identity->(1), {slug => 'ignored', score => 8})->score, 1, 'existing row is not updated';
    is $a->update_or_create_atomic($identity->(1), {slug => 'post-1', score => 8})->score, 8, 'locked update returns fresh row';
    eval { $orm->first_or_create_model('Post', $identity->(4), {slug => 'post-2', score => 8}) };
    ok $@, 'unrelated unique violation does not become a false success';
    eval { $orm->update_or_create_model('Post', $identity->(1), {slug => 'post-2', score => 8}) };
    ok $@, 'conflicting updates are not swallowed';
    eval { $orm->first_or_create_model('Post', $identity->(4), {slug => 'not-null'}) };
    like "$@", qr/null|default/i, 'missing required column is not swallowed';
    eval { $orm->update_or_create_model('Post', {slug => 'post-1'}, {tenant_id => 2, score => 5}) };
    like "$@", qr/cannot change primary key/, 'updates cannot mutate storage key';
    eval { $orm->first_or_create_model('Post', {score => 1}, {slug => 'another', tenant_id => 1, post_no => 11}) };
    like "$@", qr/unique|on conflict/i, 'nonunique identity rejected';
    $empty->delete;
    eval { $orm->first_or_create_model('Post', $identity->(3), {slug => 'replacement', score => 1}) };
    like "$@", qr/no visible row/, 'soft-deleted identity is not revived';

    SKIP: {
      skip 'fork unavailable', 3 if $^O eq 'MSWin32';
      pipe my $r, my $w or die "pipe: $!";
      my $pid = fork;
      skip 'fork unavailable', 3 unless defined $pid;
      unless ($pid) {
        close $w;
        sysread $r, my $go, 1;
        my $ok = eval { $make->()->first_or_create_model('Post', $identity->(5), {slug => 'race', score => 2}); 1 };
        diag "$@" unless $ok;
        POSIX::_exit($ok ? 0 : 1);
      }
      close $r;
      syswrite $w, '1';
      close $w;
      my $race = eval { $orm->first_or_create_model('Post', $identity->(5), {slug => 'race', score => 1}) };
      ok $race, 'parent can use atomic create in a race';
      waitpid $pid, 0;
      is $?, 0, 'independent process can use atomic create in a race';
      is $posts->()->where($identity->(5))->count, 1, 'only one row created';
    }

    my $m = $orm->migrator;
    my $other = $make->();
    eval { $m->_with_lock(sub {
      eval { Yggdrasil::Migrator->new(connection => $other->db, table => 'other_migrations')->run };
      like "$@", qr/migration lock is busy/, 'second runner cannot enter even with another tracking table';
      eval { $db->disconnect };
      like "$@", qr/pinned/, 'migration session cannot be disconnected';
      die "test release\n";
    }) };
    like "$@", qr/test release/, 'migration error is preserved';
    is_deeply $other->migrator->run, [], 'another runner can enter after an exception';
    $other->disconnect_all;

    my $import = $orm->schema_importer;
    my $metadata = $import->describe('release_comments');
    is_deeply $metadata->{primary}, ['id'], 'import reads the primary key';
    ok $metadata->{incrementing}, 'import detects generated keys';
    is_deeply $metadata->{foreign_keys}, [{table => 'release_posts', local => [qw(tenant_id post_no)], remote => [qw(tenant_id post_no)]}], 'import reads FK in order';
    my $out = tempdir(CLEANUP => 1);
    my $namespace = 'Imported::' . ucfirst $db->driver;
    my %options = (namespace => $namespace, directory => $out, table => 'release_comments');
    my $preview = $import->generate(%options, pretend => 1)->[0];
    ok !-e $preview->{file}, 'preview writes no file';
    my $saved = $import->generate(%options)->[0];
    ok -f $saved->{file}, 'import generated model';
    require $saved->{file};
    is "${namespace}::ReleaseComments"->table, 'release_comments', 'generated module loads';
    is_deeply $import->describe('release_posts')->{primary}, [qw(tenant_id post_no)], 'composite key order';
    eval { $import->generate(%options) };
    like "$@", qr/already exists/, 'import cannot overwrite a model';
    is $posts->()->count, 3, 'metadata import did not change live rows';

    $schema->drop_if_exists($_) for @tables;
    $orm->disconnect_all;
  };
}

done_testing;
