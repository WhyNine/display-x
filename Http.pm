package Http;

our @EXPORT = qw ( download );
use base qw(Exporter);

use strict;

use lib "/home/pi/display";

use Utils;
use UserDetails qw ( $jellyfin_url );

use File::Path;
use File::Basename;

# changed to use wget as there were a few files that AnyEvent::HTTP wouldn't retrieve; its also simpler although much slower
sub download($$$$) {
  my ($url, $hdr_ref, $cache, $cb) = @_;
  my $file = $cache . $url;
  my $pos = index($file, "?");
  $file = substr($file, 0, $pos);
  my ($filename, $directories, $suffix) = fileparse($file);
  mkpath($directories);
  $filename .= ".jpg" unless $suffix;                                                   # add suffix if it didn't have one
  my $wget_str = "cd $directories; wget -S -O $filename '$jellyfin_url$url' 2>&1";      # change folder and redirect stderr to stdout so that I get it
  #print_error("wget is $wget_str");
  my $result = `$wget_str`;                                                             # get file
  #print_error("result = $result");
  $pos = index($result, "  HTTP/1.1");
  my $status = substr($result, $pos + 11, 3);                                           # extract http result code
  #print_error("status = $status for $url");
  if ($status == 200 || $status == 206 || $status == 416) {
    $cb->(1, undef);
  } elsif ($status == 412 || $status == 404) {
    #print_error("status $status, file not found ($file)");
    unlink "$directories/$filename";
    $cb->(0, undef);
  } elsif ($status == 500 or $status == 503 or $status =~ /^59/) {
    print_error("status $status, server error ($file)");
    unlink "$directories/$filename";
    $cb->(0, undef);
  } else {                        # must be some other sort of error so delete file
    print_error("status $status, some other error ($file)");
    unlink "$directories/$filename";
    $cb->(undef, undef);
  }
}


1;
