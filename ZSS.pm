package ZSS;

use strict;
use warnings;

use Plack::Request;
use Digest::HMAC_SHA1 qw(hmac_sha1);
use Digest::MD5 qw (md5_base64);
use MIME::Base64 qw(decode_base64 encode_base64);
use JSON::XS;
use Date::Parse;
use URI;
use URI::QueryParam;
use URI::Escape;
use Switch;
use Encode;

use ZSS::Store;

use Data::Dumper qw(Dumper);
$Data::Dumper::Sortkeys = 1;

sub new {
  my ($class) = @_;

  # TODO: read from config
  my $self = {};
  
  $self->{buckets}->{zotero}->{secretkey} = "yoursecretkey";
  $self->{buckets}->{zotero}->{store} = ZSS::Store->new("/path/to/storage/");

  bless $self, $class;
}

sub respond {
  my $code = shift;
  my $msg = shift;
  return [ $code, [ 'Content-Type' => 'text/plain', 'Content-Length' => length($msg)], [$msg] ];
}

sub xml2string {
  my $xml = shift;

  my $msg = '';
  
  while (my $token = shift @{$xml}) {
    my $data = shift @{$xml};
    $msg .= '<'.$token.'>';
    if (ref $data eq 'ARRAY') {
      $msg .= xml2string($data);
    } else {
      $msg .= $data;
    }
    $msg .= '</'.$token.'>';
  }
  return $msg;
}

sub respondXML {
  my $code = shift;
  my $xml = shift;
  
  return [ $code, [ 'Content-Type' => 'application/xml'], ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".xml2string($xml)] ];
}

sub check_policy {
  my ($self, $cmp, $key, $val) = @_;

  switch ($cmp) {
    case 'eq' {
      if ($key eq 'bucket') {
        $key = $self->{request}->{bucket};
      } else {
        # TODO: Replace Plack::Request
        $key = $self->{req}->parameters->get($key)
      }
      return 1 if $key eq $val;
    };
    case 'content-length-range' {
      my $len = $self->{request}->{env}->{CONTENT_LENGTH};
      $self->log("Length: ".$len.", Limits: ".$key.", ".$val);
      return 1 if (($len > $key) && ($len < $val));
    }
  }
  return 0;
}

sub log {
  my ($self, $msg) = @_;

  $self->{request}->{env}->{'psgix.logger'}->({ level => 'debug', message => $msg });
}

sub get_signature {
  my $self = shift;
  
  my $request = $self->{request};
  my $env = $request->{env};
  
  my $secret = $self->{buckets}->{$request->{bucket}}->{secretkey};

  my $amzstring = '';
  for my $key (sort(grep(/^HTTP_X_AMZ/, keys %$env))) {
    my $value = $env->{$key};
    $key =~ s/_/-/g;
    $amzstring .= lc(substr($key,5)).":".$value."\n";
  }
  
  my $date;
  if ($env->{QUERY_STRING} eq '') {
    $date = $env->{HTTP_DATE};
  } else {
    $date = $request->{uri}->query_param('Expires');
  }

  # TODO: date is mandatory, handle that case
  
  my $stringtosign = $env->{REQUEST_METHOD}."\n".
                     ($env->{HTTP_CONTENT_MD5} || '')."\n".
                     ($env->{CONTENT_TYPE} || '')."\n".
                     ($date || '')."\n".
                     $amzstring.
                     "/".$request->{bucket}."/".$request->{key_escaped};

  # $self->log("Stringtosign:".$stringtosign."End");

  return encode_base64(hmac_sha1($stringtosign, $secret), '');
}

sub check_signature {
  my $self = shift;
  
  my $request = $self->{request};
  my $env = $request->{env};
  
  my $signature = $self->get_signature();
  my $received_signature;
  
  if ($env->{QUERY_STRING} eq '') {
    ($received_signature) = ($env->{HTTP_AUTHORIZATION} || '') =~ m/^AWS .*:(.*)$/;
  } else {
    $received_signature = $request->{uri}->query_param('Signature') || '';
  }

  # $self->log("Check Signature: $received_signature == $signature");
  
  return ($signature eq $received_signature);
}

sub handle_POST {
  my ($self) = @_;
  
  my $request = $self->{request};
  my $env = $request->{env};
  
  my $req = $self->{req};
  
  my $policy = $req->parameters->get('policy');
  my $signature = $req->parameters->get('signature');

  # TODO: check if policy and signature are present
  
  unless ($signature eq encode_base64(hmac_sha1($policy, $self->{buckets}->{$request->{bucket}}->{secretkey}), '')) {
    return respond('403', 'invalid signature');
  }

  my $json = JSON::XS->new->relaxed->decode(decode_base64($policy));
  
  
  return respond(403, 'no expiration given.') unless (defined $json->{expiration});
  my $expiration = Date::Parse::str2time($json->{expiration});

  if ($self->{request}->{starttime} > $expiration) {
    return respond(403, 'timed out');
  }
  $self->log("Expires:".$expiration."; Starttime:".$self->{request}->{starttime});
  
  foreach my $ref (@{$json->{conditions}}) {
    if (ref $ref eq 'HASH') {
      foreach my $key (keys %{$ref}) {
        my $val = encode("utf8", $$ref{$key}); #TODO: better to decode parameter? Is unicode normalization required?
        my $result = $self->check_policy('eq', $key, $val);
        $self->log($key."=".$val."(".$result.")");
        unless ($result == 1) {return respond(403, 'policy invalid');}
      }
    }
    if (ref $ref eq 'ARRAY') {
      my $key = $$ref[1];
      $key =~ s/^\$//;
      my $val = encode("utf8", $$ref[2]); #TODO: better to decode parameter? Is unicode normalization required?
      my $result = $self->check_policy($$ref[0], $key, $val);
      $self->log($key." ".$$ref[0]." ".$val." (".$result.")");
      unless ($result) {return respond(403, 'policy invalid');}
    }
  }

  if (not defined $req->parameters->get('file')) {
    return respond(404, 'file missing');
  }
  unless ($req->parameters->get('Content-MD5') eq md5_base64($req->parameters->get('file')).'==') {
    return respond('403', 'invalid file md5');
  }
  
  my $key = $req->parameters->get('key');
  my $store = $self->{buckets}->{$request->{bucket}}->{store};

  $store->store_file($key, $req->parameters->get('file'));
  
  my $status = $req->parameters->get('success_action_status');
  $status = '403' unless (($status eq '200') || ($status eq '201'));
  
  # TODO: access_action_redirect
  
  return respond($status, '');
}

sub handle_HEAD {
  my ($self) = @_;

  my $request = $self->{request};
  my $env = $request->{env};
  my $key = $request->{key};

  my $store = $self->{buckets}->{$request->{bucket}}->{store};
  
  my $size = $store->get_size($key);
  if ($size == 0){
    return respond(404, 'File not found');
  }
  return [200, ['Content-Length' => $size], []];
}

sub handle_GET {
  my ($self) = @_;

  my $request = $self->{request};
  my $env = $request->{env};

  my $key = $request->{key};

  my $store = $self->{buckets}->{$request->{bucket}}->{store};
  
  unless($store->check_exists($key)){
    return respond(404, 'File not found');
  }
  return [200, ['Content-Length' => $store->get_size($key)], $store->retrieve_file($key)];
}


sub handle_PUT {
  my $self = shift;

  my $request = $self->{request};
  my $env = $request->{env};
  my $store = $self->{buckets}->{$request->{bucket}}->{store};
  
  my $key = $request->{key};

  my $source = $env->{HTTP_X_AMZ_COPY_SOURCE};
  $source = uri_unescape($source); 
  (my $sourceBucket, my $sourceKey) = $source =~ m/^\/([^\?\/]*)\/?([^\?]*)/;

  # $self->log("Source: ".$sourceBucket."/bla/".$sourceKey."\nDestinationKey: ".$key."\n");

  if($store->link_files($sourceKey, $key)){
   return respondXML(200, ['CopyObjectResult' => [ 'LastModified' => '2012', 'ETag' => 'bla']]);
  }
  return respond(405, 'not implemented');
}

sub handle_DELETE {
  my $self = shift;

  my $request = $self->{request};
  my $env = $request->{env};
  my $store = $self->{buckets}->{$request->{bucket}}->{store};


  my $key = $request->{key};

  unless ($store->check_exists($key)) {
    return respond(404, 'File not found');
  }  

  # TODO: Delete file

  return respond(204, "success");

}

sub request_uri {
  my $env = shift;
  
  my $uri = ($env->{'psgi.url_scheme'} || "http") .
            "://" .
            ($env->{HTTP_HOST} || (($env->{SERVER_NAME} || "") . ":" . ($env->{SERVER_PORT} || 80))) .
            ($env->{SCRIPT_NAME} || "");

  return URI->new($uri . $env->{REQUEST_URI})->canonical();
}

sub handle {
  my ($self, $env) = @_;

  my $request = {};

  $request->{env} = $env;
  $request->{starttime} = time();

  $request->{uri} = request_uri($env);

  # split in bucket and key (currently only path style buckets no host style)
  ($request->{bucket}, $request->{key_escaped}) = $env->{REQUEST_URI} =~ m/^\/([^\?\/]*)\/?([^\?]*)/;
  $request->{key} = uri_unescape($request->{key_escaped}) || '';

  return respond(200, "Nothing to see here") if ($request->{bucket} eq '');

  if (not defined $self->{buckets}->{$request->{bucket}}) {
    return respondXML(404,
      ['Error' =>
        ['Code' => 'NoSuchBucket',
         'Message' => 'The specified bucket does not exist',
         'BucketName' => $request->{bucket}] 
      ]);
  }

  $self->{request} = $request;

  # TODO: body parsing for POST. Parameter "file" should be saved as file instead of in memory
  my $req = Plack::Request->new($env);
  $self->{req} = $req;

  my @methods = qw(POST GET HEAD PUT DELETE);

  unless ($env->{REQUEST_METHOD} ~~ @methods) {
    undef($self->{request});
    
    return respondXML(405,
      ['Error' =>
        ['Code' => 'MethodNotAllowed',
         'Message' => 'The specified method is not allowed']
      ]);
  }
  
  my $result;
  if ($env->{REQUEST_METHOD} eq 'POST') {
    $result = $self->handle_POST();
  } else {

    unless ($self->check_signature()) {
      undef($self->{request});
      return respondXML(403, ['Error' => ['Code' => 'SignatureDoesNotMatch']]);
    }

    my $method = 'handle_'.$env->{REQUEST_METHOD};
    $result = $self->$method;
  }
  
  undef($self->{request});
  
  return $result;
};


sub psgi_callback {
    my $self = shift;

    sub {
        $self->handle( shift );
    };
}

1;
