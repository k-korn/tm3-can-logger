#!/usr/bin/perl
#
# Huawei 3372 modem status monitor
# © 2020 Korn
#  

use Data::Dumper;
use LWP::UserAgent;
use Net::MQTT::Simple;
use File::Slurp;

local $Data::Dumper::Terse = 1;
local $Data::Dumper::Indent = 1;
local $Data::Dumper::Useqq = 1;
local $Data::Dumper::Deparse = 1;
local $Data::Dumper::Quotekeys = 0;
local $Data::Dumper::Sortkeys = 1;


my $net_type = {
'0' => 'None',
'1' => 'GSM',
'2' => 'GPRS',
'3' => 'EDGE',
'4' => 'WCDMA',
'5' => 'HSDPA',
'6' => 'HSUPA',
'7' => 'HSPA',
'8' => 'TDSCDMA',
'9' => 'HSPA+',
'17' => 'HSPA+64',
'18' => 'HSPA+M',
'19' => 'LTE'
};

my $conn_state = {
	900 => 'Connecting',
	901 => 'Online',
	902 => 'Offline',
	903 => 'Disconnecting'
};


my $URL='http://192.168.8.1/api/';



my $mqtt = Net::MQTT::Simple->new("127.0.0.1:1884");
my $ua = LWP::UserAgent->new();
$ua->requests_redirectable([]);

#my $cookie_jar = HTTP::Cookies->new(  file => "/tmp/mdm-cj.txt",autosave => 1,  ignore_discard => 1, );
#$ua->cookie_jar( $cookie_jar );
$|++;

do_auth();

while (1) {

$mh = api_get('monitoring/status');
#print Dumper($mh);

send_mqtt('modem_sig',$mh->{SignalIcon});
send_mqtt('modem_sig_max',$mh->{maxsignal});
send_mqtt('modem_state',$conn_state ->{$mh->{ConnectionStatus}});
send_mqtt('modem_net',$net_type->{$mh->{CurrentNetworkType}});

write_file('/dev/shm/modem_stats',"modem_sig: ".$mh->{SignalIcon}."
modem_state: ".$mh->{ConnectionStatus}."
modem_net: ".$mh->{CurrentNetworkType}."\n");


sleep 15;
}


sub do_auth() {

my $st_res = $ua->get($URL."webserver/SesTokInfo");

die("Unable to authorize") if $st_res->code() != 200;
my $sess = xml2hash($st_res->decoded_content);
$ua->default_header(':__RequestVerificationToken' => $sess->{TokInfo});
$ua->default_header('COOKIE' => $sess->{SesInfo});

}

sub api_get() {
	my $path = shift;
	my $rres = $ua->get($URL.$path);
	my $rhash = xml2hash($rres->decoded_content);
	if (defined $rhash->{code}) {
		if ($rhash->{code} == 125002) {
			print "Auth needed at $path\n";
			do_auth();
			$rres = $ua->get($URL.$path);
			$rhash = xml2hash($rres->decoded_content);
		} else {
			print "Request error on $path, code ".$rhash->{code}."\n";
			exit 1;
		}
	}


	return $rhash;

}


sub xml2hash() {

	my $data = shift;
	my $res;
	while ($data =~ /^<(\w+)>(.*?)<\/\w+>/gm) {
		
		my $k = $1;
		my $v = $2;
		next if $v eq '';
		#print "k: $k v: $v\n";
		$res->{$k} = $v;
	}
	return $res;

}


sub send_mqtt { #Publish to local MQTT
        my $id  = shift;
        my $val = shift;
        $mqtt->retain($id => $val);
}

