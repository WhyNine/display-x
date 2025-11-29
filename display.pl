# screen is 720 x 1280 (32 bits)

use strict;
use v5.28;

use lib "/home/pi/display";
use Gather;
use Graphics;
use UserDetails qw ( $path_to_pictures $health_check_url $radio_stations_ref $jellyfin_url $jellyfin_apikey $display_times_ref );
use Utils;
use Http;
use Audio;
use Photos;
use MQTT;

use Gtk3 -init;
use Glib;
use Cairo;
use Event;
#use AnyEvent::HTTP;
use JSON::Parse;
use threads;
use threads::shared;
use Thread::Queue;                # Note always need threads before Thread::Queue


my $jellyfin_user_id;
my $pictures;           # ref to array of paths
my $mqtt_data_ref;      # ref to hash of MQTT data

use constant PLAYING_NOTHING => 0;
use constant PLAYING_RADIO => 1;
use constant PLAYING_PLAYLIST => 2;
use constant PLAYING_ALBUM => 3;
my $mode_playing_area = PLAYING_NOTHING;
# array of ref to hashes of params for playing mode display, inc "update_fn" => ref to function to update play mode area
my @playing_params = (
  {"update_fn" => \&update_nothing_playing}, 
  {"update_fn" => \&update_radio_playing, "stop" => \&transport_stop}, 
  {"update_fn" => \&update_playlist_playing, "stop" => \&transport_stop, "pause" => \&transport_pause, "play" => \&transport_play, "next" => \&playlist_next_track}, 
  {"update_fn" => \&update_album_playing, "stop" => \&transport_stop, "pause" => \&transport_pause, "play" => \&transport_play, "next" => \&album_next_track, "back" => \&album_prev_track});

use constant DISPLAY_SLIDESHOW => 0;
use constant DISPLAY_RADIO => 1;
use constant DISPLAY_PLAYLISTS => 2;
use constant DISPLAY_ALBUMS_LETTER => 3;
use constant DISPLAY_ALBUMS_ICON => 4;
use constant DISPLAY_ARTISTS_LETTER => 5;
use constant DISPLAY_ARTISTS_ICON => 6;
use constant DISPLAY_ARTISTS_ALBUM => 7;
use constant DISPLAY_HA => 8;
my $mode_display_area = -1;
my @display_mode_headings = ("Slideshow", "Radio stations", "Playlists", "Albums by letter", "List of albums", "Artists by letter", "List of artists", "List of albums", "Home Assistant");
my @displaying_params = ({}, {}, {}, {}, {}, {}, {}, {}, {});
my @footer_names = qw(photos radio playlists albums artists homeauto);
# array of refs to hashes of footer callbacks
my %footer_callbacks = ($footer_names[0] => \&display_slideshow, $footer_names[1] => \&display_radio, $footer_names[2] => \&display_playlists, $footer_names[3] => \&display_albums_by_letter, $footer_names[4] => \&display_artists_by_letter, $footer_names[5] => \&display_ha);

my %pids;
my $pictures_q = Thread::Queue->new;
my $pictures_event;
my $music_event;
my $backlight_event;

my %callbacks;
my $num_callbacks;
my $music_library_key;
my $playlists_library_key;
my %thumbnails;                  # hash containing url of thumbnails that are being downloaded

# <artist name first letter> -> ref to hash 1 of:
#   <artists name> -> ref to hash 2 of:
#     id -> id of artist
#     name -> name of artist
#     albums -> ref to hash 3 of:
#       <album id> -> ref to hash 4 of:
#         title -> album name
#         artist -> ref to artists name hash 2
#         tracks -> ref to hash 5 of:
#           <index> -> ref to hash 6 of:
#             duration -> track length in ms
#             title -> track title
#             id -> id of media file
my %artists_by_letter;
my %artists_by_id;
my %album_id_to_artist_id;

# <playlist Id> -> ref to hash of
#   name -> playlist title
#   tracks -> ref to array of ref to hash of
#     id -> id of track
#     album_title -> title of album track is from
#     track_title -> title of track
#     artist_name -> name of artist
#     duration -> track length in ms
my %playlists;

# <album name first letter> -> ref to array of ref to hash 4 above (sorted by album name)
my %albums_by_letter;
my %tmp_albums_by_letter;


$SIG{'QUIT'} = $SIG{'HUP'} = $SIG{'INT'} = $SIG{'KILL'} = $SIG{'TERM'} = sub { exec("pkill perl"); exit; };


#----------------------------------------------------------------------------------------------------------------------
sub set_display_mode {
  my $new = shift;
  return if $new == $mode_display_area;
  print_error("Setting new display mode $new");
  $mode_display_area = $new;
  print_heading($display_mode_headings[$mode_display_area]);
  #$playing_params[$mode_playing_area]->{"update_fn"}();
  if ($mode_display_area == DISPLAY_SLIDESHOW) {
    setup_main_area_for_photos();
    start_displaying_pictures();
  } else {
    setup_main_area_for_others();
    stop_displaying_pictures();
  }
}

sub set_play_mode {
  $mode_playing_area = shift;
  #clear_play_area(($mode_display_area == DISPLAY_SLIDESHOW) ? 0 : 1) if $mode_playing_area == PLAYING_NOTHING;
}

sub stop_all_audio {
  $audio_q[0]->enqueue({"command" => "stop"});
  `pkill vlc`;
  set_play_mode(PLAYING_NOTHING);
}

#----------------------------------------------------------------------------------------------------------------------
sub check_and_display {
  print_error("Checking and displaying picture");
  if (!defined $pictures) {
    display_string("Gathering list of pictures", 1);
  } else {
    my $num_pics = scalar @$pictures;
    if ($num_pics == 0) {
      display_string("No pictures found", 1);
    } else {
      my $path = $$pictures[int(rand($num_pics))];
      if (-e "images/sleeping.png") {
        my @time = localtime();
        if (($time[2] > 21) || ($time[2] < 9)) {
          $path = "images/sleeping.png";
        }
      }
      if ($mode_display_area == DISPLAY_SLIDESHOW) {
        #display_string("$path", 1);
        display_photo($path);
      }
    }
  }
}

sub stop_displaying_pictures {
  Glib::Source->remove($pictures_event) if defined $pictures_event;
}

sub start_displaying_pictures {
  Glib::Timeout->add(10, sub {
    check_and_display();
    $pictures_event = Glib::Timeout->add(10000, sub {                   # check every 10s for displaying pictures
      check_and_display();
      return 1;                                       # Continue the timeout
    });
    return 0;                                       # Do not repeat this timeout
  });
}

#----------------------------------------------------------------------------------------------------------------------
sub display_slideshow {
  print_error("Back to displaying pictures");
  set_display_mode(DISPLAY_SLIDESHOW);
  if (!defined $pictures) {
    display_string("Gathering list of pictures", 1);
  } else {
    display_string("Please wait ...", 1);
  }
}

#----------------------------------------------------------------------------------------------------------------------
sub display_radio {
  set_display_mode(DISPLAY_RADIO);
  display_radio_top($radio_stations_ref, \&play_radio);
}

sub update_radio_playing {
  #display_playing_radio($playing_params[PLAYING_RADIO]->{"station"}, $radio_stations_ref, \$transport_icon_areas);
}

sub play_radio {
  my ($input) = @_;
  stop_all_audio();
  print_error("play radio $input");
  $audio_q[0]->enqueue({"command" => "play", "path" => $radio_stations_ref->{$input}->{"url"}});
  set_play_mode(PLAYING_RADIO);
  $playing_params[PLAYING_RADIO]->{"station"} = $input;
  #update_radio_playing();
}

#----------------------------------------------------------------------------------------------------------------------
sub display_playlists {
#  display_playlists_core();
}

#----------------------------------------------------------------------------------------------------------------------
# display grid of first characters of album names
sub display_albums_by_letter {
#  clear_display_area(0);
#  set_display_mode(DISPLAY_ALBUMS_LETTER);
  my %inputs = ();
  if (scalar keys %albums_by_letter) {                # album list is available?
    foreach my $letter (keys %albums_by_letter) {
      $inputs{$letter} = {"cb" => \&display_albums_by_icon};
    }
#    display_albums_top(\%inputs);
  } else {                                            # still waiting for album list to be compiled
#    display_string("Please wait ...", 0);
  }
  $displaying_params[DISPLAY_ALBUMS_ICON]->{"index"} = 0;
}

#----------------------------------------------------------------------------------------------------------------------
sub display_ha {
#  clear_display_area(0);
  set_display_mode(DISPLAY_HA);
#  display_home_assistant($mqtt_data_ref, 1);
}

#----------------------------------------------------------------------------------------------------------------------
# display grid of first characters of artist names
sub display_artists_by_letter {
#  clear_display_area(0);
#  set_display_mode(DISPLAY_ARTISTS_LETTER);
  my %inputs = ();
  if (scalar keys %artists_by_letter) {                # artist list is available?
    foreach my $letter (keys %artists_by_letter) {
      $inputs{$letter} = {"cb" => \&display_artists_by_icon};
    }
#    display_artists_top(\%inputs);
  } else {                                            # still waiting for artist list to be compiled
#    display_string("Please wait ...", 0);
  }
  $displaying_params[DISPLAY_ARTISTS_ICON]->{"index"} = 0;
}



#----------------------------------------------------------------------------------------------------------------------
init_fb();

print_footer(\@footer_names, \%footer_callbacks);
set_display_mode(DISPLAY_SLIDESHOW);

$pids{"GatherPictures"} = threads->create(sub {
  $path_to_pictures = "/mnt/shared/Media/My Pictures/1963";
  while (1) {
    print_error("Starting gathering pictures");
    $pictures_q->enqueue(Gather::gather_pictures($path_to_pictures));
    print_error("Finishing gathering pictures");
    sleep 60 * 60 * 24; # once a day
  };
})->detach();

Glib::Timeout->add(500, sub {                         # check every 500ms for new pictures list
  if (my $pics_ref = $pictures_q->dequeue_nb()) {
    $pictures = $pics_ref;
    print_error("Received pictures list with " . scalar(@$pics_ref) . " pictures");
  }
  return 1;                 # Continue the timeout
});

$pids{"audio"} = threads->create(sub{
  audio_task();
})->detach();

Glib::Timeout->add(200, sub {                        # check every 200ms for audio messages
  if (my $message = $audio_q[1]->dequeue_nb()) {
    if ($message eq "play_stopped") {
      print_error("play stopped, mode = $mode_playing_area");
      #album_next_track() if $mode_playing_area == PLAYING_ALBUM;
      #playlist_next_track() if $mode_playing_area == PLAYING_PLAYLIST;
    }
  }
  return 1;                 # Continue the timeout
});

=for comment

# Note: Jellyfin does not like being hammered by http requests hence the ones for thumbnails are queued and serialised
$pids{"Http"} = spawn {
  receive {
    msg get_json => sub {
      my ($from, $url, $id) = @_;
      #print STDERR "Getting json file from $url\n";
      http_request(
        GET => $url, 
        sub {
          my ($body, $hdr) = @_;
          my $jp = JSON::Parse->new ();
          $jp->warn_only (1);
          #print_error($body);
          snd($from, "response", $body ? $jp->parse($body) : "", $$hdr{Status} =~ /^2/, $id, $url);
        });
    };
    msg get_thumb => sub {
      my ($from, $image, $id) = @_;
      my $url = "/Items/$image/Images/Primary?ApiKey=$jellyfin_apikey&format=Jpg";
      if (length($image) == 0) {                              # don't bother if image id is blank
        snd($from, "response", undef, undef, $id, $url);
        return;
      }
      #print_error "Getting thumbnail file from $url";
      Http::download($url, undef, "thumbnail_cache", sub {
        my ($res, $http_resp_ref) = @_;                                   # $_[0] is 1 for ok, 0 for retriable error and undefined for error
        snd($from, "response", undef, $res, $id, $url);
      });
    };
  };
};

$pids{"Input"} = spawn {
  receive {
    msg "start" => sub {
      my ($from, $ref) = @_;
      snd(0, "input", Input::input_task());
    };
  };
};

$pids{"Photos"} = spawn {
  receive {
    msg "prepare" => sub {
      my ($from, $fname) = @_;
      snd(0, "photo", Photos::prepare_photo_task($fname));
    };
  };
};

$pids{"MQTT"} = spawn {
  my $running = 0;
  sleep(60);               # give time for MQTT server to start, should replace this with check for mqtt process later
  Event->timer(interval => 30, cb => sub {            # check for new MQTT messages 30s
    return if ($running);
    $running = 1;
    #print_error("Checking for MQTT messages");
    my $data_ref = MQTT::get_mqtt_values();
    #print_hash_params($data_ref);
    snd(0, "mqtt", $data_ref); 
    $running = 0;
  });
  receive {
  };
};

$pids{"HealthCheck"} = spawn {                    # ping to healthcheck.io to say we're still running
  Event->timer(after => 10, interval => 55, cb => sub {  
    my @res = system("/bin/bash -c 'curl $health_check_url' > /dev/null 2>&1");
  });
  receive {
  };
};

$pictures_event = Event->timer(after => 0, interval => 10, cb => sub { check_and_display(); });         # slide show
snd($pids{"Input"}, "start", \$input_areas[$mode_display_area]);
snd($pids{"audio"}, "init");
turn_display_on();

$music_event = Event->timer(after => 0, interval => 60 * 2, cb => sub { 
  if (keys %thumbnails) {
    if ($music_event->interval == 60 * 2) {
      my $hour = (localtime())[2];
      if ($hour == 0) {
        $music_event->interval(3600 * 24);                    # rebuild list of music every midnight
      }
      return;
    }
  } 
  gather_music(); 
});

$backlight_event = Event->timer(after => 60, interval => 60 * 10, cb => sub {       # turn display on/off depending on yaml schedule
  my $hour = (localtime())[2];
  #print_error("backlight event at $hour");
  if ($hour == $$display_times_ref{"off-time"}) {
    turn_display_off();
    $backlight_event->interval(3600) if $backlight_event->interval < 3600;
  }
  if ($hour == $$display_times_ref{"on-time"}) {
    turn_display_on();
    $backlight_event->interval(3600) if $backlight_event->interval < 3600;
  }
});

receive {
  msg "photo" => sub {
    my ($from, $ref, $fname) = @_;
    #print_error("received photo message");
    if ($mode_display_area == DISPLAY_SLIDESHOW) {
      display_photo($ref, $fname);
    }
  };
  msg "input" => sub {
    my ($from, $final_x, $final_y, $init_x, $init_y) = @_;
    #print_error("Input = $final_x, $final_y, $init_x, $init_y");
    my $input = Input::what_input($input_areas[$mode_display_area], $footer_icon_areas, $transport_icon_areas, $final_x, $final_y, $init_x, $init_y);
    print_error("what_input: $input");
    snd($pids{"Input"}, "start");
    if (! defined $input) {
      print_error("Dumping input: $input");
    } else {
      if ($input_areas[$mode_display_area]->{$input}->{"cb"}) {             # first check for input in the display area
        $input_areas[$mode_display_area]->{$input}->{"cb"}->($input);
      } else {
        if (exists $footer_callbacks{$input}) {                             # now look for input in footer
          $footer_callbacks{$input}->();
        } else {
          if (exists $playing_params[$mode_playing_area]->{$input}) {                        # finally check transport icons
            $playing_params[$mode_playing_area]->{$input}->();
          } else {
            if (exists $swipe_callbacks[$mode_display_area]->{$input}) {                        # finally check transport icons
              $swipe_callbacks[$mode_display_area]->{$input}->();
            } else {
              print_error("No callback defined for $input");
            }
          }
        }
      }
    }
  };
  msg "response" => sub {
    call_callback(@_);
  };
  msg "mqtt" => sub {
    my ($from, $data_ref) = @_;
    #print_hash_params($data_ref);
    $mqtt_data_ref = $data_ref;
    if ($mode_display_area == DISPLAY_HA) {
      display_home_assistant($data_ref, 0);
    }
  };
};
=cut

print_error("Starting graphics");
start_graphics();
