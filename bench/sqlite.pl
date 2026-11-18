use strict;
use warnings;
use Benchmark qw(cmpthese);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin ();
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
}
{
  package Bench::Model::Event;
  use Moo;
  extends 'Yggdrasil::Model';
  sub timestamps { 0 }
}

Bench::Schema->register_class(Event => 'Bench::Result::Event');
my $dir = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'benchmark.db');
my $orm = Yggdrasil->new(connections => { default => { driver => 'sqlite', database => $file } });
my $db = $orm->db;
$db->statement('create table events (id integer primary key, label text not null)');
$db->transaction(sub {
  my $sth = $db->dbh->prepare('insert into events (id, label) values (?, ?)');
  $sth->execute($_, "Event $_") for 1 .. 30_000;
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

for my $fetch ($raw_y, $raw_d, $obj_y, $obj_d, $cursor, $offset) {
  my $rows = $fetch->();
  my @ids = map { ref $_ eq 'HASH' ? $_->{id} : $_->id } @$rows;
  die "benchmark methods returned different rows\n" unless "@ids" eq join ' ', $after + 1 .. $after + $size;
}

printf "Perl %s | DBD::SQLite %s | DBIx::Class %s | Yggdrasil %s\n",
  $], $DBD::SQLite::VERSION, $DBIx::Class::VERSION, $Yggdrasil::VERSION;
print "Equivalent hash rows (same table, filter, order and limit):\n";
cmpthese(-$seconds, { yggdrasil => $raw_y, dbix_class => $raw_d });
print "\nEquivalent model rows (same table, filter, order and limit):\n";
cmpthese(-$seconds, { yggdrasil => $obj_y, dbix_class => $obj_d });
print "\nYggdrasil page with exact total vs cursor page without a total (different API guarantees):\n";
cmpthese(-$seconds, { counted_offset => $offset, cursor => $cursor });
