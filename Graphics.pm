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
use List::Util qw(min);
use File::Basename;
use Image::ExifTool qw(:Public);
#use Image::Resize;

my $window;
use constant WIDTH => 720;
use constant HEIGHT => 1280;
my $header_container;                         # Horizontal box for the header icons and text
my $main_area;                                # Main area for application content (vbox)
my $footer_container;                         # Vertical box for the footer buttons
my $full_playing_area = 0;                    # 1 = full playing area, 0 = minimal playing area (slideshow)

my @yellow = (1, 1, 0);

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
  my ($file_path, $size) = @_;
  my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file_at_scale($file_path, $size, $size, 1);
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
  add_style_class($text_box, 'information-style');
  insert_as_first_child($main_area, $text_box);
  $window->show_all;
}

sub add_style_class {
  my ($widget, $class_name) = @_;
  my $context = $widget->get_style_context;
  $context->add_class($class_name);
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
      my $image = Gtk3::Image->new_from_file($path);
      $image->set_pixel_size(116);                                  # Scales the image to 120 pixels, preserving aspect ratio.
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
  $main_area->pack_start($vbox2, 0, 0, 0);
  $full_playing_area = 1;
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
  if (-e $filename) {
    #print STDERR "Reading $filename\n";
    my $orientation = get_exif_orientation($filename);
    #print STDERR "Orientation = $orientation\n";
    my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file($filename);
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
    my $scale_factor = min(WIDTH / $width, 745 / $height);              # also in photo-image-style
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
      print_error("Displaying photo: $fname");
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
# Create small icon with title below
# Args: title, url of icon, callback address, arg to pass to callback
sub create_radio_item {
  my ($title, $fname, $callback, $arg) = @_;
  print_error("display radio item: $title, $fname");
  my $icon = create_square_image("images/radio-icons/$fname", "images/missing-image-icon.jpg", 200);
  my $icon_title = Gtk3::Label->new($title);
  my $icon_vbox = Gtk3::Box->new('vertical', 0);
  add_style_class($icon_title, 'radio-item-title-style');
  $icon_vbox->pack_start($icon, 0, 0, 0);
  $icon_vbox->pack_start($icon_title, 0, 0, 0);
  my $icon_button = Gtk3::Button->new;
  $icon_button->add($icon_vbox);
  $icon_button->signal_connect('clicked' => sub {
    &$callback($arg);
  });
  return $icon_button;
}

# Args: ref to radio stations, callback
sub display_radio_top {
  my ($ref_lists, $callback) = @_;
  my %radio_list = %$ref_lists;
  delete_first_child($main_area);
  my $scrolled_window = Gtk3::ScrolledWindow->new(undef, undef);    # Main container for the scrolling area
  add_style_class($scrolled_window, 'half-main-area-style');
  my $icon_grid = Gtk3::Grid->new;                # The grid that will hold all the icons
  $icon_grid->set_row_spacing(30);                # Set spacing between rows and columns
  $icon_grid->set_column_spacing(30);
  $scrolled_window->add($icon_grid);              # Add the grid to the scrolled window (This makes the grid scrollable)
  my $i = 0;
  my $j = 0;
  foreach my $label (sort keys %radio_list) {
    my $icon_button = create_radio_item($ref_lists->{$label}->{"name"}, $ref_lists->{$label}->{"thumbnail"}, $callback, $label);
    $icon_grid->attach($icon_button, $i, $j, 1, 1);
    $i++;
    if ($i == 3) {
      $i = 0;
      $j++;
    }
  }
  insert_as_first_child($main_area, $scrolled_window);
  $window->show_all;
}

# Args: radio label, ref to stations, full(1)/minimal
sub display_playing_radio {
  my ($label, $radio_stations_ref, $transport_areas_ref) = @_;
  print_error("Playing radio $label");
  #clear_play_area($full);
  #print_transport_icons({"stop" => 1}, $transport_areas_ref);
  #$fb->clip_reset();
  my $full = 0; #TEMP
  if ($full) {
    my $fname = $radio_stations_ref->{$label}->{"icon"};
    $fname = "images/radio-icons/$fname";
    if (-e $fname) {
  #    my $image = $fb->load_image({
  #      'y'          => 680,
  #      'x'          => 0,
  #      'width'      => WIDTH,
  #      'height'     => 348,
  #      'file'       => $fname,
  #      'convertalpha' => FALSE, 
  #      'preserve_transparency' => TRUE
  #    });
  #    $image->{'x'} = (WIDTH - $image->{'width'}) / 2;
  #    $image->{'y'} = 680 + (348 - $image->{'height'}) / 2;
  #    $fb->blit_write($image);
    }
  } else {
  #  display_playing_text("Playing: ", $radio_stations_ref->{$label}->{"name"}, 610);
  }
}

#----------------------------------------------------------------------------------------------------------------------

=for comment
# --- 2. Create Content Box 1 ---
my $box1 = Gtk3::Box->new('vertical', 10);
$box1->set_border_width(10);
$box1->add(Gtk3::Label->new("--- Box 1: Data Entry View ---"));
$box1->add(Gtk3::Button->new('Button A: Enter Data'));

# --- 3. Create Content Box 2 ---
my $box2 = Gtk3::Box->new('vertical', 10);
$box2->set_border_width(10);
$box2->add(Gtk3::Label->new("--- Box 2: Display View ---"));
$box2->add(Gtk3::Button->new('Button B: View Log'));

# --- 4. Add Boxes to the Stack ---
# The second parameter is the name/ID, and the third is the user-friendly title.
$stack->add_named($box1, 'page_one', 'Page One');
$stack->add_named($box2, 'page_two', 'Page Two');

$stack->set_visible_child_name('page_two');
=cut


1;
