package Input;

our @EXPORT = qw ( input_task what_input );
use base qw(Exporter);

use strict;

use lib "/home/pi/display";

use Utils;

use Linux::Input;
use Time::HiRes qw ( time usleep );

my $js1;
my $key_time = 0;

# bottom left of the display is (0, 0), top right is (479, 319)

sub what_input {
  my ($ref_display, $footer_ref, $transport_ref, $final_x, $final_y, $init_x, $init_y) = @_;
  my %display_areas_hash = ($ref_display) ? %$ref_display : ();
  my %footer_hash = %$footer_ref;
  my %transport_hash = %$transport_ref;
  my $delta_x = $final_x - $init_x;
  my $delta_y = $final_y - $init_y;
  my $delta = ($delta_x ** 2 + $delta_y ** 2) ** 0.5;
  #print_error "delta_x = $delta_x, delta_y = $delta_y, final_x = $final_x, final_y = $final_y, delta = $delta";
  if ($delta > 50) {                    # was it a swipe
    my $ratio = ($delta_y == 0) ? 10 : $delta_x / abs($delta_y);
    #print_error("ratio = $ratio");
    if ($ratio > 4) {
      return ("-right-");
    }
    if ($ratio < -4) {
      return ("-left-");
    }
    $ratio = ($delta_x == 0) ? 10 : $delta_y / abs($delta_x);
    #print_error("ratio = $ratio");
    if ($ratio > 4) {
      return ("-up-");
    }
    if ($ratio < -4) {
      return ("-down-");
    }
    return;
  }
  foreach my $area (keys %display_areas_hash) {
    my $ref = $display_areas_hash{$area};
    #print_error "Checking area $area, x1=$$ref{'x1'}, y2=$$ref{'y2'}";
    if (($$ref{"x1"} <= $init_x) && ($$ref{"x2"} >= $init_x) && ($$ref{"y1"} <= $init_y) && ($$ref{"y2"} >= $init_y)) {
      return $area;
    }
  }
  foreach my $area (keys %footer_hash) {
    my $ref = $footer_hash{$area};
    #print_error "Checking area $area, x1=$$ref{'x1'}, y2=$$ref{'y2'}";
    if (($$ref{"x1"} <= $init_x) && ($$ref{"x2"} >= $init_x) && ($$ref{"y1"} <= $init_y) && ($$ref{"y2"} >= $init_y)) {
      return $area;
    }
  }
  foreach my $area (keys %transport_hash) {
    my $ref = $transport_hash{$area};
    #print_error "Checking area $area, x1=$$ref{'x1'}, y2=$$ref{'y2'}";
    if (($$ref{"x1"} <= $init_x) && ($$ref{"x2"} >= $init_x) && ($$ref{"y1"} <= $init_y) && ($$ref{"y2"} >= $init_y)) {
      return $area;
    }
  }
  return;
}


# Events from Linux::Input have the following parameters:
#time in seconds
#microseconds
#type of event (press/release?)
#:0=EV_SYN (synchronise?)
#:1=key
#:2=rel
#:3=abs
#code
#:when type=1
#:  330=0x14a (BTN_TOUCH)
#:when type=3
#:  0=ABS_X (0 top left, max 719)
#:  1=ABS_Y (0 top left, max 1279)
#value
#:when type=1 and code=330
#:  1=press, 0=release
#:when type=3 and code=0/1
#:  location

sub input_task {
  my $areas_ref = shift;
  #print_hash_params($$areas_ref);
  my $touch_x = 0;
  my $touch_y = 0;
  my $touch_down = 0;
  my $press_x = 0;
  my $press_y = 0;
  $js1 = Linux::Input->new('/dev/input/by-path/platform-fe205000.i2c-event') if (!defined $js1);      # May need to change the path if move to new Pi
  while (1) {                                                   # start input loop
    while (my @events = $js1->poll(0.01)) {
      foreach my $ev (@events) {
        #print_error("type = " . $$ev{'type'} . ", code = " . $$ev{'code'} . ", value = " . $$ev{'value'} . ", time = " . time());
        if (($$ev{'type'} == 1) && ($$ev{'code'} == 330) && ($$ev{'value'} == 0)) {           ## key up detected
          if ($press_x && $press_y) {
            my $now_time = time();
            if (($now_time - $key_time) > 0.8) {            # discard keys within 0.8s
              $key_time = $now_time;
              return ($touch_x, $touch_y, $press_x, $press_y);
            }
            $press_x = 0;
            $press_y = 0;
            @events = undef;
          }
        }
        if (($$ev{'type'} == 1) && ($$ev{'code'} == 330)) {
          $touch_down = 1 if ($$ev{'value'} == 1);                      # key down detected
        }
        if (($$ev{'type'} == 3) && ($$ev{'code'} == 1)) {
          $touch_y = $$ev{'value'};
        }
        if (($$ev{'type'} == 3) && ($$ev{'code'} == 0)) {
          $touch_x = $$ev{'value'};
        }
        if ($$ev{'type'} == 0) {      # End of group of events
          if ($touch_down) {
            $press_x = $touch_x;
            $press_y = $touch_y;
          }
          $touch_down = 0;
        }
      }
      usleep(100000);
    }
  }
}

1;
