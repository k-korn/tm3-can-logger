#!/usr/bin/perl
#
# Tesla CAN logger 
# © 2020 Korn
# 

use 5.010;
use Data::Dumper;
#use Zabbix::Sender;  # Uncomment all "sender" mentions for Zabbix integration.
use Net::MQTT::Simple;
use Time::HiRes qw(gettimeofday tv_interval time);
use experimental qw( switch );

my $res;
my $t_now = 0;
my $t_sent = 0;
my $t_dump = 0;
my $t_mqtt = 0;
my $t_cons = 0;

#Defines
my $RATED_KWH = 0.13 # Rated kwh/km for your car
my $SEND_FREQ_IDLE = 30;
my $SEND_FREQ_DRIVE = 4;
#Below is changed based on mode.
my $SEND_FREQ = 30;
my $DUMP_FREQ = 0.3;
my $MQTT_FREQ = 0.1;


$SIG{INT} = \&cleanexit;
$SIG{TERM} = \&cleanexit;

my $STATEFILE='/data/permstore.txt';
#my $INFLUX_ENABLED = 1;

my $drive_states = {
	'4' => 'Abort',
	'5' => 'Drive',
	'3' => 'Fault',
	'2' => 'Standby',
	'1' => 'Cond',
	'0' => 'Idle'
};

#What to receive 
my @IDs = qw(118 132 20C 212 241 243 252 257 261 264 266 268 287 2D2 315 321 332 336 352 3B6 3D2 3D8 3FE);

#my $sender = Zabbix::Sender->new({
 #       'server' => 'localhost',
#        'port' => 10051,
#        'hostname' => 'teslapi',
#        });


my $mqtt = Net::MQTT::Simple->new("127.0.0.1:1884");

 
print "Waiting for MQTT socket\n";
while(1) {
	my $ns = `netstat -4nl`;
	last if $ns =~ /0.0.0.0:1884/;
	print "not yet\n";
	sleep 5;
}
print "Done\n";

#Construct CAN filters;
my $flt = '';
for my $cid (@IDs) {
	#	print "i: $cid\n";
	$flt .= "$cid:3FF,";
}
$flt =~ s/,$//g;

$| = 1;
my $sleeping = 2;
my $ps = {}; #persistent store
my $sent = {};
my $dcnt = 0;
my $last_seen = {};

my $ptimes = {}; #prev measurement times
my $joules = {};  #power usage energy
$ps->{drive_state_prev} = -1;


#Read persistent store
open SF,"<$STATEFILE";
while (<SF>) {
	chomp;
	my ($n,$v) = $_ =~ /^(.*): (.*)$/;
	if ($n =~ /^j_(.*)$/) {
		$joules->{$1} = $v;
	} else {
		$ps->{$n} = $v;
	}	
}
close SF;


while (1) {
open(CD,"candump can0,$flt -r 32768 -ta -T 1000 |");
while (<CD>) {
$t_now = time();
$dcnt++;

chomp;
#print "l: $_\n";
my ($ts,$id,$data_txt) = $_ =~ /^\s+\((\S+)\)\s+can0\s+([0-9A-F]{3})\s+\[\d\]\s+([0-9A-F ]+).*/;
next if !defined $id;

$ts =~ s/\.//g;
$ts .= '000';
#print "$ts: $id $data_txt\n";

#We're awake, send this
if ($sleeping == 2) {
	print "Awake\n";
	$sleeping = 0;
        $sender->bulk_buf_add(['sleeping',$sleeping,int($t_now)]);
	$sender->bulk_send;

}



#print "id: |$id| data: |$data_txt|\n";
my @d = split / /, $data_txt;
@d = map { hex($_) } @d;
#print Dumper([@data]);
my $dbin = unpack('Q',pack('cccccccc',@d));



# zero out values that can stop flowing
for my $key (keys %$last_seen) {
	my $td = $last_seen->{$key} - $t_now;
	if ($t_now - $last_seen->{$key} > 1) {
		print "$key no longer observed, zeroing\n";
		$res->{$key}->{avg} = 0;
		$res->{$key}->{val} = 0;

		delete $last_seen->{$key};
	}

}

if ($t_now - $t_dump > $DUMP_FREQ) {


	# calculated trip/state  stats  every update interval
	if (($ps->{dis_start} > 0) && $ps->{chg_volt} < 10) {
		my $odo_delta = $ps->{odo_now} - $ps->{odo_start};
		my $chg_delta = sprintf('%0.3f',$ps->{chg_now} - $ps->{chg_start});
		my $dis_delta = sprintf('%0.3f',$ps->{dis_now} - $ps->{dis_start});
		$ps->{chg_delta} = $chg_delta;
		$ps->{dis_delta} = $dis_delta;
		$res->{trip_cpu}->{avg}  = $joules->{cpu}  / 3600;
		$res->{trip_hvac}->{avg} = $joules->{hvac} / 3600;
		$res->{trip_evap}->{avg} = $joules->{evap} / 3600;
		$res->{trip_sys}->{avg}  = $joules->{sys_heat}  / 3600;
		$res->{trip_used}->{avg} =  $dis_delta;
		$res->{trip_regen}->{avg} = $chg_delta;
		$res->{trip_driven}->{avg} =  $odo_delta;
		#other usage.
		$res->{trip_other}->{avg} = $dis_delta - ($res->{trip_cpu}->{avg} + $res->{trip_hvac}->{avg} + $res->{trip_evap}->{avg} + $res->{trip_sys}->{avg});

		#Regen percent, if discharge is >0
		if ($dis_delta > 0) {
			$res->{trip_regper}->{avg} = 100 *  $chg_delta / $dis_delta;
		}

		# Trip consumption, if traveled >10 meters
		if ($odo_delta > 10) {
			my $trip_rate = 1000 * ($dis_delta - $chg_delta ) / $odo_delta;
			$trip_rate = 1999 if $trip_rate > 1999;
			if ($trip_rate != 0) {
				$res->{trip_rate}->{avg} =  $trip_rate;
			}

		}

	}

}#dump calc end

# Frequent file dump
if ($t_now - $t_dump > $DUMP_FREQ) {
	my $out = '';
	my $i = 0;
	for my $id (sort keys %$res) {
	my $val = (defined $res->{$id}->{val} && $res->{$id}->{cnt} > 0) ? $res->{$id}->{val} / $res->{$id}->{cnt} : $res->{$id}->{avg};
	#next if !defined($res->{$id}->{avg});
	$out .= sprintf("%s: %0.2f\n",$id,$val);
	$i++
	}
	$out .= "\n";
	for my $id (sort keys %$ps) {
		$out .=  sprintf("ps| %s: %0.2f\n",$id,$ps->{$id});
	}
	$out .= "\n";
	for my $id (sort keys %$joules) {
			$out .=  sprintf("j| %s: %0.2f\n",$id,$joules->{$id});
	}

	#print "Dumping $i values\n";
	#print Dumper($res);
	open DF, '>/dev/shm/statdump';
	print DF $out;
	close DF;
	$t_dump = $t_now;

}



#Send to mqtt
if ($t_now - $t_mqtt > $DUMP_FREQ) {
        for my $id (sort keys %$res) {
		my $val = (defined $res->{$id}->{val} && $res->{$id}->{cnt} > 0) ? $res->{$id}->{val} / $res->{$id}->{cnt} : $res->{$id}->{avg};
		send_mqtt($id,$val);

        }
	$t_mqtt = $t_now;
}


#Send results to Zabbix, calculate averages
if ($t_now - $t_sent > $SEND_FREQ) {
	$sent = {};


	#Calculate averages where needed.
	for my $id (sort keys %$res) {
		next if $res->{$id}->{cnt} == 0;
		next if !defined($res->{$id}->{val});
		$res->{$id}->{avg} = $res->{$id}->{val} / $res->{$id}->{cnt};
	}

	# Send to Zabbix
	for my $id (sort keys %$res) {
		next if !defined $res->{$id}->{avg};
#		$sender->bulk_buf_add([$id,$res->{$id}->{avg},int($t_now)]);
	}
#	$sender->bulk_buf_add(['sleeping',$sleeping,int(time())]);
#	$sender->bulk_send;

	$t_sent = $t_now;
	$ps->{fps} = $dcnt / $SEND_FREQ;
	$dcnt = 0;

	undef $res;


} #Zabbix end


# Parse specific IDs
given($id) {

when('118') { # Drive State
	#print "ID 118: $data_txt\n";
	my $drive_state = getbits($dbin,'16|3@1+ (1,0)');
	my $park_state  = getbits($dbin,'19|2@1+ (1,0)');
	my $gear_state  = getbits($dbin,'21|3@1+ (1,0)');

	#print "State: drive $drive_state park: $park_state gear: $gear_state \n";
	$res->{drive_state}->{avg} = $drive_state;
	$res->{park_state}->{avg} = $park_state;
	$res->{gear_state}->{avg} = $gear_state;
	
	#Modulate send frequency if driving
	if ($drive_state == 0 ) { #Idle
		$SEND_FREQ = $SEND_FREQ_IDLE;
	} else {
		$SEND_FREQ = $SEND_FREQ_DRIVE;
	}
	#Recording trip data
	$ps->{drive_state} = $drive_state;
	if ($drive_state != $ps->{drive_state_prev} && $ps->{dis_now} > 0 ) {
		print "Drive state changed to $drive_state\n";
		#notify
		my $td = sprintf("%0.1f",(time() - $ps->{time_start}) / 60);
		if ($td > 2) { #If state is longer than 2 minutes
			my $smsg = $drive_states->{int($ps->{drive_state_prev})}." finished in $td min\n";
			if ($res->{trip_driven}->{avg} > 0) {
					$smsg .= sprintf("Distance: %0.2f km consumption: %0.1f wh/km Regen: %0.1f %%\n",
					$res->{trip_driven}->{avg} / 1000,
					$res->{trip_rate}->{avg},
					$res->{trip_regper}->{avg}
				);

			}
			$smsg .= sprintf("Used: %0.0f Wh\n",$res->{trip_used}->{avg});
			$smsg .= sprintf("Driven: %0.0f Wh\n",$res->{trip_other}->{avg});
			$smsg .= sprintf("HVAC: %0.0f Wh\n",$res->{trip_hvac}->{avg}) if $res->{trip_hvac}->{avg} > 0;
			$smsg .= sprintf("SYS: %0.0f Wh\n",$res->{trip_sys}->{avg}) if $res->{trip_sys}->{avg} > 0;
			$smsg .= sprintf("EVAP: %0.0f Wh\n",$res->{trip_evap}->{avg}) if $res->{trip_evap}->{avg} > 0;
			$smsg .= sprintf("CPU: %0.0f Wh\n",$res->{trip_cpu}->{avg});
			send_msg($smsg);
		}
		
		$ps->{chg_start} = $ps->{chg_now};
		$ps->{dis_start} = $ps->{dis_now};
		$ps->{odo_start} = $ps->{odo_now};
		$ps->{drive_state_prev} = $drive_state;
		$ps->{time_start} = time();
		for my $jkey (keys %$joules) {
			$joules->{$jkey} = 0;
		}
	}



}	
when('132') { # Battery status
	#print "ID 132: $data_txt\n";

	# Battery voltage
	my $bv = getbits($dbin,'0|16@1+ (0.01,0)');

	# Battery current (smooth)
	my $bi = -1 * getbits($dbin,'16|16@1- (0.1,0)');
	next if $bi > 800;

	#Battery current raw 
	my $br = sprintf("%0.2f",500 +  -0.05 * (unpack('s',pack("cc",@d[4,5]))));

	my $br = -1 *  getbits($dbin,'32|16@1- (0.05,-500)') ;

	#Battery power, calculated.
	my $bp = $br * $bv;


	# 
	#print "bv: $bv bi: $bi br: $br  bri: $bri\n";
	#we want raw. 
	$res->{bat_v}->{val} += $bv;
	$res->{bat_v}->{cnt}++;

	$res->{bat_i}->{val} += $br; #we want raw current.
	$res->{bat_i}->{cnt}++;

	$res->{bat_p}->{val} += $bp;
	$res->{bat_p}->{cnt}++;
	
	$ps->{bat_kw_avg} = (63 * $ps->{bat_kw_avg} + $bp/1000) / 64;
	send_mqtt("dis_kmh",sprintf("%3.1f",$ps->{bat_kw_avg} / $RATED_KWH));
	send_mqtt("bat_kw",sprintf("%02.2f",$ps->{bat_kw_avg}));
	#$mqtt->publish("dis_kmh"=> sprintf("%3.1f",$bp/130));
	#$mqtt->publish("bat_kw"=> sprintf("%02.2f",$ps->{bat_kw_avg}));
	#$mqtt->publish("bat_i"=> sprintf("%0.2f",$br));
	#$mqtt->publish("bat_v"=>sprintf("%0.2f",$bv));

}

when('20C') { # VCRIGHT_hvacRequest
	#print "ID 20C: $data_txt\n";
	my $evap_watts = getbits($dbin,'0|11@1+ (5,0)');
	my $evap_enabled = getbits($dbin,'11|1@1+ (1,0)');
	my $evap_temp = getbits($dbin,'13|11@1+ (0.1,-40)');
	my $evap_target = getbits($dbin,'24|8@1+ (0.2,0)');

	#print "EVAP en: $evap_enabled T: $evap_temp TGT: $evap_target P: $evap_watts\n";
	
	$res->{evap_p}->{avg} = $evap_watts;
	$res->{evap_en}->{avg} = $evap_enabled;
	$res->{evap_t}->{avg} = $evap_temp;
	$res->{evap_tgt}->{avg} = $evap_target;
	#Heat accounting
	if (defined $ptimes->{evap}) {
			my $tdelta = tv_interval($ptimes->{evap});
			#print "td: $tdelta\n";
			$joules->{evap} += $evap_watts * $tdelta;
			$ptimes->{evap} = [gettimeofday];
	}


}

when('212') { # BMS status
	#print "Id 212: $data_txt\n";
	my $bat_tmin = getbits($dbin,' 56|8@1+ (0.5,-40) ');
	#print "Batt T min: $bat_tmin\n";
	$res->{bat_tmin}->{avg} = $bat_tmin;
}

when('241') { #Liter per minute coolant
	#print "ID 241: $data_txt\n";
	my $lpm_bat = getbits($dbin,' 0|9@1+ (0.1,0)');
	my $lpm_pt = getbits($dbin,' 22|9@1+ (0.1,0) ');

	#print "LPM: batt $lpm_bat n: $lpm_bat_n pt $lpm_pt\n";
	$res->{lpm_bat}->{val} += $lpm_bat;
	$res->{lpm_bat}->{cnt}++;
	$res->{lpm_pt}->{val} += $lpm_pt;
	$res->{lpm_pt}->{cnt}++;

}

when('243') { # HVAC status
	#print "Id 243: $data_txt\n";
	my $hvac_idx = getbits($dbin,'0|2@1+ (1,0)');
	if ($hvac_idx == 0) {
		my $temp_cabin = getbits($dbin,'30|11@1+ (0.1,-40)');
		#print "Cabin: $temp_cabin\n";
		$res->{temp_cabin}->{avg} = $temp_cabin;
	}

}

when('252') { # Power limits
	#print "ID 252: $data_txt\n";
	# Regen limit
	my $rlim = getbits($dbin,'0|16@1+ (0.01,0)');
	#Discharge limit
	my $dlim = getbits($dbin,'16|16@1+ (0.01,0)');


	#print "rlim: $rlim dlim: $dlim\n";
	$res->{reg_lim}->{val} += $rlim;
	$res->{reg_lim}->{cnt}++;

	$res->{dis_lim}->{val} += $dlim;
	$res->{dis_lim}->{cnt}++;

}

when('257') { # Speed
	#print "ID 257: $data_txt\n";
	my $speed = getbits($dbin,'12|12@1+ (0.08,-40)');
	$res->{cur_speed}->{avg} = $speed;
	$ps->{speed_avg} = (63 * $ps->{speed_avg} + $speed) / 64;
	send_mqtt("cur_speed", sprintf("%3.1f",$speed));

	#Instant usage
	if ($speed > 2) {
		$res->{cur_use}->{avg} = 1000 * $ps->{bat_kw_avg} / $ps->{speed_avg};
		$res->{cur_use}->{avg} = 9999 if $res->{cur_use}->{avg} > 9999;
		send_mqtt('cur_use',$res->{cur_use}->{avg});
	}

}

when('261') { # 12v batt
	#print "ID 261: $data_txt\n";

	my $ah_12   = getbits($dbin,'32|14@1- (0.01,0)');
	my $curr_12 = getbits($dbin,'48|16@1- (0.005,0)');
	my $volt_12 = getbits($dbin,'0|12@1+ (0.00544,0)');
	my $temp_12 = getbits($dbin,' 16|16@1- (0.01,0)');


	#print "12v volt: $volt_12 t: $temp_12 curr: $curr_12 ah $ah_12\n";		
	$res->{volt_12}->{avg} = $volt_12;
	$res->{temp_12}->{avg} = $temp_12;
	$res->{ah_12}->{avg} = $ah_12;
	$res->{curr_12}->{val} += $curr_12;
	$res->{curr_12}->{cnt}++;

}

when('264') { # Charger stats
	#print "ID 264: $data_txt\n";
	my $chg_volt = getbits($dbin,'0|14@1+ (0.033,0)');
	my $chg_curr = getbits($dbin,'14|9@1+ (0.1,0)');
	my $chg_pow = getbits($dbin,'24|8@1+ (0.1,0)');

	#print "chg v: $chg_volt i: $chg_curr p: $chg_pow\n";
	
	$res->{chg_curr}->{val} += $chg_curr;
	$res->{chg_curr}->{cnt}++;
	$res->{chg_volt}->{val} += $chg_volt;
	$res->{chg_volt}->{cnt}++;
	$res->{chg_pow}->{val} += $chg_pow;
	$res->{chg_pow}->{cnt}++;
	$ps->{chg_volt} = $chg_volt;

}

when('266') { # Rear power
	#print "ID 266: $data_txt\n";
	
	#Rear power, 11 bit at 0
	my $rear_p = getbits($dbin,'0|11@1- (0.5,0)');
	
	my $rear_heat_opt = getbits($dbin,'16|8@1+ (0.08,0)');
	my $rear_heat     = getbits($dbin,'32|8@1+ (0.08,0)');
	my $rear_heat_max = getbits($dbin,'24|8@1+ (0.08,0)');
	#print "Rear KW: $rear_p Heat: $rear_heat Opt: $rear_heat_opt Max: $rear_heat_max\n";
	$res->{rear_p}->{val} += $rear_p;
	$res->{rear_p}->{cnt} ++;
	$res->{rear_heat}->{val} += $rear_heat;
	$res->{rear_heat}->{cnt} ++;
	$res->{rear_heat_opt}->{avg} = $rear_heat_opt;
	$res->{rear_heat_max}->{avg} = $rear_heat_max;
	send_mqtt("rear_p",sprintf("%3.2f",$rear_p));
	#$mqtt->publish("rear_p"=> sprintf("%3.2f",$rear_p));
	$last_seen->{rear_p} = $t_now;

}

when('268') { # Sys power, heat
	#print "ID 268: $data_txt\n";
	my $sys_heatmax  = getbits($dbin,'0|8@1+ (0.08,0)');
	my $sys_heatcurr = getbits($dbin,'8|8@1+ (0.08,0)');
	my $sys_drivemax = getbits($dbin,'16|9@1+ (1,0) ');
	my $sys_regmax   = getbits($dbin,'32|8@1+ (1,-100)');

	#print "SYS heat max: $sys_heatmax curr: $sys_heatcurr drivemax: $sys_drivemax regen max: $sys_regmax\n";
	 $res->{sys_heat_cur}->{avg} = $sys_heatcurr;
	 $last_seen->{sys_heat_cur} = $t_now;
	if (defined $ptimes->{sys_heat}) {
			my $tdelta = tv_interval($ptimes->{sys_heat});
	#print "td: $tdelta\n";
			$joules->{sys_heat} += 1000 * $sys_heatcurr * $tdelta;
			$ptimes->{sys_heat} = [gettimeofday];
	} else {
			$ptimes->{sys_heat} = [gettimeofday];
	}
}

when('287') { # PTC Cabin Heater
	#print "ID 287: $data_txt\n";
	my $ptc_volt = getbits($dbin,'32|10@1+ (0.5,0)');
	my $ptc_curl = getbits($dbin,'48|8@1+ (0.2,0)');
	my $ptc_curr = getbits($dbin,'56|8@1+ (0.2,0)');
	my $ptc_pl = $ptc_volt * $ptc_curl;
	my $ptc_pr = $ptc_volt * $ptc_curr;
	my $ptc_p  = $ptc_pl + $ptc_pr; #Sum of left + right power

	#print "PTC V: $ptc_volt PL: $ptc_pl PR: $ptc_pr\n";
	$res->{heat_left}->{avg} = $ptc_pl;
	$res->{heat_right}->{avg} = $ptc_pr;
	$res->{heat_hvac}->{avg} = $ptc_p;

	#Heat accounting
	if (defined $ptimes->{hvac}) {
		my $tdelta = tv_interval($ptimes->{hvac});
		#print "td: $tdelta\n";
		$joules->{hvac} += $ptc_p * $tdelta;
		$ptimes->{hvac} = [gettimeofday];
		#Also, CPU counts
		my $jcpu = 130;
		$joules->{cpu} += $jcpu * $tdelta;
	} else {
		$ptimes->{hvac} = [gettimeofday];
	}

}

when('2D2') { #BMS stats
	#print "ID 2D2: $data_txt\n";

	#min volt
	my $bms_min  = getbits($dbin,' 0|16@1+ (0.01,0)');
	my $bms_max  = getbits($dbin,'16|16@1+ (0.01,0)');
	my $bms_maxc = getbits($dbin,'32|14@1+ (0.1,0)');
	my $bms_maxd = getbits($dbin,'48|14@1+ (0.128,0)'); 

	#print "bms min: $bms_min max: $bms_max maxchg: $bms_maxc maxd: $bms_maxd\n";
	$res->{bms_max_c}->{avg} = $bms_maxc;
	$res->{bms_max_d}->{avg} = $bms_maxd;


}

when('315') { #Rear Motor Temps
	#print "ID 315: $data_txt\n";
	my $rear_pcb_temp = getbits($dbin,'0|8@1+ (1,-40)');
	my $rear_inv_temp = getbits($dbin,'8|8@1+ (1,-40)');
	my $rear_sta_temp = getbits($dbin,'16|8@1+ (1,-40)');

	#print "Reat temps: pcb $rear_pcb_temp inv $rear_inv_temp sta $rear_sta_temp \n";
	$res->{rear_pcb_temp}->{avg} = $rear_pcb_temp;
	$res->{rear_inv_temp}->{avg} = $rear_inv_temp;
	$res->{rear_sta_temp}->{avg} = $rear_sta_temp;
}

when('321') { #VCFront Sensors
	#print "ID 321: $data_txt\n";

	#Coolant Battery Inlet
	my $temp_cbi = getbits($dbin,'0|10@1+ (0.125,-40)');
	# Coolant powertrain inlet
	my $temp_cpi = getbits($dbin,'10|11@1+ (0.125,-40)');
	#Ambient temp
	my $temp_amb = getbits($dbin,'24|8@1+ (0.5,-40)');

	#print "temp cbi: $temp_cbi cpi: $temp_cpi amb $temp_amb\n";
	$res->{temp_cbi}->{avg} = $temp_cbi;
	$res->{temp_cpi}->{avg} = $temp_cpi;
	$res->{temp_amb}->{avg} = $temp_amb;

}

when('332') { #BMS min/max cell stats
	#print "ID 332: $data_txt\n";
	my $bc_mode = getbits($dbin,'0|2@1+ (1,0)');
	#print "bc mode: $bc_mode\n";
	if ($bc_mode eq 0) { #Temperatures
		my $bc_tmin = getbits($dbin,'24|8@1+ (0.5,-40)');
		my $bc_tmax = getbits($dbin,'16|8@1+ (0.5,-40)');
		#print "bc tmin: $bc_tmin max: $bc_tmax\n";
		$res->{bc_tmin}->{avg} = $bc_tmin;
		$res->{bc_tmax}->{avg} = $bc_tmax;

	} else { # Voltages
		my $bc_vmin = getbits($dbin,'16|12@1+ (0.002,0)');
		my $bc_vmax = getbits($dbin, '2|12@1+ (0.002,0)');

		#print "bc vmin: $bc_vmin max: $bc_vmax\n";
		$res->{bc_vmin}->{avg} = $bc_vmin;
		$res->{bc_vmax}->{avg} = $bc_vmax;
		$res->{bc_vdiff}->{avg} = 1000 * ($bc_vmax - $bc_vmin);

	}

}
when('336') { #Drive, Regen rated
	#print "ID 336: $data_txt\n";
	my $rated_power = getbits($dbin,'0|9@1+ (1,0)');
	my $rated_regen = getbits($dbin,'16|8@1+ (1,-100)');

	#print "P rated: $rated_power R: $rated_regen\n";
	$res->{rated_pow}->{avg} = $rated_power;
	$res->{rated_reg}->{avg} = $rated_regen;
}

when('352') { #BMS Energy Status
	#print "ID 252: $data_txt\n";
	my $kw_full = getbits($dbin,' 0|10@1+ (0.1,0)');
	my $kw_rem  = getbits($dbin,'10|10@1+ (0.1,0)');
	my $kw_exp  = getbits($dbin,'20|10@1+ (0.1,0)');
	my $kw_ideal= getbits($dbin,'30|10@1+ (0.1,0)');
	my $kw_buf  = getbits($dbin,'50|8@1+ (0.1,0)');

	#print "kw_full: $kw_full kw_rem: $kw_rem exp: $kw_exp ideal: $kw_ideal buf $kw_buf\n";
	$res->{kw_full}->{avg} = $kw_full;
	$res->{kw_rem}->{avg}  = $kw_rem;
	$res->{kw_exp}->{avg} = $kw_exp;
	$res->{kw_ideal}->{avg} = $kw_ideal;
	$res->{kw_buf}->{avg} = $kw_buf;

	# Derivatives
	$res->{km_rem}->{avg} = ($kw_rem - $kw_buf) / $RATED_KWH;
	$res->{km_exp}->{avg} = ($kw_exp - $kw_buf) / $RATED_KWH;
	$res->{km_full}->{avg} = ($kw_full - $kw_buf) / $RATED_KWH;
	$res->{km_frozen}->{avg} = ($kw_rem - $kw_exp) / $RATED_KWH;
	$res->{bat_usable}->{avg} = 100 * ($kw_exp - $kw_buf) / ($kw_full - $kw_buf);
	$res->{bat_frozen}->{avg} = 100 * ($kw_rem - $kw_exp) / ($kw_full - $kw_buf);

}

when('3B6') {# Odometer
	#print "ID 3B6: $data_txt\n";	
	my $odom = getbits($dbin,'0|32@1+ (1,0)');

	next if $odom > 4200000000; #overflow
	$res->{odom}->{avg} = $odom;
	$ps->{odo_now} = $odom;
	$ps->{odo_start} = $ps->{odo_now } if "$ps->{odo_start}" eq "";
}

when('3D2') { #Total charge/discharge
	#print "ID 3D2: $data_txt\n";
	my $total_dis = getbits($dbin,'0|32@1+ (0.001,0)');
	my $total_chg = getbits($dbin,'32|32@1+ (0.001,0)');

	#print "total dis: $total_dis chg:$total_chg \n";
	$res->{total_dis}->{avg} = $total_dis;
	$res->{total_chg}->{avg} = $total_chg;
	$ps->{dis_now} = $total_dis * 1000;
	$ps->{chg_now} = $total_chg * 1000;
}

when('3D8') { #Elevation
	#print "ID 3D8: $data_txt\n";
	my $elev = getbits($dbin,'0|16@1+ (1,0)');
	#print "Elev: $elev\n";
	$res->{elev}->{avg} = $elev;
}

when('3FE') { #Brake temps
	#print "ID 3FE: $data_txt\n";
	#Front Left, 10-bit from 0
	my $btemp_fl = getbits($dbin,' 0|10@1+ (1,-40)');
	my $btemp_fr = getbits($dbin,'10|10@1+ (1,-40)');
	my $btemp_rl = getbits($dbin,'20|10@1+ (1,-40)');
	my $btemp_rr = getbits($dbin,'30|10@1+ (1,-40)');

	$res->{btemp_fl}->{avg} = $btemp_fl;
	$res->{btemp_fr}->{avg} = $btemp_fr;
	$res->{btemp_rl}->{avg} = $btemp_rl;
	$res->{btemp_rr}->{avg} = $btemp_rr;
}

default { 
	#print "ID $id: $data_txt\n"
}

} # Given/when end
}# Main loop end

close CD;
#print "CAN bus idle, sleeping\n";
$sleeping = 1;
#$sender->bulk_buf_add(['sleeping',$sleeping,int($t_now)]);
#$sender->bulk_send;
$sleeping = 2;
$ptimes = {};
sleep 1;
} #External while true loop end


sub getbits { # Get bit value from message, using DBC file format encoding.

	my $v = shift;
	my $mask = shift;

	#print "Mask: $mask v: $v\n";
	my ($start,$width,$end,$sign,$mult,$add) = ($mask =~ /^\s*(\d+)\|(\d+)\@(\d)([+-]) \((.*?),(.*?)\)\s*$/);
	#print "s $start,w $width,e $end,s $sign,m $mult,a $add\n";

	my $res = ($v >> $start) & (1 << $width) - 1;

	#Signed.
	if ($sign eq "-") {
		my $bw = 1 << $width;
		$res -= $bw if $res > ($bw / 2 - 1);
	}

	# Little-endian
	if ($sign eq '0') {
		print STDERR "LittleEndian not implemented\n";
	}
	$res = $mult * $res + $add;
	#print "res: $res\n";
	return $res;

}

sub send_mqtt { #Publish to local MQTT
	my $id  = shift;
	my $val = shift;

	return if $val eq $sent->{$id};
	$sent->{$id} = $val;
        $val /= 1000 if $id =~ /^(trip_driven|heat_hvac|evap_p)$/;
	$val = int($val) if $id eq 'dis_lim';

	# 1-digit values
	if ($id =~ /(dis_kmh|trip_rate|temp.*|bat_tmin|rear_p|sys_heat_cur|cur_speed)/) {
	        $val = sprintf("%0.1f",$val);
	} else {
		$val = sprintf("%0.2f",$val);
	}
	$val =~ s/\.?0+$// if $id !~ /(bat_kw|dis_kmh|cur_speed|rear_p|sys_heat_cur)/;
        $mqtt->publish($id => $val);
}

sub send_msg {  # Send message to owner via some custom channel. Customize this if needed.

	my $msg = shift;
	system('echo', '/usr/bin/mosquitto_pub','-h','127.0.0.1','-t','/sbot/send_now','-m',$msg);

}

sub cleanexit {
	print "Storing persistence on exit\n";
	open SF,">$STATEFILE";
	for my $n (sort keys %$ps) {
		print SF "$n: ".$ps->{$n}."\n";
	}
        for my $n (sort keys %$joules) {
                print SF "j_$n: ".$joules->{$n}."\n";
        }

	close SF;
	exit;
}
