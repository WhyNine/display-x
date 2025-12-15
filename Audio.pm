package Audio;

use strict;
use v5.28;

our @EXPORT = qw ( audio_init @audio_q audio_task audio_state);
use base qw(Exporter);

use lib "/home/pi/display";

use Utils;
use UserDetails qw ( $jellyfin_url );

use Audio::Play::MPG123;
use File::Basename;
use threads;
use threads::shared;
use Thread::Queue;
#use Glib;

my $player;
my $vlc_playing = 0;
my $message_poll;
my $polling = 0;

our @audio_q : shared;
@audio_q = (Thread::Queue->new, Thread::Queue->new);  # to/from queues for audio messages (to = to audio thread, from = from audio thread)

sub player_poll {
  $player->poll(0) if $player;
}

# 0 = idle, 2 = playing
sub audio_state {
  #print_error("audio state = " . $player->state()) if $player;
  #print_error("vlc playing") if $vlc_playing;
  return 2 if $vlc_playing;
  return $player->state() if $player;
  return 0;
}

sub audio_init {
  print_error("audio init");
  my $pulse = `pulseaudio --start`;
  new_player();
  Glib::Source->remove($message_poll) if $message_poll;
  $message_poll = Glib::Timeout->add(1000, sub {
    return 1 unless $polling;                   # only poll if enabled
    player_poll();
    return 1 if audio_state();                  # return if playing or paused
    audio_stop();
    $audio_q[1]->enqueue(shared_clone("play_stopped"));
    return 1;
  });
}

sub new_player {
  $player = new Audio::Play::MPG123;
  print_error("audio initialised ok") if $player;
  print_error("audio initialised fail") unless $player;
}

sub audio_stop {
  print_error("audio stop");
  $player->stop() if $player;
  $polling = 0;
  #$$poll_event_ref->stop() if $poll_event_ref;
}

# Note: Some folders include utf8 chars which aren't handled well by mpg123, so change to folder then play file to get round it
# when playing a network radio stream, sub does not return until vlc process killed externally
sub audio_play {
  my $path = shift;
  #print_error("audio play");
  audio_stop();
  new_player();
  if ($path =~ /^http/ and $path !~ /$jellyfin_url/) {
    print_error("playing stream audio from $path");
    $vlc_playing = 1;
    my $vlc = `cvlc --no-video $path`;
    $vlc_playing = 0;
  } else {
    return unless $player;
    if ($path =~ /^http/) {
      if (!$player->load($path)) {
        print_error("Unable to start playing track at $path");
      } else {
        print_error("Started playing music");
      }
    } else {
      my ($filename, $folder, $suffix) = fileparse($path);
      chdir $folder;
      #print_error($folder);
      if (!$player->load($filename)) {
        print_error("Unable to start playing track at $path");
      } else {
        print_error("Started playing music");
      }
    }
    $polling = 1;
    #$$poll_event_ref->start();
  }
}

sub audio_pause_play {
  #print_error("audio play/pause");
  return unless $player;
  $player->pause();
}

sub audio_task {
  audio_init();
  while (1) {
    my $message = $audio_q[0]->dequeue();                 # wait for next message
    if ($message->{"command"} eq "play") {
      audio_init();
      audio_play($message->{"path"});
    } elsif ($message->{"command"} eq "stop") {
      audio_stop();
    } elsif ($message->{"command"} eq "pause_play") {
      audio_pause_play();
    }
  }
}


1;
