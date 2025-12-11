package Gather;

use v5.28;

our @EXPORT = qw ( gather_pictures gather_music call_callback );
use base qw(Exporter);

use strict;

use lib "/home/pi/display";
use Utils;


sub gather_pictures {
  my $path = shift;
  my @pics;
  while (! -d $path) {
    print_error "Waiting for $path to become available\n";
    my $tmp = `sudo mount -a`;
    sleep 60;
  }
  opendir(my $DIR, "$path") || die "Problem reading $path folder";
  chomp(my @dir = readdir($DIR));
  closedir($DIR);
  return if (grep(/^\.nomedia$/, @dir));
  foreach my $file (@dir) {
    next if ($file =~ /^\.+/);
    if (-d "$path/$file") {
      my $r = gather_pictures("$path/$file");
      if (defined($r)) {
        @pics = (@pics, @{$r});
      }
    } elsif (-f "$path/$file" && $file =~ /\.(jpg|jpeg|gif|tiff|bmp|png)$/i) {
      push(@pics, "$path/$file");
      #print_error("Found picture: $path/$file");
    }
  } ## end foreach my $file (@dir)
  return (\@pics);
} ## end sub gather


1;
