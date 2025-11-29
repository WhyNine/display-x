package UserDetails;

our @EXPORT = qw ( $path_to_pictures $health_check_url $radio_stations_ref $jellyfin_url $jellyfin_apikey $mqtt_ref $display_times_ref);
use base qw(Exporter);
use strict;

use lib "/home/pi/doorbell";
use Utils;

use YAMC;

my $yamc = new YAMC();
$yamc->fileName('/home/pi/display/UserDetails.yml');

my $hash = $yamc->Read();
my %settings = %$hash;

our $path_to_pictures = $settings{"picture-path"};
print_error("Path to pictures does not exist: $path_to_pictures") unless -e $path_to_pictures;

our $jellyfin_url = $settings{"jellyfin-url"};
print_error("No JellyFin URL provided") unless $jellyfin_url;

our $jellyfin_apikey = $settings{"jellyfin-apikey"};
print_error("No JellyFin API key provided") unless $jellyfin_apikey;

our $health_check_url = $settings{"health-check-url"};

our $radio_stations_ref = $settings{"stations"};
print_error("No radio stations defined") unless $radio_stations_ref;

our $mqtt_ref = $settings{"mqtt"};
print_error("No MQTT server defined") unless $mqtt_ref;

our $display_times_ref = $settings{"display"};
print_error("No display times defined") unless $display_times_ref;

1;
