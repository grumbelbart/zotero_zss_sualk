package ZSS::Store;

use strict;
use warnings;

use Digest::MD5 qw (md5_hex);
use File::Util qw(escape_filename);
use File::Path qw(make_path);

sub new {
  my $class = shift;

  # TODO: read from config
  my $self = {storagepath => shift};

  bless $self, $class;
}

sub get_path {
  my $self = shift;
  my $key = shift;

  my $filename = md5_hex($key);

  my $dir = $self->{storagepath} . substr($filename, 0, 1) . "/" . $filename ."/";

  make_path($dir);

  return $dir . escape_filename($key, '_');
}

sub store_file {
  my $self = shift;
  my $key = shift;
  my $file = shift;

  my $filepath = $self->get_path($key);
  #$self->log($filepath);
 
 # TODO: check if file already exists
  # what to do then? overwrite?

  open(my $fh, '>:raw', $filepath);
  print $fh ($file);
  close($fh);
 # TODO: add another file with the metadata (Content-MD5, Content-Type, ...)

}

sub check_exists{
  my $self = shift;
  my $key = shift;
  
  my $path = $self->get_path($key);
  unless (-e $path){
    return 0;
  }
  return 1;
}

sub retrieve_file {
  my $self = shift;
  my $key = shift;

  unless($self->check_exists($key)){
    return undef;
  }
  my $path = $self->get_path($key);
  open(my $fh, '<:raw', $path);
  return $fh;
}

sub get_size{
  my $self = shift;
  my $key = shift;

  my $path = $self->get_path($key);
  
  unless (-e $path) {
   return 0;
  }
  my $size = -s $path;
  return $size;
}

sub link_files{
  my $self = shift;
  my $source_key = shift;
  my $destination_key = shift;

  my $source_path = $self->get_path($source_key);
  my $destination_path = $self->get_path($destination_key);

  return link($source_path, $destination_path);
}

1;
