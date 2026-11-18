# Yggdrasil 0.05 User Guide

Yggdrasil is a standalone Perl ORM with an Eloquent-style query API. Start with a query builder or a Moo model in any Perl application. The Mojolicious adapter adds app-bound helpers, and Skapa adds shortcuts for generating models, managing migrations, and seeding databases.

## Install and create your first model

Install the standalone core from the release archive. Pick a driver for your database: `DBD::SQLite`, `DBD::Pg`, `DBD::mysql` for Oracle MySQL, or `DBD::MariaDB` for MariaDB.

```sh
cpanm DBD::SQLite
cpanm ./Yggdrasil-0.05.tar.gz
```

Put these classes under `lib/MyApp/Model/` in `Post.pm` and `Comment.pm`, respectively:

```perl
package MyApp::Model::Post;
use Moo;
extends 'Yggdrasil::Model';

sub timestamps { 0 }
sub fillable { [qw(title)] }
sub comments { $_[0]->has_many('Comment', 'post_id') }
1;
```

```perl
package MyApp::Model::Comment;
use Moo;
extends 'Yggdrasil::Model';

sub timestamps { 0 }
sub fillable { [qw(body approved)] }
sub post { $_[0]->belongs_to('Post', 'post_id') }
1;
```

Save this runnable example as `example.pl` next to `lib/`. It creates a disposable in-memory database, inserts a post, and reads it with its comments.

```perl
use strict;
use warnings;
use lib 'lib';
use Yggdrasil;

my $orm = Yggdrasil->new(
  connections => { default => { driver => 'sqlite', database => ':memory:' } },
  model_namespaces => ['MyApp::Model'],
);

$orm->schema->create('posts', sub {
  my $t = shift;
  $t->id;
  $t->string('title');
});

$orm->schema->create('comments', sub {
  my $t = shift;
  $t->id;
  $t->foreign_id('post_id')->constrained('posts');
  $t->text('body');
  $t->boolean('approved')->default(0);
  $t->index([qw(post_id approved id)]);
});

my $post = $orm->create_model('Post', { title => 'Hello, Yggdrasil' });
$post->comments->create({ body => 'First comment', approved => 1 });
my $found = $orm->model_query('Post')->with('comments')->find($post->id);
print $found->title, ': ', $found->related('comments')->size, " comment(s)\n";
```

`model_query`, `make_model`, and `create_model` bind to an explicit manager, so multiple apps can coexist without sharing a global default. Pass `using => 'reports'` to select another configured connection. When using class-level calls with the legacy manager, use `MyApp::Model::Post->include('comments')`; `with` is already a Moo keyword on model classes.

For Oracle MySQL over TCP, enable TLS in the connection's `options`, for example `options => { mysql_ssl => 1, mysql_ssl_verify_server_cert => 1, mysql_ssl_ca_file => '/path/to/ca.pem' }`. Use a CA and hostname appropriate to your server; simply turning on encryption is not a substitute for verifying server identity.

## Load 10 comments per post

Use `with` when you want to display related records for more than one parent. Put the limit inside the relationship callback, not on the outer query.

```perl
my $posts = $orm->model_query('Post')
  ->with(comments => sub {
    my $q = shift;
    $q->where(approved => 1)->order_by_desc('id')->limit(10);
  })
  ->order_by_desc('id')
  ->limit(25)
  ->get;

for my $post (@$posts) {
  for my $comment (@{$post->related('comments')}) {
    print $comment->body, "\n";
  }
}
```

Each post gets up to 10 approved comments. For a small page with one relationship, this uses one parent query and one batched comments query, not one query per post. The database ranks rows by parent, and only the requested ranks reach Perl. The database may still scan or sort additional matches, so add an index starting with the relationship key, then consider filter and order columns.

- **Order:** Supply a real column name. Yggdrasil appends the related primary key as a tiebreaker; without an explicit sort, it orders by that key. With a pivot, qualify ambiguous column names, such as `tags.id`.
- **Offset:** `->offset(10)->limit(10)` skips ten qualifying rows for each parent, not ten globally. An offset without a limit is rejected for an eager-load callback.
- **Projection:** Keep all matching key columns on both sides of the relationship. For a pivot, keep its default projection to retain the aliased pivot keys, and do not use `__yggdrasil_rank` as a column alias in a limited relation.
- **Filters and nesting:** Put eager-load filters in the `with` callback. Query modifiers chained inside relation methods are not applied to batch eager loads. Dotted names such as `with('comments.author')` work when `author` is defined on the comment model.
- **Portability:** Multi-parent limits require window functions: [SQLite 3.25+](https://www.sqlite.org/windowfunctions.html), [MySQL 8+](https://dev.mysql.com/doc/refman/8.4/en/window-functions-usage.html), [MariaDB 10.2+](https://mariadb.com/resources/blog/introduction-to-window-functions-in-mariadb-server-10-2/), or a supported PostgreSQL release. These are SQL feature floors, not recommendations to run old database releases. Limited eager queries cannot use raw ordering, `DISTINCT`, grouping, or row locks.

### Filter posts by their relationships

`where_has` filters parent rows; it does not load the related rows. `with` loads related rows; it does not filter parents. Use both when you need both effects.

```perl
my $approved = sub { $_[0]->where(approved => 1) };

my $page = $orm->model_query('Post')
  ->where_has('comments', $approved)
  ->with(comments => sub { $approved->($_[0]); $_[0]->order_by_desc('id')->limit(10) })
  ->cursor_page(size => 25, order => [['id', 'desc']]);

my $without = $orm->model_query('Post')->where_doesnt_have('comments', $approved);
```

Use `or_where_has` inside a `where(sub { ... })` group when combining alternatives with required filters, such as a tenant ID. Nested checks use dotted names. Existence checks use the configured relation and respect soft-delete scopes; they require the model's unaliased table and a same-connection relation. Use an ordinary ungrouped relationship query without limits, offsets, or locks. If clients choose which relations to include, map their input to an application-maintained allowlist of relationship methods.

## Paginate, export, and run SQL

| Need | API | What it fetches |
| --- | --- | --- |
| Next-page navigation | `cursor_page(size => 25, order => [['id','desc']], after => $cursor)` | Up to 26 parent rows to detect another page; no total |
| Exact totals or numbered pages | `order_by('id')->paginate(25, $page_number)` | A count plus rows for the requested page |
| Large export | `chunk_by_cursor($callback, size => 250, order => ['id'])` | One bounded page at a time; return `0` from the callback to stop |
| A short, bounded list | `order_by('id')->limit(25)->get` | At most 25 rows; no paging metadata |

For cursor navigation, pass `$page->next_cursor` into the next call, with the same filters and order. Always use non-null sort columns with a unique final ordering, and keep those columns in the projection. A cursor is an array of values, not a signed token or a snapshot.

If a query needs SQL that the builder does not express, use parameter bindings. Never concatenate untrusted input into identifiers or raw SQL; choose identifiers from an allowlist.

```perl
my $rows = $orm->db->select_all(
  'select id, title from posts where id > ? order by id limit 25', $last_id
);
```

## Composite many-to-many relationships

Declare the compound primary key on each model and create a pivot with matching foreign keys. For this example, `posts` has `PRIMARY KEY (tenant_id, post_no)`, `tags` has `PRIMARY KEY (tenant_id, tag_no)`, and `post_tag` has `PRIMARY KEY (tenant_id, post_no, tag_no)` with a nullable `label`.

```perl
# In the Post model:
sub primary_key { [qw(tenant_id post_no)] }
sub tags {
  $_[0]->belongs_to_many(
    'Tag', 'post_tag', [qw(tenant_id post_no)], [qw(tenant_id tag_no)]
  )->with_pivot('label');
}

# In the Tag model: sub primary_key { [qw(tenant_id tag_no)] }
my $post = $orm->model_query('Post')->find({ tenant_id => 7, post_no => 42 });
$post->tags->attach({ tenant_id => 7, tag_no => 9 }, { label => 'featured' });
my $label = $post->tags->first->pivot->{label};
$post->tags->sync([{ tenant_id => 7, tag_no => 9 }, { tenant_id => 7, tag_no => 12 }]);
$post->tags->detach({ tenant_id => 7, tag_no => 12 });
```

The ordered arrays name the two pivot foreign keys; the model keys they refer to default to each model's primary key. Composite IDs can be exact key hashes or stored related models on the same connection. A shared pivot column, such as `tenant_id`, must agree on both sides. `sync` applies its changes in a transaction but does not serialize independent callers; coordinate concurrent replacement of the same set in the application.

## Write safely under concurrency

Use the atomic helpers when workers can race to create the same identity. The identity columns must exactly match a primary key or a full unique index, use non-null values, and be separate from the mutable values.

```perl
# Table accounts has UNIQUE (tenant_id, email).
my $identity = { tenant_id => $tenant_id, email => $email };
my $account = $orm->first_or_create_model('Account', $identity, { display_name => $name });
$account = $orm->update_or_create_model('Account', $identity, { display_name => $name });
```

On a configured model use `first_or_create_atomic` or `update_or_create_atomic`; the older `first_or_create` and `update_or_create` keep their previous read-then-write behavior. The atomic methods attempt an insert first, then read the row for the intended key. The update variant changes an existing row under the same transaction and returns the hydrated result.

- **Schema:** Use ordinary, non-deferrable unique constraints or full-column indexes. Do not use partial or expression indexes for identity. Use InnoDB for MySQL/MariaDB. Pass enough values to make a valid insert, even if you expect a row to exist.
- **Model behavior:** These methods skip model lifecycle hooks, but still use attribute casts/mutators and managed timestamps. `$values` follows mass-assignment rules; the identity is force-filled, so build it yourself from trusted column names and authorized values. A soft-deleted match is an error, not a restore.
- **Retries:** Database errors still occur, including uniqueness conflicts on other keys, deadlocks, serialization errors, and SQLite lock contention. No automatic retry is attempted. If appropriate, retry the entire outer transaction, not just the last statement, and keep external effects out of retryable callbacks.
- **Transactions:** Use `$orm->db->transaction(sub { ... })` for related writes on the same connection. An exception rolls back that transaction, and nested calls use savepoints.

## Use Mojolicious and Skapa

Install the adapter and CLI after the standalone core. The Skapa bundle is optional if you only need the ORM CLI. For the bundle, install its other declared plugin dependencies as well.

```sh
cpanm ./Mojolicious-Plugin-Yggdrasil-0.04.tar.gz
cpanm ./Mojolicious-Command-skapa-0.03.tar.gz
# Optional:
cpanm ./Mojolicious-Plugin-Skapa-0.03.tar.gz
```

Configure Yggdrasil in the app's `startup`. The Skapa bundle installs plugins but does not configure your database connections.

```perl
$app->plugin(Yggdrasil => {
  connections => { default => { driver => 'sqlite', database => 'app.sqlite' } },
  models       => ['MyApp::Model'],
  migrations   => 'migrations',
  seeds        => 'seeds',
  legacy_global => 0,
});
```

### Generate models from an existing database

```sh
script/my_app skapa schema:import --table comments --pretend
script/my_app skapa schema:import --table comments
script/my_app skapa schema:import -c reports --pretend
```

Import reads metadata from the current schema or database. It does not modify the database, create migrations, or overwrite model files. Models go under the configured namespace in the app's `lib/` directory, with names derived from the table name (`comments` becomes `Comments.pm`). With `-c`, generated models pin to that named connection.

The importer generates a declared primary key, a conservative incrementing flag, and `related_*` `belongs_to` methods for supported same-schema foreign keys. It does not infer reverse or pivot relationships, casts, soft deletes, or lifecycle timestamps. Models start guarded and with timestamps disabled; review the files and add only the `fillable` fields your application needs. When scanning all tables it skips unsupported keys and the default `migrations` table; use `--table` to target a specific table. If you import only one table, generate or adapt the referenced models separately.

Standalone code can use `$orm->schema_importer('reports')->generate(namespace => 'MyApp::Model', directory => 'lib', table => 'comments', pretend => 1)`.

### Manage migrations and seed data

| Command | What it does |
| --- | --- |
| `skapa make:model Post --migration` | Generate a model and migration scaffold |
| `skapa migrate` | Apply pending migrations |
| `skapa migrate:status` | Show applied and pending steps |
| `skapa migrate:rollback` | Undo the latest batch; use `--step N` for N migrations |
| `skapa migrate:refresh` | Roll back known migrations and rerun them |
| `skapa make:seed RolesSeeder` | Create `seeds/roles_seeder.pl` |
| `skapa db:seed RolesSeeder` | Run one seeder without dropping tables; omit the name to run all |
| `skapa migrate:fresh --seed` | Drop all tables in the target, rerun migrations, and seed |

Only run `fresh` on a disposable database. It drops tables outside the migration history too. A failed seeder rolls back its own DML batch, not the preceding schema rebuild. MySQL and MariaDB DDL can auto-commit; never treat a migration lock as a guarantee that every schema edit can be rolled back.

Migration writers fail fast when another writer holds the same lock. PostgreSQL uses a session advisory lock scoped to the active schema; MySQL/MariaDB use a named session lock scoped to the database. Connect directly or through a session-pooling proxy. SQLite file databases use a lock file alongside the database; runners must see the same file on a filesystem with working `flock`, and the directory must be writable. Leave the lock file in place while runners may be active. In-memory SQLite is not a shared production migration target. Status, previews, and independent `db:seed` calls do not take the migration lock; `fresh --seed` holds it through seeding.

## Upgrade checklist

- **From 0.04:** An eager callback `limit(10)` now means ten per parent, not ten across the entire batch. Page the parents too to keep response size bounded.
- **Schema:** Confirm relationship indexes and unique identities. Fresh tracking tables enforce unique migration names; existing repositories are not retrofitted. Audit existing rows before adding a unique constraint yourself.
- **Test:** Use a disposable database with production-like indexes and engine settings. Core tests can target PostgreSQL with `YGGDRASIL_TEST_PG` and MySQL/MariaDB with `YGGDRASIL_TEST_MYSQL`; those suites create and drop fixture tables. Set `YGGDRASIL_TEST_MYSQL_TLS=1` to require encrypted transport from `DBD::mysql` to an Oracle MySQL test fixture. The supplied GitHub Actions workflow has separate SQLite, PostgreSQL, MariaDB and Oracle MySQL jobs.
- **Profile:** Run `perl bench/sqlite.pl` in the extracted core distribution with `DBIx::Class` and `DBD::SQLite` installed. It compares equivalent reads, committed writes, and a 30,000-row keyset export. It also measures four Yggdrasil workers racing across 150 shared unique keys. The top-three comparison uses a batched Yggdrasil query versus DBIx::Class per-parent queries; it does not compare against hand-tuned window SQL in DBIx::Class.

## Benchmark snapshot

One local run used Perl 5.40.1, DBD::SQLite 1.78, Yggdrasil 0.05, and DBIx::Class 0.082844. Reads used the same database and verified equivalent results. The rates below describe these workloads, not overall ORM performance.

| Exact workload | Yggdrasil | DBIx::Class |
| --- | ---: | ---: |
| Read 25 keyset-selected hash rows from 30,000 | 9,361 requests/s | 2,572 requests/s |
| Read the same 25 rows as model objects | 4,227 requests/s | 2,349 requests/s |
| Materialize 25 parents and all 8 children each | 338 requests/s | 162 requests/s |
| Materialize 25 parents and first 3 of 8 children each, ordered by child ID | 543 requests/s | 74.9 requests/s |
| Run 300 committed transactions, each inserting then updating one row | 1,314 transactions/s | 1,111 transactions/s |
| Export 30,000 model rows in keyset batches of 250, consuming IDs and labels | 90,391 rows/s | 151,944 rows/s |

For the top-three workload, Yggdrasil uses a window batch and DBIx::Class uses one limited relationship query per parent. In the separate Yggdrasil-only concurrency test, four workers made 600 atomic create calls against the same 150 unique keys. They completed all calls and left exactly 150 rows. The export result shows an area where the DBIx::Class implementation retained an advantage on this fixture.
