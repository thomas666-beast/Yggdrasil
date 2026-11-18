package Yggdrasil::Collection;
use strict;
use warnings;
use List::Util ();
use re qw(is_regexp);
use Scalar::Util qw(blessed);

sub new { my $class = shift; bless [@_], ref($class) || $class }
sub _from_array { bless $_[1], $_[0] } # takes ownership of a fresh array
sub size { scalar @{$_[0]} }
sub last { $_[0]->[-1] }
sub to_array { [@{$_[0]}] }
sub TO_JSON { $_[0]->to_array }
sub join { CORE::join($_[1] // '', @{$_[0]}) }
sub reverse { $_[0]->new(CORE::reverse @{$_[0]}) }
sub shuffle { $_[0]->new(List::Util::shuffle(@{$_[0]})) }
sub compact { $_[0]->new(CORE::grep { defined && (ref || length) } @{$_[0]}) }
sub tap { my ($s, $cb) = @_; $cb->($s); $s }

sub first {
  my ($s, $cb, @args) = @_;
  return $s->[0] unless $cb;
  return List::Util::first { is_regexp($cb) ? $_ =~ $cb : $cb->($_, @args) } @$s;
}
sub map {
  my ($s, $cb, @args) = @_;
  return $s->new(CORE::map { $cb->($_, @args) } @$s);
}
sub grep {
  my ($s, $cb, @args) = @_;
  return $s->new(CORE::grep { is_regexp($cb) ? $_ =~ $cb : $cb->($_, @args) } @$s);
}
sub each {
  my ($s, $cb) = @_;
  return @$s unless $cb;
  my $i = 0;
  $cb->($_, ++$i) for @$s;
  return $s;
}
sub sort {
  my ($s, $cb) = @_;
  return $s->new(CORE::sort @$s) unless $cb;
  my $caller = caller;
  no strict 'refs';
  return $s->new(CORE::sort {
    local (*{"${caller}::a"}, *{"${caller}::b"}) = (\$a, \$b);
    $cb->($a, $b);
  } @$s);
}
sub uniq {
  my ($s, $cb, @args) = @_;
  my %seen;
  return $s->new(CORE::grep { my $key = $cb ? $cb->($_, @args) : $_; !$seen{$key // ''}++ } @$s);
}
sub head {
  my ($s, $n) = @_;
  $n += @$s if $n < 0;
  $n = @$s if $n > @$s;
  return $s->new(@$s[0 .. $n - 1]);
}
sub tail {
  my ($s, $n) = @_;
  $n += @$s if $n < 0;
  $n = @$s if $n > @$s;
  return $s->new(@$s[@$s - $n .. $#$s]);
}
sub reduce {
  my $s = shift;
  @_ = (@_, @$s);
  goto &List::Util::reduce;
}
sub flatten {
  my $s = shift;
  return $s->new(_flatten(@$s));
}
sub _flatten {
  return CORE::map { ref($_) eq 'ARRAY' || (blessed($_) && $_->isa(__PACKAGE__)) ? _flatten(@$_) : $_ } @_;
}

1;
