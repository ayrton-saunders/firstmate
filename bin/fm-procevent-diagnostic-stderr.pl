#!/usr/bin/env perl
# Test-only detached stderr sink. Usage: perl fm-procevent-diagnostic-stderr.pl <file>
# Drain stdin to EOF, retaining at most 262144 bytes INCLUDING the truncation
# marker in the shared file. flock keeps concurrent detached writers within
# that same budget. An unavailable destination still drains without logging.
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_APPEND O_CREAT O_NOFOLLOW O_NONBLOCK LOCK_EX LOCK_UN);

my $limit = 262144;
my $marker = "\n[stderr truncated: shared byte limit=$limit]\n";
my $data_limit = $limit - length($marker);
my $log;
if (@ARGV == 1 && sysopen(my $file, $ARGV[0], O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600)) {
  my @st = stat($file);
  $log = $file if @st && -f $file && $st[4] == $< && ($st[2] & 07777) == 0600 && $st[3] == 1;
}
sub write_all {
  my ($file, $bytes) = @_;
  while (length($bytes)) {
    my $written = syswrite($file, $bytes);
    return 0 unless defined($written) && $written > 0;
    substr($bytes, 0, $written, '');
  }
  return 1;
}
while (1) {
  my $read = sysread(STDIN, my $bytes, 65536);
  next if !defined($read) && $!{EINTR};
  last unless defined($read) && $read > 0;
  next unless $log && flock($log, LOCK_EX);
  my $size = (stat($log))[7];
  my $ok = 1;
  if (defined($size) && $size <= $data_limit) {
    my $take = $data_limit - $size;
    $take = $read if $take > $read;
    $ok = write_all($log, substr($bytes, 0, $take));
    $ok &&= write_all($log, $marker) if $take < $read;
  }
  flock($log, LOCK_UN);
  $log = undef unless $ok;
}
