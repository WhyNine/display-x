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
#use MQTT;

use Gtk3 -init;
use Glib;
use Cairo;
#use Event;
#use AnyEvent::HTTP;
use JSON::Parse;
use threads;
use threads::shared;
use Thread::Queue;                # Note always need threads before Thread::Queue
use Furl;

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

my @transport_buttons_radio = ({"icon-filename" => "stop", "callback" => \&transport_stop});        # radio only has stop
my @transport_buttons_playlist_play = ({"icon-filename" => "stop", "callback" => \&transport_stop}, 
                                       {"icon-filename" => "play", "callback" => \&transport_play}, 
                                       {"icon-filename" => "next", "callback" => \&playlist_next_track});
my @transport_buttons_playlist_pause = ({"icon-filename" => "stop", "callback" => \&transport_stop}, 
                                        {"icon-filename" => "pause", "callback" => \&transport_pause}, 
                                        {"icon-filename" => "next", "callback" => \&playlist_next_track});

my @transport_buttons_album_play = ({"icon-filename" => "back", "callback" => \&album_prev_track}, 
                                    {"icon-filename" => "stop", "callback" => \&transport_stop}, 
                                    {"icon-filename" => "play", "callback" => \&transport_play}, 
                                    {"icon-filename" => "next", "callback" => \&album_next_track});
my @transport_buttons_album_pause = ({"icon-filename" => "back", "callback" => \&album_prev_track}, 
                                     {"icon-filename" => "stop", "callback" => \&transport_stop}, 
                                     {"icon-filename" => "pause", "callback" => \&transport_pause}, 
                                     {"icon-filename" => "next", "callback" => \&album_next_track});

my %pids;
my $pictures_q = Thread::Queue->new;
my $pictures_event;
my $music_event;
my $backlight_event;

use constant TO_THREAD => 0;
use constant FROM_THREAD => 1;
# Note audio_q is defined in Audio.pm
my @http_q = (Thread::Queue->new, Thread::Queue->new);   # [0] is to send messages to http thread, [1] is to receive messages from http thread
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
  if ($mode_display_area == DISPLAY_SLIDESHOW) {
    setup_main_area_for_photos();
    start_displaying_pictures();
  } else {
    setup_main_area_for_others();
    stop_displaying_pictures();
  }
  $playing_params[$mode_playing_area]->{"update_fn"}();
}

sub set_play_mode {
  $mode_playing_area = shift;
  clear_play_area() if $mode_playing_area == PLAYING_NOTHING;
}

sub stop_all_audio {
  $audio_q[0]->enqueue({"command" => "stop"});
  `pkill vlc`;
  set_play_mode(PLAYING_NOTHING);
}

sub update_nothing_playing {
  display_playing_nothing();
}

#----------------------------------------------------------------------------------------------------------------------
sub transport_stop {
  stop_all_audio();
  set_play_mode(PLAYING_NOTHING);
}

sub transport_pause {
  $audio_q[TO_THREAD]->enqueue({"command" => "pause_play"});
  print_error("transport pause");
  $playing_params[$mode_playing_area]->{"paused"} = 1;
  $playing_params[$mode_playing_area]->{"update_fn"}->();
}

sub transport_play {
  $audio_q[TO_THREAD]->enqueue({"command" => "pause_play"});
  print_error("transport play");
  $playing_params[$mode_playing_area]->{"paused"} = 0;
  $playing_params[$mode_playing_area]->{"update_fn"}->();
  #update_playlist_playing();
}

#----------------------------------------------------------------------------------------------------------------------
sub gen_id {
  my @set = ('0' ..'9', 'A' .. 'Z', 'a' .. 'z');
  return join '' => map $set[rand @set], 1 .. 20;
};

sub add_apikey {
  my ($base, $key) = @_;
  if (index($base, "?") == -1) {
    return "$base?ApiKey=$key";
  } else {
    return "$base&ApiKey=$key";
  }
}

# got hash keys $a and $b automatically
sub album_sort {
  return remove_leading_article($a->{"title"}) cmp remove_leading_article($b->{"title"});
}

sub numeric_sort {
  return $a <=> $b;
}

sub get_json {
  my ($url, $cb) = @_;
  my $id = gen_id();
  $callbacks{$id} = $cb;
  $http_q[TO_THREAD]->enqueue({"command" => "get_json", "url" => add_apikey($jellyfin_url . $url, $jellyfin_apikey), "id" => $id});
};

sub get_thumb {
  my ($image, $cb) = @_;
  #print_error("Fetching thumbnail for $image");
  return if $thumbnails{$image};        # return if already fetched this id
  $thumbnails{$image} = 1;
  my $id = gen_id();
  $callbacks{$id} = $cb;
  $http_q[TO_THREAD]->enqueue({"command" => "get_thumb", "id" => $id, "image" => $image});
};

sub call_callback {
  my $resp_ref = shift;
  my ($json, $status, $id, $url) = ($$resp_ref{"body"}, $$resp_ref{"success"}, $$resp_ref{"id"}, $$resp_ref{"url"});
  #print_error("Callback for id $id, status = $status, url = $url");
  my $cb = $callbacks{$id};
  delete $callbacks{$id};
  &$cb($json, $status, $url) if $cb;
  if (scalar(keys %callbacks) == 0) {
    compile_list_of_albums();
    print_error("Done gathering music");
    %albums_by_letter = (%tmp_albums_by_letter);
    %tmp_albums_by_letter = undef;
  }
}

# Check that arg1 is a ref to a hash containing a key for arg2
# return 0 if check fails, else 1
sub check_hash_for_item {
  my $ref = shift;
  my $key = shift;
  if (ref($ref) ne "HASH") {
    print_error("Expecting HASH in JSON with $key");
    return 0;
  }
  my %hash = %$ref;
  if (! $hash{$key}) {
    print_error("No $key in JSON");
    return 0;
  }
  return 1;
}

# Check that arg1 is a ref to an array
# return 0 if check fails, else 1
sub check_array {
  my $ref = shift;
  if (ref($ref) ne "ARRAY") {
    print_error("Expecting ARRAY in JSON");
    return 0;
  }
  return 1;
}

sub find_artist_ref {
  my $name = shift;
  my $ref = $artists_by_letter{uc substr($name, 0, 1)}->{$name};
  if (defined $ref) {
    return $ref;
  }
  print_error("Ooops, can't find artist data for $name");
  return undef;
}

sub get_albums_tracks {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $ref = $$json{"Items"};
  return unless check_array($ref);
  my $album_id = $$ref[0]->{"AlbumId"};
  #print_error("parsing tracks for album $album_id which has tracks no. = " . scalar @$ref);
  my $artist_id = $album_id_to_artist_id{$album_id};
  my $artist_name = $artists_by_id{$artist_id};
  utf8::decode($artist_name);
  my $artist_data_ref = find_artist_ref($artist_name);
  return unless (defined $artist_data_ref);
  my $albums_ref = $$artist_data_ref{"albums"};
  my $album_data_ref = $$albums_ref{$album_id};
  return unless (defined $album_data_ref);
  my %tracks;                                       # hash of tracks on the album
  foreach my $track_ref (@$ref) {
    return if $$track_ref{"Type"} ne "Audio";
    my $t = 0;
    if ($$track_ref{"IndexNumber"}) {
      $t = $$track_ref{"IndexNumber"};
    }
    $tracks{$t} = {};
    $tracks{$t}->{"duration"} = $$track_ref{"RunTimeTicks"} / 10000;
    $tracks{$t}->{"title"} = $$track_ref{"Name"};
    utf8::decode($tracks{$t}->{"title"});
    $tracks{$t}->{"id"} = $$track_ref{"Id"};
    #print_error($tracks{$t}->{"id"});
  }
  $$album_data_ref{"tracks"} = \%tracks;
  return 1;
}

sub get_parentId_from_url {
  my $str = shift;
  my $pos = index($str, "parentId=");
  return if $pos == -1;
  return substr($str, $pos + 9, 32);
}

# get data for an artist and their albums
sub get_artists_albums {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $albums_ref = $$json{"Items"};
  return unless check_array($albums_ref);
  my $artist_id = get_parentId_from_url($url);
  my $artist_name = $artists_by_id{$artist_id};
  utf8::decode($artist_name);
  my $artist_data_ref = find_artist_ref($artist_name);
  return unless (defined $artist_data_ref);
  my $hash_ref;                                 # ref to hash of album data
  if ($$artist_data_ref{"albums"}) {
    $hash_ref = $$artist_data_ref{"albums"};
  } else {
    $hash_ref = {};
  }
  my $ref;
  foreach $ref (@$albums_ref) {
    next unless check_hash_for_item($ref, "Name");
    next if $$ref{"Type"} ne "MusicAlbum";
    $album_id_to_artist_id{$$ref{"Id"}} = $artist_id;
    $$hash_ref{$$ref{"Id"}} = {} unless $$hash_ref{$$ref{"Id"}};
    $$hash_ref{$$ref{"Id"}}->{"id"} = $$ref{"Id"};
    get_thumb($$ref{"Id"}) if $$ref{"Id"};
    $$hash_ref{$$ref{"Id"}}->{"title"} = $$ref{"Name"};
    utf8::decode($$hash_ref{$$ref{"Id"}}->{"title"});
    $$hash_ref{$$ref{"Id"}}->{"artist"} = $artist_data_ref;
    #print_error("Album = " . $$ref{"Name"} . ", id = " . $$ref{"Id"} . ", user id = $jellyfin_user_id");
    get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$ref{"Id"}, sub {parse_error() if !get_albums_tracks(@_);});
  }
  foreach my $key (keys %$hash_ref) {                  # now check for any deleted albums
    my $found = 0;
    foreach $ref (@$albums_ref) {
      if ($key eq $$ref{"key"}) {
        $found = 1;
        last;
      }
    }
    delete $$hash_ref{$ref} unless $found;
  }
  $$artist_data_ref{"albums"} = $hash_ref unless $$artist_data_ref{"albums"};
  return 1;
}

# parse music library top level, which lists all album artists
sub process_music_library {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  return unless check_hash_for_item($json, "Items");
  my $ref = $$json{"Items"};
  return unless check_array($ref);
  foreach $ref (@$ref) {
    next unless check_hash_for_item($ref, "Name");             # check artist has a name
    next if $$ref{"Type"} ne "MusicArtist";
    utf8::decode($$ref{"Name"});
    $artists_by_id{$$ref{"Id"}} = $$ref{"Name"};
    #print_error("Found artist " . $$ref{"Name"});
    my $first_char = uc substr($$ref{"Name"}, 0, 1);              # get first char of name
    if (! defined $artists_by_letter{$first_char}) {
      $artists_by_letter{$first_char} = {};
    }
    my $data_ref = $artists_by_letter{$first_char};
    my $artist_ref;
    if ($$data_ref{$$ref{"Name"}}) {
      $artist_ref = $$data_ref{$$ref{"Name"}};
    } else {
      $artist_ref = {};
    }
    $$artist_ref{"id"} = $$ref{"Id"};
    get_thumb($$artist_ref{"id"}) if $$artist_ref{"id"};
    $$artist_ref{"name"} = $$ref{"Name"};
    #print_error("added artist " . $$artist_ref{"name"} . " with id " . $$ref{"Id"});
    $$data_ref{$$ref{"Name"}} = $artist_ref unless $$data_ref{$$ref{"Name"}};
    get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$ref{"Id"}, sub {parse_error() if !get_artists_albums(@_);});
  }
  return 1;
}

# parse list of top level folders, which will be photos and music
sub process_library_sections {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $i (@array) {
    if (check_hash_for_item($i, "CollectionType")) {
      if (($$i{"CollectionType"} eq "music") and ($$i{"Path"} =~ /Music/)) {                     # music library
        $music_library_key = $$i{"Id"};
      }
    }
  }
  return unless $music_library_key;
  get_json("/Items?userId=$jellyfin_user_id&parentId=$music_library_key", sub {parse_error() if !process_music_library(@_);});
  #print_error("Start looking for playlists");
  foreach my $i (@array) {
    if (check_hash_for_item($i, "CollectionType")) {
      if ($$i{"CollectionType"} eq "playlists") {                     # playlists library
        $playlists_library_key = $$i{"Id"};
      }
    }
  }
  return unless $playlists_library_key;
  get_json("/Items?userId=$jellyfin_user_id&parentId=$playlists_library_key", sub {parse_error() if !process_playlists_top(@_);});
  return 1;
}

sub parse_error {
  print_error("Hmm, something went wrong here");
}

# parse playlists
sub process_playlist_items {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  my $playlist_id = get_parentId_from_url($url);
  my @tracks = ();
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $track_ref (@array) {
    next unless check_hash_for_item($track_ref, "RunTimeTicks");
    my %track_info;
    $track_info{"duration"} = $$track_ref{"RunTimeTicks"} / 10000;
    $track_info{"album_id"} = $$track_ref{"AlbumId"};
    $track_info{"album_title"} = $$track_ref{"Album"};
    utf8::decode($track_info{"album_title"});
    $track_info{"track_title"} = $$track_ref{"Name"};
    utf8::decode($track_info{"track_title"});
    $track_info{"artist_name"} = $$track_ref{"AlbumArtist"};
    utf8::decode($track_info{"artist_name"});
    $track_info{"id"} = $$track_ref{"Id"};
    get_thumb($$track_ref{"Id"}) if $$track_ref{"Id"};
    #print_error("Playlast track id = $track_info{'id'}");
    push(@tracks, \%track_info);
    #print_error("Added track $track_info{'track_title'} // $track_info{'artist_name'} to playlist " . $playlists{$playlist_id}->{'name'});
  }
  $playlists{$playlist_id}->{"tracks"} = \@tracks;
  return 1;
}

# parse list of playlists
sub process_playlists_top {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  #print_error("Looking for list of playlists");
  return unless check_hash_for_item($ref, "Items");
  my %hash = %$ref;
  $ref = $hash{"Items"};
  return unless check_array($ref);
  my @array = @$ref;
  foreach my $i (@array) {
    if (check_hash_for_item($i, "Type")) {
      if ($$i{"Type"} eq "Playlist") {                     # audio playlist
        if (check_hash_for_item($i, "Name") && check_hash_for_item($i, "Id")) {
          utf8::decode($$i{"Name"});
          #print_error("Found playlist " . $$i{"Name"});
          $playlists{$$i{"Id"}} = {};
          $playlists{$$i{"Id"}}->{"name"} = $$i{"Name"};
          get_thumb($$i{"Id"});
          get_json("/Items?userId=$jellyfin_user_id&parentId=" . $$i{"Id"}, sub {parse_error() if !process_playlist_items(@_);});
        }
      }
    }
  }
  return 1;
}

sub extract_jellyfin_user_id {
  my ($json, $ok, $url) = @_;
  if (! $ok) {
    print_error("Unable to GET $url");
    return;
  }
  my $ref = $json;
  return unless check_array($ref);
  $jellyfin_user_id = $$ref[0]->{"Id"};
  print_error("Found JellyFin user Id ($jellyfin_user_id)");
  return 1;
}

sub find_jellyfin_user_id {
  my $cb = shift;
  get_json("/Users", sub{
    if (!extract_jellyfin_user_id(@_)) {
      parse_error();
      sleep(60);
    }
    &$cb();
  });
}

sub gather_music {
  if (audio_state() != 0) {
    print_error("Postpone gathering music as currently playing");
    return;
  }
  if (! defined $jellyfin_user_id) {
    print_error("Jellyfin user Id not defined");
    find_jellyfin_user_id(sub {gather_music();});
    return;
  }
  print_error("Start gathering music");
  %thumbnails = ();
  #get_json("/playlists", sub {parse_error() if !process_playlists_top(@_);});
  get_json("/Library/MediaFolders", sub {parse_error() if !process_library_sections(@_);});
}

sub compile_list_of_albums {
  %tmp_albums_by_letter = ();
  print_error("Starting album compilation");
  foreach my $artist_letter (keys %artists_by_letter) {
    my %hash1 = %{$artists_by_letter{$artist_letter}};
    foreach my $artist_name (keys %hash1) {
      my %hash2 = %{$hash1{$artist_name}};
      my %hash3 = %{$hash2{"albums"}};
      foreach my $album_key (keys %hash3) {
        my $album_first_letter = uc substr(remove_leading_article($hash3{$album_key}->{"title"}), 0, 1);
        my $alphanumerics = join('', ('0' ..'9', 'A' .. 'Z'));
        if (index($alphanumerics, $album_first_letter) == -1) {
          $album_first_letter = "#";
        }
        if (! $tmp_albums_by_letter{$album_first_letter}) {
          my @empty = ($hash3{$album_key});
          $tmp_albums_by_letter{$album_first_letter} = \@empty;
        } else {
          push(@{$tmp_albums_by_letter{$album_first_letter}}, $hash3{$album_key});
        }
      }
    }
  }
  foreach my $letter (keys %tmp_albums_by_letter) {
    @{$tmp_albums_by_letter{$letter}} = sort album_sort @{$tmp_albums_by_letter{$letter}};
  }
}

#----------------------------------------------------------------------------------------------------------------------
sub check_and_display {
  #print_error("Checking and displaying picture");
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
  if (defined $pictures_event) {
    Glib::Source->remove($pictures_event) ;
    $pictures_event = undef;
  }
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
  display_playing_radio($playing_params[PLAYING_RADIO]->{"station"}, $radio_stations_ref, \@transport_buttons_radio);
}

sub play_radio {
  my ($input) = @_;
  stop_all_audio();
  print_error("play radio $input");
  $audio_q[0]->enqueue({"command" => "play", "path" => $radio_stations_ref->{$input}->{"url"}});
  set_play_mode(PLAYING_RADIO);
  $playing_params[PLAYING_RADIO]->{"station"} = $input;
  update_radio_playing();
}

#----------------------------------------------------------------------------------------------------------------------
sub display_playlists {
  #print_error("playlists");
  set_display_mode(DISPLAY_PLAYLISTS);
  display_playlists_top(\%playlists, \&play_playlist);
}

sub update_playlist_playing {
  set_play_mode(PLAYING_PLAYLIST);
  my $transports;
  if ($playing_params[PLAYING_PLAYLIST]->{"paused"} == 0) {
    $transports = \@transport_buttons_playlist_pause;
  } else {
    $transports = \@transport_buttons_playlist_play;
  }
  display_playing_playlist($playing_params[PLAYING_PLAYLIST]->{"playlist"}, \%playlists, $playing_params[PLAYING_PLAYLIST]->{"track"}, $transports);
}

sub play_playlist {
  my ($input) = @_;
  stop_all_audio();
  print_error("play playlist $input " . $playlists{$input}->{"name"});
  $playing_params[PLAYING_PLAYLIST]->{"playlist"} = $input;
  my $tracks_ref = $playlists{$input}->{"tracks"};
  if (defined $tracks_ref) {
    $playing_params[PLAYING_PLAYLIST]->{"track"} = int rand(scalar @$tracks_ref);
    $audio_q[TO_THREAD]->enqueue({"command" => "play", "path" => "$jellyfin_url/Items/" . $playlists{$input}->{'tracks'}->[$playing_params[PLAYING_PLAYLIST]->{'track'}]->{'id'} . "/Download?ApiKey=$jellyfin_apikey"});
    $playing_params[PLAYING_PLAYLIST]->{"paused"} = 0;
    update_playlist_playing();
  } else {
    display_string("Please wait ...");
  }
}

sub playlist_next_track {
  stop_all_audio();
  my $title = $playing_params[PLAYING_PLAYLIST]->{"playlist"};
  my $track_ref = $playlists{$title}->{"tracks"};
  my $track_no = $playing_params[PLAYING_PLAYLIST]->{"track"};
  print_error("playlist next track, tracks left = " . scalar @$track_ref);
  if (scalar @$track_ref) {                                 # if only one track in array, leave it at same value (0)
    delete $playing_params[PLAYING_PLAYLIST]->{"track"};
    while (1) {
      $playing_params[PLAYING_PLAYLIST]->{"track"} = int rand(scalar @$track_ref);
      last if $playing_params[PLAYING_PLAYLIST]->{"track"} != $track_no;    # only break out of loop once we have a different track number
    }
  }
  $audio_q[TO_THREAD]->enqueue({"command" => "play", "path" => "$jellyfin_url/Items/" . $playlists{$title}->{'tracks'}->[$playing_params[PLAYING_PLAYLIST]->{'track'}]->{'id'} . "/Download?ApiKey=$jellyfin_apikey"});
  update_playlist_playing();
}

#----------------------------------------------------------------------------------------------------------------------
# display grid of first characters of album names
sub display_albums_by_letter {
  set_display_mode(DISPLAY_ALBUMS_LETTER);
  if (scalar keys %albums_by_letter) {                # album list is available?
    display_albums_top(\%albums_by_letter, \&display_albums_by_icon);
  } else {                                            # still waiting for album list to be compiled
    display_string("Please wait ...");
    #my %tmp = ('A'=> undef, 'G'=> undef, 'H'=> undef, 'M'=> undef, 'N'=> undef, 'O'=> undef, 'P'=> undef, 'Q'=> undef, 'R'=> undef, 'S'=> undef, 'T'=> undef, '4'=> undef, '1'=> undef, '2'=> undef, '3'=> undef, 'B'=> undef, 'C'=> undef, 'D'=> undef, 'E'=> undef, 'F'=> undef, 'J'=> undef, 'K'=> undef, 'L'=> undef, 'I'=> undef, 'W'=> undef, '#'=> undef);
    #display_albums_top(\%tmp, \&display_albums_by_icon)
  }
}

sub display_albums_by_icon {
  my ($input) = shift;
  #print_error("display albums with letter $input");
  $input = $displaying_params[DISPLAY_ALBUMS_ICON]->{"input"} unless $input;
  $displaying_params[DISPLAY_ALBUMS_ICON]->{"input"} = $input;                 # remember letter we are displaying
  set_display_mode(DISPLAY_ALBUMS_ICON);
  display_albums_with_letter($albums_by_letter{$input}, \&play_album);
}

sub update_album_playing {
  #print_error("update album playing");
  set_play_mode(PLAYING_ALBUM);
  my $transports_ref = ($playing_params[PLAYING_ALBUM]->{"paused"} == 0) ? \@transport_buttons_album_pause : \@transport_buttons_album_play;
  display_playing_album($playing_params[PLAYING_ALBUM]->{"album_ref"}, $playing_params[PLAYING_ALBUM]->{"track"}, $transports_ref);
}

sub play_album {
  my ($input) = shift;
  stop_all_audio();
  print_error("play $input");
  # need to look through albums_by_letter to find match with $input
  my $album_ref;
  foreach my $letter (keys %albums_by_letter) {
    my @albums = @{$albums_by_letter{$letter}};
    foreach my $ref (@albums) {
      my $tracks_ref = $$ref{"tracks"};
      if ($input eq construct_album_uid($ref)) {
        $album_ref = $ref;
        last;
      }
    }
    last if $album_ref;
  }
  unless ($album_ref) {
    print_error("oops, can't find album uid $input");
    display_slideshow();
    return;
  }
  $playing_params[PLAYING_ALBUM]->{"album_ref"} = $album_ref;                         # remember the album we are playing
  my @tracks = sort numeric_sort keys %{$album_ref->{"tracks"}};
  #print_error("Tracks in album: @tracks");
  my @paths;
  foreach my $i (@tracks) {
    #print_error($album_ref->{"tracks"}->{$i}->{"id"} . ", " . $album_ref->{"tracks"}->{$i}->{"title"});
    my $p = "$jellyfin_url/Items/" . $album_ref->{"tracks"}->{$i}->{"id"} . "/Download?ApiKey=$jellyfin_apikey";
    #print_error("Adding track $i: $p");
    $paths[$i] = $p;
  }
  $playing_params[PLAYING_ALBUM]->{"paths_array_ref"} = \@paths;                      # remember the tracks we are playing (note that not all array entries are used)
  unless (scalar @paths) {
    print_error("oops, can't find any valid tracks on album with uid $input");
    display_slideshow();
    return;
  }
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  foreach my $i (0 .. scalar @paths - 1) {            # find first track
    #my $track_url = $album_ref->{"tracks"}->{$tracks[0]}->{"url"};
    #print_error("track url $track_url");
    my $p = $paths[$i];
    if ($p) {
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # remember the track we are playing
      last;
    }
  }
  $audio_q[TO_THREAD]->enqueue({"command" => "play", "path" => $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]});
  $playing_params[PLAYING_ALBUM]->{"paused"} = 0;
  update_album_playing();
}

sub album_prev_track {
  stop_all_audio();
  my $current = $playing_params[PLAYING_ALBUM]->{"track"};
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  #print_error("current track = $current");
  foreach my $i (reverse(0 .. $current - 1)) {
    if ($playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$i]) {
      #print_error("setting track to $i");
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # move to the previous track
      last;
    }
  }
  $playing_params[PLAYING_ALBUM]->{"track"} = $current unless ($playing_params[PLAYING_ALBUM]->{"track"});                       # if we found another track to play
  $audio_q[TO_THREAD]->enqueue({"command" => "play", "path" => $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]});
  update_album_playing();
}

sub album_next_track {
  stop_all_audio();
  $playing_params[PLAYING_ALBUM]->{"paused"} = 0;
  my $current = $playing_params[PLAYING_ALBUM]->{"track"};
  delete $playing_params[PLAYING_ALBUM]->{"track"};
  #print_error("current track = $current");
  foreach my $i ($current + 1 .. scalar @{$playing_params[PLAYING_ALBUM]->{"paths_array_ref"}} - 1) {
    if ($playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$i]) {
      #print_error("setting track to $i");
      $playing_params[PLAYING_ALBUM]->{"track"} = $i;                                 # move to the next track
      last;
    }
  }
  if ($playing_params[PLAYING_ALBUM]->{"track"}) {                       # if we found another track to play
    $audio_q[TO_THREAD]->enqueue({"command" => "play", "path" => $playing_params[PLAYING_ALBUM]->{"paths_array_ref"}->[$playing_params[PLAYING_ALBUM]->{"track"}]});
    update_album_playing();
  }
}

#----------------------------------------------------------------------------------------------------------------------
sub display_ha {
#  clear_display_area(0);
  set_display_mode(DISPLAY_HA);
#  display_home_assistant($mqtt_data_ref, 1);
}

#----------------------------------------------------------------------------------------------------------------------
sub display_artist_albums_by_icon {
  my $input = shift;                            # arg is name of artist
  $input = $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"input"} unless $input;
  $displaying_params[DISPLAY_ARTISTS_ALBUM]->{"input"} = $input;                 # remember artist we are displaying
  set_display_mode(DISPLAY_ARTISTS_ALBUM);
  my $ref = $artists_by_letter{$displaying_params[DISPLAY_ARTISTS_ICON]->{"input"}};
  display_artist_albums_with_letter($ref->{$input}, \&play_album);
}

sub display_artists_by_icon {
  my $input = shift;                             # arg is letter of artist name
  $input = $displaying_params[DISPLAY_ARTISTS_ICON]->{"input"} unless $input;
  $displaying_params[DISPLAY_ARTISTS_ICON]->{"input"} = $input;                 # remember letter we are displaying
  set_display_mode(DISPLAY_ARTISTS_ICON);
  display_artists_with_letter($artists_by_letter{$input}, \&display_artist_albums_by_icon);
}

# display grid of first characters of artist names
sub display_artists_by_letter {
  set_display_mode(DISPLAY_ARTISTS_LETTER);
  if (scalar keys %artists_by_letter) {                # artist list is available?
    display_artists_top(\%artists_by_letter, \&display_artists_by_icon);
  } else {                                            # still waiting for artist list to be compiled
    display_string("Please wait ...");
  }
}

#----------------------------------------------------------------------------------------------------------------------
init_fb();

print_footer(\@footer_names, \%footer_callbacks);
set_display_mode(DISPLAY_SLIDESHOW);

$pids{"GatherPictures"} = threads->create(sub {
  #$path_to_pictures = "/mnt/shared/Media/My Pictures/1963";
  while (1) {
    print_error("Starting gathering pictures");
    $pictures_q->enqueue(Gather::gather_pictures($path_to_pictures));
    print_error("Finishing gathering pictures");
    sleep 60 * 60 * 24; # once a day
  };
})->detach();

$pids{"audio"} = threads->create(sub{
  audio_task();
})->detach();

# Note: Jellyfin does not like being hammered by http requests hence everything is queued and serialised
$pids{"http"} = threads->create(sub{
  my $furl = Furl->new( timeout => 120 );                 # jellyfin can be quite slow with the large responses
  if (!defined $furl) {
    print_error("Failed to create Furl object");
    return;
  }
  my $jp = JSON::Parse->new ();
  $jp->warn_only (1);
  while (1) {
    my $message = $http_q[TO_THREAD]->dequeue();
    if ($$message{"command"} eq "get_json") {
      #print_error("Getting json file from $$message{'url'}");
      my $fresp = $furl->get($$message{"url"});
      if (! $fresp->is_success) {
        $fresp = $furl->get($$message{"url"});                  # try again
      }
      my $parsed_json = $fresp->body ? $jp->parse($fresp->decoded_content) : "";
      print_error($$message{"url"}) if !defined $parsed_json;
      my %response = (
        "body" => $parsed_json,
        "success" => $fresp->is_success,
        "id" => $$message{"id"},
        "url" => $$message{"url"}
      );
      $http_q[FROM_THREAD]->enqueue(\%response);
    }
    if ($$message{"command"} eq "get_thumb") {
      my ($image, $id) = ($$message{"image"}, $$message{"id"});
      #print_error("Fetching thumbnail for $image");
      my $url = "/Items/$image/Images/Primary?ApiKey=$jellyfin_apikey&format=Jpg";
      if (length($image) == 0) {                              # don't bother if image id is blank
        my %response = (
          "body" => undef,
          "success" => undef,
          "id" => $id,
          "url" => $url
        );
        $http_q[FROM_THREAD]->enqueue(\%response);
        return;
      }
      #print_error "Getting thumbnail file from $url";
      Http::download($url, undef, "thumbnail_cache", sub {
        my ($res, $http_resp_ref) = @_;                                   # $_[0] is 1 for ok, 0 for retriable error and undefined for error
        my %response = (
          "body" => undef,
          "success" => $res,
          "id" => $id,
          "url" => $url
        );
        $http_q[FROM_THREAD]->enqueue(\%response);
      });
    }
  }
})->detach();

Glib::Timeout->add(500, sub {                         # check every 500ms for new pictures list
  if (my $pics_ref = $pictures_q->dequeue_nb()) {
    $pictures = $pics_ref;
    print_error("Received pictures list with " . scalar(@$pics_ref) . " pictures");
  }
  return 1;                 # Continue the timeout
});

Glib::Timeout->add(200, sub {                         # check every 200ms for audio messages
  if (my $message = $audio_q[1]->dequeue_nb()) {
    if ($message eq "play_stopped") {
      print_error("play stopped, mode = $mode_playing_area");
      #album_next_track() if $mode_playing_area == PLAYING_ALBUM;
      #playlist_next_track() if $mode_playing_area == PLAYING_PLAYLIST;
    }
  }
  return 1;                 # Continue the timeout
});

Glib::Timeout->add(100, sub {                         # check every 24hrs at midnight for music library changes
  gather_music();
  my $hour = (localtime())[2];
  Glib::Timeout->add((24 - $hour) * 3600 * 1000, sub {    # wait until midnight
    gather_music();
    Glib::Timeout->add(24 * 3600 * 1000, sub {        # real timer to check music library every 24 hours at midnight
      gather_music();
      return 1;
    });
    return 0;
  });
  return 0;
});

Glib::Timeout->add(100, sub {                         # check every 100ms for http responses
  while (my $response_ref = $http_q[FROM_THREAD]->dequeue_nb()) {
    call_callback($response_ref);
  }
  return 1;                 # Continue the timeout
});

=for comment

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

receive {
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
