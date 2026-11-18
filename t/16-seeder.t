use strict;
use warnings;
use File::Temp qw(tempdir);
use Test::More;
use Yggdrasil;

my @targets = (['SQLite', { driver => 'sqlite', database => ':memory:' }]);
push @targets, ['PostgreSQL', { url => $ENV{YGGDRASIL_TEST_PG} }] if $ENV{YGGDRASIL_TEST_PG};
push @targets, ['MariaDB/MySQL', { url => $ENV{YGGDRASIL_TEST_MYSQL} }] if $ENV{YGGDRASIL_TEST_MYSQL};

sub write_seed {
  my ($file, $body) = @_;
  open my $fh, '>', $file or die "$file: $!";
  print {$fh} $body;
  close $fh or die "$file: $!";
}

for my $target (@targets) {
  subtest $target->[0] => sub {
    my $dir = tempdir('seeds with spaces XXXX', TMPDIR => 1, CLEANUP => 1);
    my $orm = Yggdrasil->new(
      connections => { reports => $target->[1] },
      default => 'reports', seed_paths => { reports => "$dir/seeds" },
    );
    my $db = $orm->db;
    my $seed = $orm->seeder;
    eval { $seed->run };
    like $@, qr/no seeders found/, 'empty directory fails explicitly';
    my $file = $seed->make('RolesSeeder');
    like $file, qr{/roles_seeder\.pl\z}, 'scaffold uses a predictable name';
    is_deeply $seed->run('RolesSeeder'), ['roles_seeder'], 'generated stub is runnable';
    eval { $seed->make('roles-seeder') };
    like $@, qr/already exists/, 'generator refuses to overwrite';
    eval { $seed->make('../bad') };
    like $@, qr/invalid seeder name/, 'name cannot traverse paths';
    eval { $seed->run('MissingSeeder') };
    like $@, qr/not found/, 'missing named seeder fails';

    $db->schema->drop_if_exists('seed_test_roles');
    $db->schema->create('seed_test_roles', sub { $_[0]->string('code')->unique; $_[0]->string('description') });
    my $table = sub { $db->table('seed_test_roles') };
    write_seed("$dir/seeds/01_base.pl", <<'SEED');
return sub { $_[0]->table('seed_test_roles')->upsert([{code => 'base', description => 'Base'}], ['code'], ['description']) };
SEED
    write_seed("$dir/seeds/02_extra.pl", <<'SEED');
return sub {
  die "base must run before extra" unless $_[0]->table('seed_test_roles')->where(code => 'base')->exists;
  $_[0]->table('seed_test_roles')->upsert([{code => 'extra', description => 'Extra'}], ['code'], ['description']);
};
SEED
    is_deeply $seed->run, [qw(01_base 02_extra roles_seeder)], 'run all in lexical order';
    $seed->run;
    is $table->()->count, 2, 'upserts are repeatable';
    write_seed("$dir/seeds/03_failing.pl", <<'SEED');
return sub {
  $_[0]->table('seed_test_roles')->insert({code => 'temporary', description => 'Temporary'});
  die "fixture failure\n";
};
SEED
    $table->()->delete;
    eval { $seed->run };
    like $@, qr/fixture failure/, 'exception propagates to caller';
    is $table->()->count, 0, 'failed seeder rolls back the entire batch';
    write_seed("$dir/seeds/04_invalid.pl", "return {};\n");
    eval { $seed->prepare };
    like $@, qr/must return a code reference/, 'entire batch is validated up front';
    my $extra = tempdir(CLEANUP => 1);
    write_seed("$extra/01_base.pl", "return sub {};\n");
    eval { $orm->seeder(undef, paths => ["$dir/seeds", $extra])->run };
    like $@, qr/duplicate seeder/, 'duplicate names are rejected across paths';
    $db->schema->drop_if_exists('seed_test_roles');
    $orm->disconnect_all;
  };
}

done_testing;
