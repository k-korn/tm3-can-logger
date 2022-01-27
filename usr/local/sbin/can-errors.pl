#!/usr/bin/perl
use 5.010;
use Data::Dumper;
use File::Slurp;
use Time::HiRes qw(usleep);



my @IDs = qw(123 124 304 31E 320 325 32F 338 33F 340 356 357 35A 35B 35D 360 365 367 368 36B 36E 370 371 37F 384 385 391 395 39F 3A4 3A5 3AA 3B5 3BE 3C0 3C5 3C8 3D5 3DE 3E5 3E8 3F1 3F9 46C 502 54B 54F);

my $whitelist = {
	'can0  123   [8]  00 00 12 12 D2 00 00 00' => 1, # homelink, premium audio, etc
	'can0  123   [8]  00 00 13 12 D2 00 00 00' => 1, # same while driving
	'can0  320   [8]  01 00 00 08 00 00 00 00' => 1, # BMS_a084_SW_Sleep_Wake_Aborted = 1
	'can0  340   [8]  04 40 00 00 00 00 00 00' => 1, # Trying to sleep
	'can0  340   [8]  03 0C 00 00 00 00 00 00' => 1, #Trying to sleep
	'can0  340   [8]  01 00 00 00 02 00 00 00' => 1, #unknown multiplier
	'can0  3F9   [8]  02 00 01 00 00 00 00 00' => 1, #alarm vcsec
	'can0  3C0   [8]  02 00 00 04 00 00 00 00' => 1, #mirrorManuallyFolded
};


#check alive
my $statfile='/sys/class/net/can0/statistics/rx_packets';

my $logfile = '/data/logs/can-errors.log';

my $prev = read_file($statfile); chomp $prev;
sleep(1);
my $now = read_file($statfile); chomp $now;

if ($now == $prev) {
	print STDERR "Car is sleeping, nothing to do\n";
	exit;
}


my $res ;

#Construct CAN filters;
my $flt = '';
for my $cid (@IDs) {
       	#      	print "i: $cid\n";
       	$flt .= "$cid:3FF,";
}
$flt =~ s/,$//g;

print STDERR "Capturing some frames..\n\n";
open(CD,"candump can0,$flt -r 32768 -tA -n 100 |");
my $seen;
while (<CD>) {
$t_now = time();
chomp;
my $line = $_;
my $id = $1 if /can0  (\S+) /;
my $ts = $1 if / \((.*)\)/;
my $canline = $1 if /(can0 .*)/;

next if (! grep /^$id$/,@IDs);  #mismatched IDS
$seen->{$id} = 1;

next if $canline =~ /00 00 00 00 00 00 00/; # all good
next if defined $whitelist->{$canline};

#print "$id ts: $ts line: $canline\n";
$res->{$canline} = $line;

}
my $received = scalar keys %$seen;
my $total = scalar @IDs;
my $errs = scalar keys %$res;
print STDERR "Received $received of $total messages, $errs errors\n";
exit if $errs == 0;
print join("\n", values %$res) . "\n";

open LF, ">>$logfile";
print LF join("\n", values %$res) . "\n";
close LF;
