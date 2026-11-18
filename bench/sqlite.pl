use strict;
use warnings;
use Benchmark qw(cmpthese);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin ();
use POSIX ();
use Time::HiRes qw(time);
use lib "$FindBin::Bin/../lib";
use Yggdrasil;
use DBIx::Class ();
use DBIx::Class::ResultClass::HashRefInflator ();
use DBD::SQLite ();

{
  package Bench::Schema;
  use parent 'DBIx::Class::Schema';
}
{
  package Bench::Result::Event;
  use parent 'DBIx::Class::Core';
  __PACKAGE__->table('events');
  __PACKAGE__->add_columns(qw(id label));
  __PACKAGE__->set_primary_key('id');
  __PACKAGE__->has_many(details => 'Bench::Result::EventDetail', 'event_id');
}
{
  package Bench::Result::EventDetail;
  use parent 'DBIx::Class::Core';
  __PACKAGE__->table('event_details');
  __PACKAGE__->add_columns(qw(id event_id body));
  __PACKAGE__->set_primary_key('id');
}
{
  package Bench::Model::Event;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
  sub details { shift->has_many('Bench::Model::EventDetail', 'event_id') }
}
{
  package Bench::Model::EventDetail;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
  sub table { 'event_details' }
}
{
  package Bench::Result::Ingest;
  use parent 'DBIx::Class::Core';
  __PACKAGE__->table('ingest');
  __PACKAGE__->add_columns(qw(id label));
  __PACKAGE__->set_primary_key('id');
}
{
  package Bench::Model::Ingest;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
  sub fillable { [qw(id label)] }
  sub table { 'ingest' }
}

Bench::Schema->register_class(Event => 'Bench::Result::Event');
Bench::Schema->register_class(EventDetail => 'Bench::Result::EventDetail');
Bench::Schema->register_class(Ingest => 'Bench::Result::Ingest');
my $dir = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'benchmark.db');
my $orm = Yggdrasil->new(connections => { default => { driver => 'sqlite', database => $file } });
my $db = $orm->db;
$db->statement('create table events (id integer primary key, label text not null)');
$db->statement('create table event_details (id integer primary key, event_id integer not null, body text not null)');
$db->statement('create index event_details_event_id on event_details(event_id)');
$db->statement('create table ingest (id integer primary key, label text not null)');
$db->transaction(sub {
  my $sth = $db->dbh->prepare('insert into events (id, label) values (?, ?)');
  $sth->execute($_, "Event $_") for 1 .. 30_000;
  my $detail = $db->dbh->prepare('insert into event_details (event_id, body) values (?, ?)');
  for my $event (19_501 .. 20_500) {
    $detail->execute($event, "Detail $_ of $event") for 1 .. 8;
  }
});
my $dbic = Bench::Schema->connect("dbi:SQLite:dbname=$file", '', '', { RaiseError => 1, PrintError => 0 });
my $seconds = $ENV{BENCH_SECONDS} // 2;
die "BENCH_SECONDS must be a positive integer\n" unless $seconds =~ /\A[1-9][0-9]?\z/;
my ($after, $size) = (20_000, 25);

my $raw_y = sub { $orm->table('events')->where('id', '>', $after)->order_by('id')->limit($size)->get };
my $raw_d = sub { [$dbic->resultset('Event')->search({ id => { '>' => $after } }, {
  order_by => 'id', rows => $size, result_class => 'DBIx::Class::ResultClass::HashRefInflator',
})->all] };
my $obj_y = sub { $orm->model_query('Bench::Model::Event')->where('id', '>', $after)->order_by('id')->limit($size)->get };
my $obj_d = sub { [$dbic->resultset('Event')->search({ id => { '>' => $after } }, { order_by => 'id', rows => $size })->all] };
my $cursor = sub { $orm->table('events')->cursor_page(size => $size, order => ['id'], after => [$after])->items };
my $offset = sub { $orm->table('events')->order_by('id')->paginate($size, int($after / $size) + 1)->items };
my $graph_y = sub {
  my $rows = $orm->model_query('Bench::Model::Event')->where('id', '>', $after)
    ->order_by('id')->limit($size)->include('details')->get;
  return [map { [0 + $_->id, $_->label, sort map { $_->body } @{$_->related('details')}] } @$rows];
};
my $graph_d = sub {
  my @rows = $dbic->resultset('Event')->search({ 'me.id' => { '>' => $after } }, {
    order_by => 'me.id', rows => $size, prefetch => 'details',
  })->all;
  return [map { [0 + $_->id, $_->label, sort map { $_->body } $_->details->all] } @rows];
};
my $top_y = sub {
  my $rows = $orm->model_query('Bench::Model::Event')->where('id', '>', $after)
    ->order_by('id')->limit($size)->with(details => sub { $_[0]->order_by('id')->limit(3) })->get;
  return [map { [0 + $_->id, $_->label, map { $_->body } @{$_->related('details')}] } @$rows];
};
my $top_d = sub {
  my $rows = $obj_d->();
  return [map { [0 + $_->id, $_->label, map { $_->body }
    $_->details->search(undef, { order_by => 'id', rows => 3 })->all] } @$rows];
};

for my $fetch ($raw_y, $raw_d, $obj_y, $obj_d, $cursor, $offset) {
  my $rows = $fetch->();
  my @ids = map { ref $_ eq 'HASH' ? $_->{id} : $_->id } @$rows;
  die "benchmark methods returned different rows\n" unless "@ids" eq join ' ', $after + 1 .. $after + $size;
}
my $expected = join "\n", map {
  my $event = $_;
  join "\t", $event, "Event $event", map { "Detail $_ of $event" } 1 .. 8;
} $after + 1 .. $after + $size;
for my $fetch ($graph_y, $graph_d) {
  my $actual = join "\n", map { join "\t", @$_ } @{$fetch->()};
  die "eager benchmark did not return equivalent parents and children\n" unless $actual eq $expected;
}
my $expected_top = join "\n", map {
  my $event = $_;
  join "\t", $event, "Event $event", map { "Detail $_ of $event" } 1 .. 3;
} $after + 1 .. $after + $size;
for my $fetch ($top_y, $top_d) {
  my $actual = join "\n", map { join "\t", @$_ } @{$fetch->()};
  die "top-N benchmark did not return equivalent parents and children\n" unless $actual eq $expected_top;
}

printf "Perl %s | DBD::SQLite %s | DBIx::Class %s | Yggdrasil %s\n",
  $], $DBD::SQLite::VERSION, $DBIx::Class::VERSION, $Yggdrasil::VERSION;
print "Equivalent hash rows (same table, filter, order and limit):\n";
cmpthese(-$seconds, { yggdrasil => $raw_y, dbix_class => $raw_d });
print "\nEquivalent model rows (same table, filter, order and limit):\n";
cmpthese(-$seconds, { yggdrasil => $obj_y, dbix_class => $obj_d });
print "\nRelationship graph: 25 parents, eight children each; materialize the same payload:\n";
cmpthese(-$seconds, { yggdrasil => $graph_y, dbix_class => $graph_d });
print "\nTop three per parent: Yggdrasil window batch vs DBIx::Class per-parent limit (not optimized DBIx SQL):\n";
cmpthese(-$seconds, { yggdrasil => $top_y, dbix_class => $top_d });
print "\nYggdrasil page with exact total vs cursor page without a total (different API guarantees):\n";
cmpthese(-$seconds, { counted_offset => $offset, cursor => $cursor });

# Fixed work and wall time for I/O-heavy or multi-process benchmarks.
my $write_y = sub {
  my ($id) = @_;
  $db->transaction(sub {
    $orm->create_model('Bench::Model::Ingest', {id => $id, label => 'created'})->update({label => 'committed'});
  });
};
my $write_d = sub {
  my ($id) = @_;
  $dbic->txn_do(sub { $dbic->resultset('Ingest')->create({id => $id, label => 'created'})->update({label => 'committed'}) });
};
print "\nCommitted writes: 300 transactions, each creating and updating the same row:\n";
for my $case (['Yggdrasil', $write_y], ['DBIx::Class', $write_d]) {
  $db->table('ingest')->delete;
  my $start = time;
  $case->[1]->($_) for 1 .. 300;
  printf "%-12s %8.1f transactions/s\n", $case->[0], 300 / (time - $start);
  die "write verification failed\n" unless $db->table('ingest')->where(label => 'committed')->count == 300;
}

my $export_y = sub {
  my ($count, $sum) = (0, 0);
  $orm->model_query('Bench::Model::Event')->chunk_by_cursor(sub {
    my $rows = shift;
    for my $row (@$rows) { $count++; $sum += $row->id + length $row->label }
    return 1;
  }, size => 250, order => ['id']);
  return ($count, $sum);
};
my $export_d = sub {
  my ($count, $sum, $key) = (0, 0, 0);
  while (1) {
    my @rows = $dbic->resultset('Event')->search({id => {'>' => $key}}, {order_by => 'id', rows => 250})->all;
    for my $row (@rows) { $count++; $sum += $row->id + length $row->label }
    last if @rows < 250;
    $key = $rows[-1]->id;
  }
  return ($count, $sum);
};
my $checksum = 0;
$checksum += $_ + length("Event $_") for 1 .. 30_000;
print "\nKeyset export: 30,000 model rows, chunks of 250, consume an ID and label checksum:\n";
for my $case (['Yggdrasil', $export_y], ['DBIx::Class', $export_d]) {
  my $start = time;
  for (1 .. 3) {
    my ($count, $actual) = $case->[1]->();
    die "export verification failed\n" unless $count == 30_000 && $actual == $checksum;
  }
  printf "%-12s %8.1f rows/s\n", $case->[0], 90_000 / (time - $start);
}

if ($^O ne 'MSWin32') {
  $db->table('ingest')->delete;
  $orm->disconnect_all;
  $dbic->storage->disconnect;
  pipe my $read, my $write or die "pipe: $!";
  my (@workers, $keys);
  $keys = 150;
  for my $worker (1 .. 4) {
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if (!$pid) {
      close $write;
      my $ok = eval {
        die 'missing start signal' unless sysread $read, my $signal, 1;
        $orm->first_or_create_model('Bench::Model::Ingest', {id => $_}, {label => 'concurrent'}) for 1 .. $keys;
        1;
      };
      warn "$@" unless $ok;
      POSIX::_exit($ok ? 0 : 1);
    }
    push @workers, $pid;
  }
  close $read;
  my $start = time;
  syswrite $write, 'x' x @workers;
  close $write;
  for my $pid (@workers) { waitpid $pid, 0; die "worker failed: $?\n" if $? }
  my $wall = time - $start;
  die "concurrent identity verification failed\n"
    unless $db->table('ingest')->where(label => 'concurrent')->count == $keys;
  printf "\nYggdrasil only: %d workers, %d shared unique keys, %d calls, %.1f calls/s, %d stored rows\n",
    scalar(@workers), $keys, $keys * @workers, $keys * @workers / $wall, $keys;
}
