package Graphics;

use v5.28;
use strict;

our @EXPORT = qw ( init_fb clear_screen display_photo display_string display_albums_top display_albums_with_letter display_playing_album display_playlists_top display_playing_playlist 
  print_transport_icons display_artists_top display_artists_with_letter display_artist_albums_with_letter display_radio_top display_playing_radio print_heading print_footer display_playing_radio_details 
  clear_play_area clear_display_area prepare_photo display_home_assistant display_playing_nothing start_graphics setup_main_area_for_photos setup_main_area_for_others );
use base qw(Exporter);

use lib "/home/pi/display";

use Utils;
use MQTT;

use Gtk3 -init;
use Glib;
use Cairo;
use Pango;
use List::Util qw(min);
use File::Basename;
use Image::ExifTool qw(:Public);
use Error ':try';
use Math::Libm ':all';

my $window;
use constant WIDTH => 720;
use constant HEIGHT => 1280;
my $header_container;                         # Horizontal box for the header icons and text
my $main_area;                                # Main area for application content (vbox)
my $footer_container;                         # Vertical box for the footer buttons
my $full_playing_area = 0;                    # 1 = full playing area, 0 = minimal playing area (slideshow)

my @yellow = (1, 1, 0);
my @pale_yellow = (0.94, 0.94, 0.24);
my @dark_green = (0.2, 0.67, 0.08);
my @gray = (0.3, 0.3, 0.3);

my %orientations = (
  "1" => sub {my $image = shift; return $image;},
  "2" => sub {my $image = shift; return mirror($image, 1);},
  "3" => sub {my $image = shift; return rotate_cw($image, 'rotate180');},
  "4" => sub {my $image = shift; return mirror($image, 0);},
  "5" => sub {my $image = shift; return rotate_cw(mirror($image, 1), 'counterclockwise');},
  "6" => sub {my $image = shift; return rotate_cw($image, 90);},
  "7" => sub {my $image = shift; return rotate_cw(mirror($image, 1), 'clockwise');},
  "8" => sub {my $image = shift; return rotate_cw($image, 270);},
  ""  => sub {my $image = shift; return $image;},
  "Unknown (0)" => sub {my $image = shift; return $image;},
);

sub delete_all_children {
  my ($box) = @_;
  return unless defined $box;
  my @children = $box->get_children;
  foreach my $child (@children) {
    $box->remove($child);
  }
}

sub delete_first_child {
  my ($box) = @_;
  my @children = $box->get_children;
  $box->remove($children[0]) if @children;
}

sub insert_as_first_child {
  my ($box, $child) = @_;
  $box->pack_start($child, 0, 0, 0);
  $box->reorder_child($child, 0);          # Ensure it's at the top
}

sub load_image {
  my ($file_path, $size, $h) = @_;
  $h = (defined $h) ? $h : $size;
  my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file_at_scale($file_path, $size, $h, 1);
  if (!$pixbuf) {
    print_error("Failed to load pixbuf from $file_path!");
    return;
  }
  my $image = Gtk3::Image->new;
  $image->set_from_pixbuf($pixbuf);
  return $image;
}

# args: image_path, alt_image_path, size
# Note: if frame required, add class outlined-box to container
sub create_square_image {
  my ($image_path, $alt_image_path, $size) = @_;
  if (! -e $image_path) {
    print_error("Unable to load thumbnail $image_path");
    $image_path = $alt_image_path;
  }
  my $image = load_image($image_path, $size);
}

sub return_string_from_file {
  my ($file_path) = @_;
  open my $fh, '<', $file_path or do {
    print_error("Could not open file '$file_path': $!");
    return '';
  };
  local $/ = undef;
  my $content = <$fh>;
  close $fh;
  return $content;
}

# --- Drawing Function (Draws the single horizontal line) ---
sub on_draw_horizontal_separator {
    my ($widget, $context) = @_;
    #print_error("Drawing horizontal separator");
    my $width = $widget->get_allocated_width;
    my $height = $widget->get_allocated_height;
    $context->set_source_rgb(@yellow);
    $context->set_line_width($height);
    # Draw the horizontal line near the bottom edge of its area
    $context->move_to(0, $height / 2);
    $context->line_to($width, $height / 2);
    $context->stroke;
    return 1;
}

sub construct_horizontal_separator {
  my $height = shift;
  my $h_sep_area = Gtk3::DrawingArea->new;
  $h_sep_area->set_size_request(-1, $height);                             # fix height to specified pixels, width fills available space
  $h_sep_area->signal_connect('draw' => \&on_draw_horizontal_separator);
  return $h_sep_area;
}

sub display_string {
  my ($str) = @_;
  print_error("Displaying string: $str");
  delete_first_child($main_area);
  my $text_box = Gtk3::Label->new($str);
  add_style_class($text_box, 'display-string-style');
  add_style_class($text_box, ($full_playing_area == 1) ? 'half-main-area-style' : 'information-style');
  insert_as_first_child($main_area, $text_box);
  $window->show_all;
}

sub add_style_class {
  my ($widget, $class_name) = @_;
  my $context = $widget->get_style_context;
  $context->add_class($class_name);
}

# Create small icon with  title below
# Args: title, url of icon, callback address, arg to pass to callback
sub create_scroll_item_with_title {
  my (%args) = @_;
  my $title1 = $args{'title1'};
  my $title2 = $args{'title2'};
  my $fname = $args{'icon_path'};
  my $callback = $args{'callback'};
  my $arg = $args{'callback_arg'};
  #print_error("display scroll item: $title, $fname");
  my $icon = create_square_image($fname, "images/missing-image-icon.jpg", 200);
  my $icon_vbox = Gtk3::Box->new('vertical', 0);
  $icon_vbox->pack_start($icon, 0, 0, 0);
  my $icon_title = Gtk3::Label->new($title1);
  add_style_class($icon_title, 'scroll-item-title-style');
  $icon_title->set_line_wrap(1);
  $icon_title->set_halign('center');
  $icon_vbox->pack_start($icon_title, 0, 0, 0);
  if ($title2) {
    my $icon_artist = Gtk3::Label->new($title2);
    add_style_class($icon_artist, 'scroll-item-title2-style');
    $icon_artist->set_line_wrap(1);
    $icon_artist->set_halign('center');
    $icon_vbox->pack_start($icon_artist, 0, 0, 0);
  }
  my $icon_button = Gtk3::Button->new;
  $icon_button->add($icon_vbox);
  $icon_button->signal_connect('clicked' => sub {
    &$callback($arg);
  });
  return $icon_button;
}

sub construct_scrolled_grid_box {
  my $spacing = shift;
  my $scrolled_window = Gtk3::ScrolledWindow->new(undef, undef);    # Main container for the scrolling area
  add_style_class($scrolled_window, 'half-main-area-style');
  my $icon_grid = Gtk3::Grid->new;                # The grid that will hold all the icons
  $icon_grid->set_row_spacing($spacing);                # Set spacing between rows and columns
  $icon_grid->set_column_spacing($spacing);
  $icon_grid->set_halign('center');
  $scrolled_window->add($icon_grid);              # Add the grid to the scrolled window (This makes the grid scrollable)
  insert_as_first_child($main_area, $scrolled_window);
  return $icon_grid;
}

#----------------------------------------------------------------------------------------------------------------------
sub init_fb {
  $window = Gtk3::Window->new ('toplevel');
  $window->fullscreen;                         #SHOULD BE THIS
  #$window->set_default_size(WIDTH, HEIGHT);
  $window->set_decorated(0);                      # Remove window borders and title bar
  my $css = return_string_from_file("styles.css");
  my $provider = Gtk3::CssProvider->new;
  $provider->load_from_data($css);
  my $display = Gtk3::Gdk::Display::get_default();
  my $screen = Gtk3::Gdk::Display::get_default_screen($display);
  Gtk3::StyleContext::add_provider_for_screen($screen, $provider, Gtk3::STYLE_PROVIDER_PRIORITY_APPLICATION);
  my $context = $window->get_style_context();
  $context->add_provider($provider, Gtk3::STYLE_PROVIDER_PRIORITY_APPLICATION);
  $window->signal_connect('key-press-event' => sub {        # only needed when running on HDMI so can quit back to OS
      my ($widget, $event) = @_;
      if ($event->keyval == Gtk3::Gdk::KEY_Escape) {        # Check if the key pressed was 'Escape'
          Gtk3::main_quit;
      }
  });
  # Now construct the main boxes for header, main area, and footer
  my $vbox = Gtk3::Box->new('vertical', 0);                 # Main vertical box to stack the content
  $window->add($vbox);
  $header_container = Gtk3::Box->new('horizontal', 0);      # Horizontal box for the header icons and text
  add_style_class($header_container, 'header-footer-style');
  $vbox->pack_start($header_container, 0, 0, 0);            # Place at the top of the window
  $main_area = Gtk3::Box->new('vertical', 0);
  $main_area->signal_connect('size-allocate' => sub {
    my ($widget, $allocation) = @_;
    return if ($widget->get_allocated_width == 722) && ($widget->get_allocated_height == 1032);
    print_error("Main area resized to " . $widget->get_allocated_width . "x" . $widget->get_allocated_height);
  });
  $vbox->pack_start($main_area, 1, 0, 0);                   # Place at the top of the window taking rest of space
  $footer_container = Gtk3::Box->new('vertical', 0);        # Vertical box for the footer buttons
  add_style_class($footer_container, 'header-footer-style');
  $vbox->pack_end($footer_container, 0, 0, 0);              # Place at the bottom of the window
  $window->show_all;
}

sub start_graphics {
  Gtk3::main;
}

sub print_footer {
  # --- Drawing Function (Draws the vertical lines between buttons) ---
  sub on_draw_vertical_separator {
    my ($widget, $context) = @_;
    #print_error("Drawing vertical separator");
    my $height = $widget->get_allocated_height;
    $context->set_source_rgb(@yellow); 
    $context->set_line_width(4);
    $context->move_to(2, 0);
    $context->line_to(2, $height);
    $context->stroke;
    return 1;
  }
  my ($names_ref, $callbacks_ref) = @_;
  my @footer_names = @$names_ref;
  my %footer_callbacks = %$callbacks_ref;
  # --- 2. Horizontal Separator Line ---
  my $h_sep_area = construct_horizontal_separator(4);
  $footer_container->pack_start($h_sep_area, 0, 0, 0);                            # Place just above the buttons
  # --- 3. Bottom Button Strip (Horizontal Box wrapped in a DrawingArea) ---
  # We use a GtkOverlay to allow the DrawingArea to draw over the buttons, 
  # but for simplicity, we'll draw within the button container's space using 
  # a GtkBox for layout.
  # Horizontal Box for the buttons. We use expand=1 for all buttons.
  my $hbox_container = Gtk3::Box->new('horizontal', 0);
  # The DrawingArea is inserted *behind* the buttons (using a GtkEventBox 
  # or GtkOverlay is complex), so we'll just let the HBox be the drawing area's 
  # drawing space for simplicity in this structure.
  # We'll connect the drawing function to the HBox's 'draw' signal.
  for my $icon (@footer_names) {
    #print_error("Loading footer icon $icon");
    my $path = "images/" . $icon . "-icon.png";
    if (-e $path) {
      my $image = load_image($path, 117);
      my $button = Gtk3::Button->new;
      $button->add($image);
      $button->signal_connect('clicked' => sub {&{$footer_callbacks{$icon}};});           # &{$footer_callbacks{$icon}}
      # Crucial: expand=1 ensures buttons share the space equally
      $hbox_container->pack_start($button, 0, 0, 0);
    } else {
      print_error("Unable to load icon $path");
    }
    if ($icon ne $footer_names[-1]) {
      my $sep = Gtk3::DrawingArea->new;
      $sep->set_size_request(4, -1);                                 # Width just for the line
      $sep->signal_connect('draw' => \&on_draw_vertical_separator);
      $hbox_container->pack_start($sep, 0, 0, 0);
    }
  }
  $footer_container->pack_start($hbox_container, 0, 0, 0);                     # Place at the bottom of the window
  $window->show_all;
}

sub print_heading {
  my $heading = shift;
  #print_error("Printing heading: $heading");
  delete_all_children($header_container);
  my $image1 = load_image("images/jellyfin.png", 120);
  my $image2 = load_image("images/jellyfin.png", 120);
  $header_container->pack_start($image1, 0, 0, 10) if $image1;
  $header_container->pack_end($image2, 0, 0, 10) if $image2;
  my $text_box = Gtk3::Label->new($heading);
  add_style_class($text_box, 'heading-style');
  $header_container->pack_start($text_box, 1, 1, 0);
  $window->show_all;
}

sub setup_main_area_for_photos {
  delete_all_children($main_area);
  my $vbox1 = Gtk3::Box->new('vertical', 0);
  $main_area->pack_start($vbox1, 0, 0, 0);
  my $vbox2 = Gtk3::Box->new('vertical', 0);
  add_style_class($vbox2, 'playing-area-small-style');
  $main_area->pack_end($vbox2, 0, 0, 0);
  $window->show_all;
  $full_playing_area = 0;
}

sub setup_main_area_for_others {
  delete_all_children($main_area);
  my $vbox1 = Gtk3::Box->new('vertical', 0);
  add_style_class($vbox1, 'half-main-area-style');
  my $sep = construct_horizontal_separator(2);
  my $vbox2 = Gtk3::Box->new('vertical', 0);
  add_style_class($vbox2, 'half-main-area-style');
  $main_area->pack_start($vbox1, 0, 0, 0);
  $main_area->pack_start($sep, 0, 0, 0);
  $main_area->pack_end($vbox2, 0, 0, 0);
  $full_playing_area = 1;
}

sub clear_play_area {
  my @children = $main_area->get_children;
  my $playing_box = $children[-1];                      # last child is playing area
  delete_all_children($playing_box);
  $window->show_all;
  return $playing_box;
}

#----------------------------------------------------------------------------------------------------------------------
sub find_font_size_to_fit {
    my ($label, $max_width) = @_;
    my $text = $label->get_text;
    
    # 1. Create a Pango Layout to measure the text
    my $layout = $label->create_pango_layout($text);
    my $best_size = 8;                # Start with a minimum size (e.g., 8 points)
    
    # 2. Iterate from a large size down to the minimum
    # (e.g., 38pt down to 8pt) to find the largest fitting size.
    for my $size (reverse(8..38)) { 
        # Set the font description for measurement (e.g., "Sans 48pt")
        my $font_desc = Pango::FontDescription->from_string("Nimbus Sans ${size}pt");
        $layout->set_font_description($font_desc);
        my ($width_pango, $height_pango) = $layout->get_size();           # Get the measured size in Pango units
        my $width_pixels = $width_pango / Pango::SCALE;                   # Convert Pango units (1024 units per pixel) to actual pixels
        # Check if the measured width fits within the container's max width
        if ($width_pixels <= $max_width) {
            $best_size = $size;
            last; # Found the largest size that fits
        }
    }
    
    # 3. Apply the final size using Pango Markup
    # We use 'font_desc' in markup to apply the specific point size
    my $final_markup = "<span font_desc=\"Nimbus Sans ${best_size}pt\">" . $text . "</span>";
    $label->set_markup($final_markup);
}

# args: 2 lines of text of what is playing, width of gap to print into
sub display_playing_text {
  my ($box, $line1, $line2, $width) = @_;
  print_error("Displaying playing text: $line1 / $line2");
  my $vbox = Gtk3::Box->new('vertical', 0);
  my $tbox1 = Gtk3::Label->new($line1);
  add_style_class($tbox1, 'playing-text-style');
  $tbox1->set_halign('center');
  $vbox->pack_start($tbox1, 0, 0, 0);
  my $tbox2 = Gtk3::Label->new($line2);
  add_style_class($tbox2, 'playing-text-style');
  $tbox2->set_halign('center');
  $vbox->pack_start($tbox2, 0, 0, 0);
  add_style_class($vbox, 'playing-text-box-style');
  $box->pack_start($vbox, 1, 1, 0);
  #need to find best font size to fit in width
}

sub display_playing_nothing {
  my @children = $main_area->get_children;
  my $playing_box = $children[-1];                      # last child is playing area
  delete_all_children($playing_box);
  $window->show_all;
}

# Args: playing area box, ref to array of refs to hash with icon file names and callbacks
sub print_transport_icons {
  my ($playing_box, $buttons_ref) = @_;
  my @buttons = @$buttons_ref;
  my $hbox = Gtk3::Box->new('horizontal', 0);
  add_style_class($hbox, 'transport-icons-box-style');
  foreach my $button_ref (@buttons) {
    my $fname = $button_ref->{"icon-filename"};
    my $callback = $button_ref->{"callback"};
    if (-e "images/$fname.png") {
      my $image = load_image("images/$fname.png", 60);
      my $button = Gtk3::Button->new;
      $button->add($image);
      $button->signal_connect('clicked' => sub {&{$callback}();});
      $button->set_halign('end');
      add_style_class($button, 'transport-box-style');
      $hbox->pack_start($button, 0, 0, 0);
    } else {
      print_error("Unable to load transport icon images/$fname.png");
    }
  }
  $hbox->set_halign('end');
  $playing_box->pack_end($hbox, 0, 0, 0);
}

#----------------------------------------------------------------------------------------------------------------------
sub rotate_cw {
  my ($pixbuf, $angle) = @_;
  return $pixbuf->rotate_simple($angle);
}

sub mirror {
  my ($pixbuf, $dir) = @_;
  return $pixbuf->flip($dir);
}

sub get_exif_orientation {
    my ($filename) = @_;
    
    # Read the metadata
    my $info = ImageInfo($filename);

    # The 'Orientation' tag contains the numerical code (1-8)
    my $orientation = $info->{Orientation} || 1; 

    # If the value is a descriptive string ("Horizontal (normal)"), 
    # we convert it to the numerical code (1)
    if ($orientation =~ /normal/i) {
        return 1;
    }
    
    # Otherwise, return the numerical value (e.g., 6 for 90 degrees clockwise)
    return $orientation;
}

sub prepare_photo {
  my $filename = shift;
  my $pixbuf;
  my $orientation;
  if (-e $filename) {
    try {
      #print STDERR "Reading $filename\n";
      $orientation = get_exif_orientation($filename);
      #print STDERR "Orientation = $orientation\n";
      $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($filename);
    } otherwise {
      print_error("Error loading image file $filename: " . shift);
      return undef;
    };
    unless ($pixbuf) {
      print_error("Could not load image file: $filename");
      return (undef);
    }
    my $ref = $orientations{$orientation};
    my $new_pixbuf;
    if (defined $ref) {
      $new_pixbuf = &$ref($pixbuf);
    } else {
      $new_pixbuf = $pixbuf;
    }
    my $width = $new_pixbuf->get_width;
    my $height = $new_pixbuf->get_height;
    my $scale_factor = min(WIDTH / $width, 851 / $height);              # also in photo-image-style
    my $final_pixbuf = $new_pixbuf->scale_simple(
      $width * $scale_factor, 
      $height * $scale_factor, 
      'bilinear' # High quality scaling
    );
    return ($final_pixbuf);
  } else {
    return (undef);
  }
}

sub extract_file_details {
    my ($file_path) = @_;
    
    # Extract the filename and the directory path
    my $filename = fileparse($file_path);
    my $dir = dirname($file_path);
    
    # Remove the extension from the filename
    $filename =~ s/\.[^.]+$//;
    
    # Get the lowest level folder name
    my @dirs = split(/[\/\\]/, $dir);
    my $lowest_level_folder = $dirs[-1];
    
    return ($filename, $lowest_level_folder);
}

sub display_photo {
  my ($fname) = @_;
  delete_first_child($main_area);
  if (-e $fname) {
    my $pixbuf = prepare_photo($fname);
    if (defined $pixbuf) {
      #print_error("Displaying photo: $fname");
      my $vbox = Gtk3::Box->new('vertical', 0);
      insert_as_first_child($main_area, $vbox);
      my ($file, $folder) = extract_file_details($fname);
      my $text_box = Gtk3::Label->new("Folder: $folder,  File: $file");
      add_style_class($text_box, 'photo-path-style');
      $vbox->pack_start($text_box, 0, 0, 0);
      my $pbox = Gtk3::Image->new_from_pixbuf($pixbuf);
      add_style_class($pbox, 'photo-image-style');
      $vbox->pack_end($pbox, 0, 0, 0);
    } else {
      display_string("Failed to prepare photo:\n$fname");
    }
  } else {
    display_string("File not found at\n$fname");
  }
  $window->show_all;
}

#----------------------------------------------------------------------------------------------------------------------
# Args: ref to radio stations, callback
sub display_radio_top {
  my ($ref_lists, $callback) = @_;
  my %radio_list = %$ref_lists;
  delete_first_child($main_area);
  my $icon_grid = construct_scrolled_grid_box(30);
  my $i = 0;
  my $j = 0;
  foreach my $label (sort keys %radio_list) {
    my $icon_button = create_scroll_item_with_title('title1' => $ref_lists->{$label}->{"name"}, 'icon_path' => "images/radio-icons/" . $ref_lists->{$label}->{"thumbnail"}, 'callback' => $callback, 'callback_arg' => $label);
    $icon_grid->attach($icon_button, $i, $j, 1, 1);
    $i++;
    if ($i == 3) {
      $i = 0;
      $j++;
    }
  }
  $window->show_all;
}

# Args: radio label, ref to stations, ref to transport buttons
sub display_playing_radio {
  my ($label, $radio_stations_ref, $transport_buttons_ref) = @_;
  print_error("Playing radio $label");
  my $playing_box = clear_play_area();
  if ($full_playing_area) {
    my $fname = $radio_stations_ref->{$label}->{"icon"};
    $fname = "images/radio-icons/$fname";
    $fname = "images/missing-image-icon.jpg" unless -e $fname;
    if (-e $fname) {
      my $image = load_image($fname, WIDTH, 370);
      $image->set_halign('center');
      add_style_class($image, 'radio-playing-image-style');
      $playing_box->pack_start($image, 0, 0, 0);
      my $hbox = Gtk3::Box->new('horizontal', 0);
      print_transport_icons($hbox, $transport_buttons_ref);
      $playing_box->pack_end($hbox, 0, 0, 0);
    }
  } else {
    my $hbox = Gtk3::Box->new('horizontal', 0);
    $playing_box->pack_start($hbox, 0, 0, 0);
    display_playing_text($hbox, "Playing: ", $radio_stations_ref->{$label}->{"name"}, 610);
    print_transport_icons($hbox, $transport_buttons_ref);
  }
  $window->show_all;
}

#----------------------------------------------------------------------------------------------------------------------
# $title is either album title or playlist title or radio name
# $playlist_flag is 1 for playlist/radio, 0 for album
sub display_play_screen_core {
  my ($title, $thumb_path, $artist_name, $track_title, $track_number, $tracks_total, $playlist_flag) = @_;
  #print_error("title: $title, track title: $track_title, artist name: $artist_name");
  if ($full_playing_area) {
    my $hbox1 = Gtk3::Box->new('horizontal', 0);
    my $icon = create_square_image($thumb_path, "images/missing-music-group-icon.png",300);
    add_style_class($icon, 'outlined-box');
    $hbox1->pack_start($icon, 0, 0, 0);
    my $str = remove_trailing_squares(($playlist_flag) ? $track_title : $title);
    my $title_label = Gtk3::Label->new($str);
    $title_label->set_line_wrap(1);
    $title_label->set_valign('end');
    $title_label->set_halign('center');
    $title_label->set_justify('center');
    add_style_class($title_label, 'playing-album-title-text-style');
    my $artist_label = Gtk3::Label->new($artist_name);
    $artist_label->set_line_wrap(1);
    $artist_label->set_halign('center');
    $artist_label->set_valign('start');
    $artist_label->set_justify('center');
    add_style_class($artist_label, 'playing-artist-name-text-style')  ;
    my $vbox = Gtk3::Box->new('vertical', 0);
    add_style_class($vbox, 'playing-album-artist-box-style');
    $vbox->pack_start($title_label, 1, 1, 0);
    $vbox->pack_start($artist_label, 1, 1, 0);
    $hbox1->pack_end($vbox, 0, 0, 0);
    add_style_class($hbox1, 'playing-icon-details-style');
    return $hbox1;
  } else {
    return;
  }
}

#----------------------------------------------------------------------------------------------------------------------
# Args: playlist id, ref to playlists, index to track being played
sub display_playing_playlist {
  my ($id, $playlists_ref, $track_no, $transport_ref) = @_;
  my %playlists = %$playlists_ref;
  my $tracks_ref = $playlists{$id}->{"tracks"};
  my $title = $playlists{$id}->{"name"};
  my $track_id = $tracks_ref->[$track_no]->{"id"};
  my $album_id = $tracks_ref->[$track_no]->{"album_id"};
  print_error("Playing from playlist $title, track number $track_no");
  my $tracks_thumb_path = "thumbnail_cache/Items/$track_id/Images/Primary.jpg";
  $tracks_thumb_path = "thumbnail_cache/Items/$album_id/Images/Primary.jpg" if (! -e $tracks_thumb_path);      # use album art if no track art
  #print_error("Track thumb path $tracks_thumb_path");
  my $artist_name = $tracks_ref->[$track_no]->{"artist_name"};
  my $track_title = $tracks_ref->[$track_no]->{"track_title"};
  my $playing_box = clear_play_area();
  my $info_box = display_play_screen_core($title, $tracks_thumb_path, $artist_name, $track_title, 0, 0, 1);
  $playing_box->pack_start($info_box, 0, 0, 0) if $info_box;
  my $hbox = Gtk3::Box->new('horizontal', 0);
  display_playing_text($hbox, "Playing:", "$title playlist", 400);
  print_transport_icons($hbox, $transport_ref);
  $playing_box->pack_end($hbox, 0, 0, 0);
  $window->show_all();
}

# Args: ref to playlists hash, callback
sub display_playlists_top {
  my ($ref_playlists, $callback) = @_;
  print_error("Displaying playlists top");
  sub sort_playlists_by_name { return $$ref_playlists{$a}->{"name"} cmp $$ref_playlists{$b}->{"name"}; }
  if (defined $ref_playlists) {
    delete_first_child($main_area);
    my $icon_grid = construct_scrolled_grid_box(30);
    my $i = 0;
    my $j = 0;
    #print_error("Number of playlists: " . scalar(keys %$ref_playlists));
    foreach my $id (sort sort_playlists_by_name keys %$ref_playlists) {             # display playlists alphabetically
      #print_error("Playlist id: $id, name: " . $$ref_playlists{$id}->{"name"});
      my $icon_button = create_scroll_item_with_title('title1' => $$ref_playlists{$id}->{"name"}, 'icon_path' => "thumbnail_cache/Items/" . $id . "/Images/Primary.jpg", 'callback' => $callback, 'callback_arg' => $id);
      $icon_grid->attach($icon_button, $i, $j, 1, 1);
      $i++;
      if ($i == 3) {
        $i = 0;
        $j++;
      }
    }
  } else {
    display_string("Please wait ...");
  }
  $window->show_all;
}

#----------------------------------------------------------------------------------------------------------------------
# Args: ref to hash of letters, callback function
sub display_letter_grid {
  my ($ref, $callback) = @_;
  delete_first_child($main_area);
  my $icon_grid = construct_scrolled_grid_box(30);
  my $i = 0;
  my $j = 0;
  foreach my $label (sort keys %$ref) {
    my $letter_box = Gtk3::Label->new($label);
    add_style_class($letter_box, 'letter-box-text-style');
    $letter_box->set_halign('center');
    $letter_box->set_valign('center');
    my $letter_button = Gtk3::Button->new;
    $letter_button->add($letter_box);
    $letter_button->signal_connect('clicked' => sub {
      &$callback($label);
    });
    $icon_grid->attach($letter_button, $i, $j, 1, 1);
    $i++;
    if ($i == 6) {
      $i = 0;
      $j++;
    }
  }
  $window->show_all;
}

# display grid of first letters of albums
# Args: ref to albums by letter hash, callback
sub display_albums_top {
  display_letter_grid($_[0], $_[1]);
}

# display grid of album icons with title/artist below
# Args: ref to array of ref to hash 4 (sorted by album name), callback
sub display_albums_with_letter {
  my ($ref, $callback) = @_;
  my @albums = @$ref;
  #print_error("Displaying " . scalar @albums . " albums for selected letter");
  delete_first_child($main_area);
  my $icon_grid = construct_scrolled_grid_box(30);
  my $y = 0;
  my $x = 0;
  for my $i (0 .. $#albums) {
    my $uid = construct_album_uid($albums[$i]);
    my $icon_button = create_scroll_item_with_title(title1 => $albums[$i]->{"title"}, 
                                                    title2 => $albums[$i]->{"artist"}->{"name"},
                                                    icon_path => "thumbnail_cache/Items/" . $albums[$i]->{"id"} . "/Images/Primary.jpg", 
                                                    callback => $callback, 
                                                    callback_arg => $uid);
    $icon_grid->attach($icon_button, $x, $y, 1, 1);
    $x++;
    if ($x == 3) {
      $x = 0;
      $y++;
    }
  }
  $window->show_all();
}

sub numeric_sort {
  return $a <=> $b;
}

# Args: ref to album, index to track being played
sub display_playing_album {
  my ($album_ref, $track, $transport_ref, $paused) = @_;
  my $playing_box = clear_play_area();
  my $album_title = $$album_ref{"title"};
  my $album_thumb_url = $$album_ref{"id"};
  my $artist_ref = $$album_ref{"artist"};
  my $artist_name = $$artist_ref{"name"};
  my $tracks_ref = $$album_ref{"tracks"};
  my $track_title = $$tracks_ref{$track}->{"title"};
  my $album_thumb_path = "thumbnail_cache/Items/$album_thumb_url/Images/Primary.jpg";
  my @track_keys = sort numeric_sort keys %$tracks_ref;
  my $track_no = find_element_in_array($track, \@track_keys) + 1;
  my $info_box = display_play_screen_core($album_title, $album_thumb_path, $artist_name, $track_title, 0, 0, 1);
  $playing_box->pack_start($info_box, 0, 0, 0) if $info_box;
  my $hbox = Gtk3::Box->new('horizontal', 0);
  display_playing_text($hbox, "Track $track_no of " . scalar @track_keys, $track_title, 400);
  print_transport_icons($hbox, $transport_ref);
  $playing_box->pack_end($hbox, 0, 0, 0);
  $window->show_all();
}

#----------------------------------------------------------------------------------------------------------------------
# Display a grid of letters for the artists
# Args: ref to artists by letter hash, callback
sub display_artists_top {
  display_letter_grid($_[0], $_[1]);
}

# Args: ref to hash 1 (artists name), callback
# Grid of album thumbnails with artist below
sub display_artists_with_letter {
  my ($aref, $callback) = @_;
  my @artists = sort keys %$aref;
  delete_first_child($main_area);
  my $icon_grid = construct_scrolled_grid_box(30);
  my $y = 0;
  my $x = 0;
  foreach my $i (@artists) {
    my $icon_button = create_scroll_item_with_title(title1 => $aref->{$i}->{"name"}, 
                                                    icon_path => "thumbnail_cache/Items/" . $aref->{$i}->{"id"} . "/Images/Primary.jpg", 
                                                    callback => $callback, 
                                                    callback_arg =>$aref->{$i}->{"name"});
    $icon_grid->attach($icon_button, $x, $y, 1, 1);
    $x++;
    if ($x == 3) {
      $x = 0;
      $y++;
    }
  }
  $window->show_all();
}

# display grid of album icons
# Args: ref to hash 2, callback
# Grid of album thumbnails with title/artist below
sub display_artist_albums_with_letter {
  my ($aref, $callback) = @_;
  my @albums;
  foreach my $key (keys %{$aref->{"albums"}}) {
    push(@albums, {"key" => $key, "ref" => $aref->{"albums"}->{$key}})
  }
  @albums = sort album_key_sort @albums;
  #print_error("number of albums found: " . scalar @albums);
  delete_first_child($main_area);
  my $icon_grid = construct_scrolled_grid_box(30);
  my $y = 0;
  my $x = 0;
  for my $i (0 .. $#albums) {
    my $ref = $albums[$i]->{'ref'};
    my $uid = construct_album_uid($ref);
    #print_error("Displaying album: " . $ref->{"title"} . " by " . $ref->{"artist"}->{"name"});
    my $icon_button = create_scroll_item_with_title(title1 => $ref->{"title"}, 
                                                    title2 => $ref->{"artist"}->{"name"},
                                                    icon_path => "thumbnail_cache/Items/" . $ref->{"id"} . "/Images/Primary.jpg", 
                                                    callback => $callback, 
                                                    callback_arg => $uid);
    $icon_grid->attach($icon_button, $x, $y, 1, 1);
    $x++;
    if ($x == 3) {
      $x = 0;
      $y++;
    }
  }
  $window->show_all();
}

sub album_key_sort {
  return remove_leading_article($a->{"ref"}->{"title"}) cmp remove_leading_article($b->{"ref"}->{"title"});
}

#----------------------------------------------------------------------------------------------------------------------
sub changed {
  my $ref = shift;
  my @vals = @_;
  my $i = 0;
  my $changed = 0;
  foreach my $val (@vals) {
    if (defined $val) {                     # if we have a new value
      if (! defined $ref->[$i]) {           # if no old value
        $changed = 1;
        $ref->[$i] = $val;
      } else {                              # if we have an old value
        if ($ref->[$i] ne $val) {           # if new different to old (using string comp)
          $changed = 1;
          $ref->[$i] = $val;
        }
      }
    }
    $i++;
  }
  return $changed;
}

sub draw_gauge {
  my ($widget, $cr, $data) = @_;
  # Get the width and height of the drawing area
  my $width  = $widget->get_allocated_width;
  my $height = $widget->get_allocated_height;
  
  # --- Define Gauge Parameters ---
  my $center_x  = $width / 2;
  my $center_y  = $height;                # Place the center at the bottom of the widget
  my $line_width   = $width / 4;          # Thickness of the arc ring
  my $radius_outer = $width / 2;          # Outer radius of the arc
  my $radius_inner = $radius_outer - $line_width;
  
  # Radians for the semi-circle (0 to pi)
  # Start: 180 degrees (left), End: 0 degrees (right)
  my $START_ANGLE = M_PI;
  my $END_ANGLE   = 0;
  
  # Calculate the angle for the value
  my $normalized_value = $data / 100;
  # The value arc goes from 180 degrees (START_ANGLE) down to the calculated angle
  my $value_angle = $START_ANGLE + ($normalized_value * M_PI);
  
  # --- Cairo Setup for Drawing ---
  $cr->set_line_cap('butt');
  $cr->set_line_width($line_width);

  # 1. Draw the Background Arc (Full Semicircle)
  $cr->set_source_rgb(defined $data ? @dark_green : @gray);
  $cr->arc($center_x, $center_y, $radius_outer - ($line_width/2), 
            $START_ANGLE, $END_ANGLE);
  $cr->stroke();

  # 2. Draw the Value Arc (Green Filled Portion)
  $cr->set_source_rgb(defined $data ? @pale_yellow : @gray);
  $cr->arc($center_x, $center_y, $radius_outer - ($line_width/2), 
            $START_ANGLE, $value_angle);
  $cr->stroke();

  if ($height > 60) {
    my $text = sprintf("%.0f%%", $data);
    $cr->select_font_face("Sans", 'normal', 'normal');
    $cr->set_font_size(25);                           # Choose a readable size
    my $extents = $cr->text_extents($text);           # This returns: x_bearing, y_bearing, width, height, x_advance, y_advance
    my $t_width  = $extents->{width};
    my $t_height = $extents->{height};
    my $tx = $center_x - ($t_width / 2) - $extents->{x_bearing};
    my $ty = $center_y - ($radius_inner / 5);                     # Adjust the '3' to move it up or down inside the arc
    $cr->set_source_rgb(@pale_yellow);
    $cr->move_to($tx + 2, $ty + 2);
    $cr->show_text($text);
  }
}

sub draw_slice_widget {
  my ($data, $size, $title) = @_;
  #print_error("Drawing slice widget of size $size with title $title and data: $data");
  my $vbox = Gtk3::Box->new('vertical', 0);
  my $drawing_area = Gtk3::DrawingArea->new();
  $drawing_area->set_halign('center');
  $vbox->pack_start($drawing_area, 0, 0, 0);
  $drawing_area->signal_connect('draw' => sub {      # Connect the drawing function to the 'draw' signal
    my ($widget, $context) = @_;
    draw_gauge($widget, $context, $data);
  });
  if ($size eq "small") {
    $drawing_area->set_size_request(80, 40);
  } elsif ($size eq "large") {
    $drawing_area->set_size_request(200, 100);
  }
  my $title_box = Gtk3::Label->new($title);
  add_style_class($title_box, 'slice-widget-title-style');
  $title_box->set_halign('center');
  $vbox->pack_start($title_box, 0, 0, 0);
  return $vbox;
}

sub ha_create_params_box {
  my @data = @_;
  my $params_box = Gtk3::Grid->new();
  add_style_class($params_box, 'ha-params-top-box-style');
  $params_box->set_valign('center');
  foreach my $i (0 .. 2) {
    my $label = shift @data;
    my $value = shift @data;
    my $label_box = Gtk3::Label->new("$label:");
    add_style_class($label_box, 'ha-param-label-style');
    $label_box->set_halign('end');
    my $value_box = Gtk3::Label->new("$value");
    add_style_class($value_box, 'ha-param-value-style');
    $value_box->set_halign('start');
    $value_box->set_xalign(0.0);
    $value_box->set_size_request(130, -1);
    $params_box->attach($label_box, 0, $i, 1, 1);
    $params_box->attach($value_box, 1, $i, 1, 1);}
  return $params_box;
}

# solar parameters
sub display_solar {
  my ($data_ref, $force_display) = @_;
  state @old_values;
  my $solar_box;
  if (($force_display) || (!defined $solar_box)) {
    $solar_box = Gtk3::Box->new('horizontal', 0);
    add_style_class($solar_box, 'solar-top-box-style');
  }
  my $vale = $data_ref->{return_solar_exported()};
  my $valbp = $data_ref->{return_solar_bat_power()};
  my $valsp = $data_ref->{return_solar_power()};
  my $valbatt = $data_ref->{return_solar_battery()};
  #print_error("Solar values: exported=$vale, bat power=$valbp, solar power=$valsp");
  changed(\@old_values, $vale, $valbp, $valsp, $valbatt);
  $vale = $old_values[0];
  $valbp = $old_values[1];
  $valsp = $old_values[2];
  $valbatt = $old_values[3];
  delete_all_children($solar_box);
  my $solar_slice_box = Gtk3::Box->new('vertical', 0);
  add_style_class($solar_slice_box, 'solar-slice-box-style');
  my $title_box = Gtk3::Label->new("Solar");
  add_style_class($title_box, 'ha-title-text-style');
  $title_box->set_halign('start');
  $solar_slice_box->pack_start($title_box, 0, 0, 0);
  my $battery_slice = draw_slice_widget($valbatt, "large", "Battery");
  add_style_class($battery_slice, 'solar-slice-widget-style');
  $solar_slice_box->pack_start($battery_slice, 0, 0, 0);
  $solar_box->pack_start($solar_slice_box, 0, 0, 0);
  my $gen_str = defined $valsp ? format_number($valsp) . "W" : "N/A";
  my $imp_exp_str;
  my $ie_val_str;
  if (defined $vale) {
    if ($vale < 0) {
      $imp_exp_str = "Importing";
      $ie_val_str = format_number(-$vale) . "W";
    } else {
      $imp_exp_str = "Exporting";
      $ie_val_str = format_number($vale) . "W";
    }
  } else {
    $imp_exp_str = "Importing/Exporting";
    $ie_val_str = "N/A";
  }
  my $cons_str;
  if (defined $valsp && defined $valbp && defined $vale) {
    my $valc = $valsp - $valbp - $vale;
    $cons_str = format_number($valc) . "W";
  } else {
    $cons_str = "N/A";
  }
  my $params_box = ha_create_params_box("Generating", $gen_str, $imp_exp_str, $ie_val_str, "Consuming", $cons_str);
  $solar_box->pack_end($params_box, 0, 0, 0);
  return $solar_box;
}

# car parameters
sub display_car {
  my ($data_ref, $force_display) = @_;
  state @old_values;
  my $car_box;
  if (($force_display) || (!defined $car_box)) {
    $car_box = Gtk3::Box->new('horizontal', 0);
    add_style_class($car_box, 'car-top-box-style');
  }
  my $valr = $data_ref->{return_car_range()};
  my $valct = $data_ref->{return_car_time()};
  my $valpi = $data_ref->{return_car_connected()};
  my $valbatt = $data_ref->{return_car_battery()};
  #print_error("range=$valr, time=$valct, plug=$valpi");
  changed(\@old_values, $valr, $valct, $valpi, $valbatt);
  $valr = $old_values[0];
  $valct = $old_values[1];
  $valpi = $old_values[2];
  $valbatt = $old_values[3];
  $valct = (defined $valct) ? $valct : "--";
  delete_all_children($car_box);
  my $car_slice_box = Gtk3::Box->new('vertical', 0);
  add_style_class($car_slice_box, 'car-slice-box-style');
  my $title_box = Gtk3::Label->new("Car");
  add_style_class($title_box, 'ha-title-text-style');
  $title_box->set_halign('start');
  $car_slice_box->pack_start($title_box, 0, 0, 0);
  my $battery_slice = draw_slice_widget($valbatt, "large", "Battery");
  add_style_class($battery_slice, 'car-slice-widget-style');
  $car_slice_box->pack_start($battery_slice, 0, 0, 0);
  $car_box->pack_start($car_slice_box, 0, 0, 0);
  $valr = int($valr * 5 / 8) . " miles" if defined $valr;
  $valct = sprintf("%.1f hours", $valct / 60) if defined $valct;
  $valpi = (($valpi eq "off") ? "No" : "Yes") if defined $valpi;
  my $params_box = ha_create_params_box("Range", $valr, "Charge time", $valct, "Plugged in", $valpi);
  $car_box->pack_end($params_box, 0, 0, 0);
  return $car_box;
}

# printer ink statuses
sub display_printer {
  my ($data_ref, $force_display) = @_;
  my $printer_box;
  state @old_values;
  if (($force_display) || (!defined $printer_box)) {
    $printer_box = Gtk3::Box->new('horizontal', 0);
    add_style_class($printer_box, 'printer-top-box-style');
  }
  my $valm = $data_ref->{return_ink_magenta()};
  my $valc = $data_ref->{return_ink_cyan()};
  my $valy = $data_ref->{return_ink_yellow()};
  my $valb = $data_ref->{return_ink_black()};
  changed(\@old_values, $valm, $valc, $valy, $valb);
  my $valm = $old_values[0];
  my $valc = $old_values[1];
  my $valy = $old_values[2];
  my $valb = $old_values[3];
  delete_all_children($printer_box);
  my $title_box = Gtk3::Label->new("Printer");
  add_style_class($title_box, 'ha-title-text-style');
  $title_box->set_valign('start');
  $printer_box->pack_start($title_box, 0, 0, 0);
  foreach my $color (["Magenta", $valm], ["Cyan", $valc], ["Yellow", $valy], ["Black", $valb]) {
    my $slice = draw_slice_widget($color->[1], "small", $color->[0]);
    $slice->set_valign('end');
    add_style_class($slice, 'printer-slice-widget-style');
    $printer_box->pack_start($slice, 0, 0, 0);
  }
  return $printer_box;
}

sub display_home_assistant {
  my ($data_ref, $force_display) = @_;
  my $top_box;
  print_error("display home assistant");
  #print_hash_params($data_ref);
  my $solar_box = display_solar($data_ref, $force_display);
  my $car_box = display_car($data_ref, $force_display);
  my $printer_box = display_printer($data_ref, $force_display);
  delete_first_child($main_area);                       # clear main area and create new box
  $top_box = Gtk3::Box->new('vertical', 0);
  add_style_class($top_box, 'half-main-area-style');
  insert_as_first_child($main_area, $top_box);
  $top_box->pack_start($solar_box, 0, 0, 0);
  my $sep1 = construct_horizontal_separator(2);
  $top_box->pack_start($sep1, 0, 0, 0);
  $top_box->pack_start($car_box, 0, 0, 0);
  my $sep2 = construct_horizontal_separator(2);
  $top_box->pack_start($sep2, 0, 0, 0);
  $top_box->pack_start($printer_box, 0, 0, 0);
  $window->show_all;
}


1;
