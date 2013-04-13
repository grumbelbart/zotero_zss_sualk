#!/usr/bin/perl
use strict;
use warnings;

use lib ('/path/to/ZSS.pm');

use ZSS;

my $app = ZSS->new();

$app->psgi_callback();
