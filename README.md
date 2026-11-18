# Yggdrasil

Yggdrasil is a standalone, Eloquent-style Perl ORM for SQLite, PostgreSQL, MySQL and MariaDB. It includes a DBI query builder, Moo models, relationships, eager loading, soft deletes, a schema builder and file-based migrations. It does not require Mojolicious.

## Install and run

Install the release archive with `cpanm ./Yggdrasil-0.03.tar.gz`. Use the driver for your database: `DBD::SQLite` for `sqlite`, `DBD::Pg` for `pg`, `DBD::mysql` for `mysql`, or `DBD::MariaDB` for `mariadb`.

```perl
use strict;
use warnings;
use Yggdrasil;

{
  package MyApp::Model::Post;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
}

my $orm = Yggdrasil->new(
  connections => { main => { driver => 'sqlite', database => ':memory:' } },
  default => 'main',
  model_namespaces => ['MyApp::Model'],
);

$orm->db->schema->create('posts', sub {
  my $t = shift;
  $t->id;
  $t->string('title');
});

my $post = $orm->create_model('Post', { title => 'Hello' });
print $orm->model_query('Post')->find($post->id)->title, "\n";
my $rows = $orm->table('posts')->order_by('id')->limit(25)->get;
```

Use `model_query`, `make_model` and `create_model` on the manager for isolated apps, workers and tests. Pass `using => 'reports'` to select a named connection. Class-level calls such as `Post->where(...)` still use the legacy default manager configured by `Yggdrasil->init`; do not rely on that global when multiple apps share a process. The ORM uses synchronous DBI. Wrap related writes with `$orm->db->transaction(sub { ... })` and use trusted, version-controlled migration files through `$orm->migrator`.

## Read one page at a time

```perl
my $q = $orm->model_query('Post');
my %args = (size => 25, order => [['id', 'desc']]);
my $page = $q->cursor_page(%args);
for my $row (@{$page->items}) { print $row->title, "\n" }
my $next = $page->next_cursor;
my $following = $q->cursor_page(%args, after => $next) if defined $next;
```

Use `cursor_page` for next-page navigation without a total. It reads at most `size + 1` parent rows, with a maximum page size of 1,000. Include every sort column in the projection, use non-null sort values, and end the sort with a unique tiebreaker. Add a matching index and keep the filters and order the same on continuation. The cursor is an array of values, not a signed external token or a snapshot guarantee. If exposing it in a public API, validate it and apply authorization independently on every request.

Use `order_by(...)->paginate($size, $page)` if clients need exact totals or arbitrary page numbers. `get` retrieves the full matching result unless bounded, and `chunk` still uses offsets. Eager loading fetches related rows only for visible parents, but a large to-many relationship can still return many child rows.

## Seed data

Configure the manager with `seed_paths => { main => ['seeds'] }` for a connection named `main`, or pass `paths => ['seeds']` to `$orm->seeder('main', paths => ['seeds'])`. Generate a starter file with `$orm->seeder('main')->make('RolesSeeder')` and replace its sample with your data. Its path will be `seeds/roles_seeder.pl`.

```perl
use strict;
use warnings;

return sub {
  my ($db) = @_;
  # Run migrations first. The roles table must have a unique index on code.
  $db->table('roles')->upsert(
    [{ code => 'viewer', name => 'Viewer' }],
    ['code'],
    ['name'],
  );
};
```

Run one file with `$orm->seeder('main')->run('RolesSeeder')`, or run all in filename order with `$orm->seeder('main')->run`. There is no migration log for seeds: each invocation reruns the selected files, so use stable keys and upserts if they should be repeatable. A failed callback rolls back the batch's data changes on the selected connection when using transactional tables. Treat seed files as trusted Perl, keep changes inside the callback, and put schema changes in migrations.

## Upgrading from bundled 0.01

- **Collections:** `get` and to-many relations now return `Yggdrasil::Collection`, not `Mojo::Collection`. Array dereferencing and common chaining methods remain; use `to_array` if you need a plain array reference. Do not rely on the old class identity or assume full Mojo method parity.
- **Writes:** Unsupported query shapes fail instead of silently discarding limits or ordering. A filtered `truncate` is rejected. Stored records must be mutated using their original primary key; use an explicit, reviewed migration to rekey data.
- **Logs and migrations:** Logger callbacks redact bindings by default; explicitly enabled query logs and SQL exceptions can still contain bound values. Status and dry runs do not create the migrations table; preview does not sandbox Perl code or direct DBI calls. Run migrations through a single release job.

## Tests and benchmark

Run `prove -l t` for SQL generation and SQLite. To include live PostgreSQL and MariaDB or MySQL, set `YGGDRASIL_TEST_PG` and `YGGDRASIL_TEST_MYSQL` to disposable test databases. These suites drop tables.

Install `DBIx::Class` and run `perl bench/sqlite.pl` for a local comparison of equivalent indexed lookups and a separate illustration of counted offset versus cursor paging. One workload does not establish general performance superiority.
