package MQTT;

our @EXPORT = qw ( check_mqtt_subscribed get_mqtt_values return_car_battery return_car_connected return_car_time return_solar_battery return_solar_power 
  return_solar_exported return_solar_bat_power return_car_range return_ink_black return_ink_cyan return_ink_magenta return_ink_yellow);
use base qw(Exporter);

use strict;

use lib "/home/pi/display";

use Utils;
use UserDetails qw ( $mqtt_ref );

use AnyEvent::MQTT;

my @topics_subs = (\&return_car_battery, \&return_car_connected, \&return_car_range, \&return_car_time, \&return_solar_bat_power, \&return_solar_battery, \&return_solar_exported, 
  \&return_solar_power, \&return_ink_black, \&return_ink_cyan, \&return_ink_magenta, \&return_ink_yellow);
my %data;
my $mqtt_instance;
my $subscribed;

sub return_car_battery {
  return "car/battery";
}

sub return_car_connected {
  return "car/cable_connected";
}

sub return_car_time {
  return "car/charge_time";
}

sub return_car_range {
  return "car/range";
}

sub return_solar_battery {
  return "solax/battery_capacity";
}

sub return_solar_power {
  return "solax/solar_power";
}

sub return_solar_exported {
  return "solax/exported_power";
}

sub return_solar_bat_power {
  return "solax/battery_power";
}

sub return_ink_black {
  return "brother/ink/black";
}

sub return_ink_cyan {
  return "brother/ink/cyan";
}

sub return_ink_magenta {
  return "brother/ink/magenta";
}

sub return_ink_yellow {
  return "brother/ink/yellow";
}

sub rcv_msg {
  my ($topic, $message) = @_;
  #print_error("Received mqtt message $message on topic $topic");
  if (($message ne "") && ($message ne "unavailable") && ($message ne "unknown")) {
    $data{$topic} = $message;
  } else {
    delete $data{$topic};
  }
}

sub mqtt_server_address {
  my $host = $mqtt_ref->{'ip'} ? $mqtt_ref->{'ip'} : $mqtt_ref->{'server'};
  my $ping = `ping -n -q -c 3 -W 1 -4 $host`;
  chomp($ping);
  return if (length($ping) == 0);
  return if ($ping =~ /No address associated with hostname/);
  return if ($ping =~ /0 received/);
  return $host if $mqtt_ref->{'ip'};
  my @lines = split(/\n/, $ping);
  #print_error($lines[0]);
  $lines[0] =~ /\((\d+.\d+.\d+.\d+)\)/;
  my $ip = $1;
  #print_STDERR($ip);
  return if (length($ip) == 0);
  print_error("Found MQTT server at $ip");
  $mqtt_ref->{'ip'} = $ip;
  return $ip;
}

sub check_mqtt_subscribed {
  my $online = (my $server = mqtt_server_address());
  while (!$online) {
    print_error("Unable to ping MQTT server " . $mqtt_ref->{'server'});
    $mqtt_instance->cleanup() if $mqtt_instance;
    $mqtt_instance = undef;
    sleep 1;
    $online = ($server = mqtt_server_address());
  }
  if (!$mqtt_instance && $online) {
    $mqtt_instance = AnyEvent::MQTT->new(host => $server, user_name => $mqtt_ref->{'username'}, password => $mqtt_ref->{'password'});
    print_error("Unable to receive messages from MQTT server " . $server) unless ($mqtt_instance);
    print_error("Connected to MQTT server $server for subscriptions") if $mqtt_instance;
    $subscribed = 0;
  }
  if ($mqtt_instance && ($subscribed == 0)) {
    foreach my $topic_sub (@topics_subs) {
      my $topic = $topic_sub->();
      print_error("Registering subscription for $topic");
      my $cv = $mqtt_instance->subscribe(topic => $topic, callback => sub { rcv_msg(@_); });
    }
    $subscribed = 1;
  }
}

sub get_mqtt_values {
  my $data_ref = {};
  check_mqtt_subscribed();
  foreach my $topic (keys %data) {
    $data_ref->{$topic} = $data{$topic};
  }
  #print_hash_params($data_ref);
  return $data_ref;
}


1;
