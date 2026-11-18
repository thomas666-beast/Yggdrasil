requires 'perl', '5.016';
requires 'Moo', '2.003';
requires 'DBI', '1.630';
requires 'JSON::PP';

on test => sub {
  requires 'Test::More';
  requires 'DBD::SQLite', '1.66';
};
