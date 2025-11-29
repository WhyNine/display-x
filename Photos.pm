package Photos;

use v5.28;
use strict;

our @EXPORT = qw (prepare_photo_task);
use base qw(Exporter);

use lib "/home/pi/display";
use Graphics;
use Utils;

sub prepare_photo_task {
  my $fname = shift;
  #print_error("preparing $fname");
  return prepare_photo($fname);
}

1;
