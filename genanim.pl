use strict;
use Data::Dumper;
use File::Copy;

my (%sizes, @frames, @global_frames, %alias, $ROOT, %root_config);

my %allowed_components = (
	br => 0,	# brightness. -1 black, 0 normal, +1 white
	scx => 1,	# scale x only
	scy => 1,	# scale y only
	scxp => -1,	# scale x to a set pixel width, y is original height by default
	scyp => -1,	# scale y to a set pixel height, x is original width by default
	al => 1,	# alpha blending, 0 = transparent, 1 = opaque
	rot => 0,	# rotation in degrees, +ve = rotate right, -ve = rotate left
);

my $framerate = 25;

my %key_frames = ();
unlink("cmd.log");
#my $coords = gen_coords($this_file, $this_dur, \@keys);
my %used = ();
my %start_frames = ();
my $end_filter;
my $debug = 0;
my $duration;

#===============================================

sub dump_callers {
	my $i = 0;
	while (my ($package, $filename, $line, $subroutine) = caller($i++)) {
		print "$filename $line $subroutine\n";
	}
}

#===============================================

sub round {
	my $num = shift @_;
	my $int = int($num);
	my $f = $num - $int;

	if ($f >= 0.5) {
		return $int+1;
	} else {
		return $int;
	}
}


sub _system {
	my $cmd = shift @_;

	my $run_cmd;

	$cmd =~ s/\\/\//g;

	my @bits = split(/\|/, $cmd);
	$run_cmd = shift @bits;
	if ($debug) {
		open(CMD_LOG, ">>cmd.log") or die $!;
	}

	my $count = 1;
	while (@bits > 0) {
		$run_cmd .= " | " . shift @bits;
		$count++;
		if ($count == 4000 && @bits > 0) 
		{
			$run_cmd .= " > tmp_$$.pnm";
print CMD_LOG "$run_cmd\n\n" if ($debug);
print "cmd is [$run_cmd]\n";

			my $r = system($run_cmd);
			if ($r) {
				die "cmd [$run_cmd] FAILED";
			}
			$run_cmd = "cat tmp_$$.pnm";
			$count = 1;
		}
	}

	if ($run_cmd eq "cat tmp_$$.pnm") {
		close(CMD_LOG) if ($debug);
		return 0;
	} else {
		print CMD_LOG "$run_cmd\n\n" if ($debug);
		close(CMD_LOG) if ($debug);
		return system($run_cmd);
	}
}

#===============================================

sub gen_coords {
	my ($file, $alias, $dur, $keyref, $main_start_frame, $global_start_frame, $debug_this) = @_;

	my @keys = @{$keyref};
	my @coords = ();
	my @legs = ();
	my $distance = 0;
	my @files = sort glob("$ROOT/src/".$file);
	
	my $this_size = get_image_size($files[0]);
	my ($size_x, $size_y) = @{$this_size};

	# calc distance

	for (my $i = 1; $i < @keys; $i++) {

		my $xa = $keys[$i-1]->{x};
		my $ya = $keys[$i-1]->{y};
		my $xb = $keys[$i]->{x};
		my $yb = $keys[$i]->{y};

#		my ($xa, $ya) = @{$keys[$i-1]};
#		my ($xb, $yb) = @{$keys[$i]};

		$xa = $xa + ($size_x/2); # scale here
		$ya = $ya + ($size_y/2); # scale here
		$xb = $xb + ($size_x/2); # scale here
		$yb = $yb + ($size_y/2); # scale here

		# distance is distance of centres

		my $leg_distance = get_vector_length($xa, $ya, $xb, $yb);
		$distance += $leg_distance;

		$legs[$i-1]->{distance} = $leg_distance;
		$legs[$i-1]->{xa} = $xa;
		$legs[$i-1]->{xb} = $xb;
		$legs[$i-1]->{ya} = $ya;
		$legs[$i-1]->{yb} = $yb;

		$legs[$i-1]->{scale_a} = 1; # scale here
		$legs[$i-1]->{scale_b} = 1; # scale here

		$legs[$i-1]->{alpha_a} = 1; # alpha here
		$legs[$i-1]->{alpha_b} = 1; # alpha here

		foreach my $comp (keys %allowed_components) {
			$legs[$i-1]->{"${comp}_a"} = $keys[$i-1]->{$comp}
				if (defined($keys[$i-1]->{$comp}));
			$legs[$i-1]->{"${comp}_b"} = $keys[$i]->{$comp}
				if (defined($keys[$i]->{$comp}));
		}
	}

if ($debug_this) {
#	print Dumper(\@legs) . "\n";
}

	# calc frames to use

	my $num_frames = $dur;
	my $tot_frames = 0;

	# calc duration in frames of each leg

	for (my $i = 0; $i < @legs; $i++) {
		$legs[$i]->{frames} = round(($legs[$i]->{distance} / $distance) * $num_frames);
		$tot_frames += $legs[$i]->{frames};
	}

	# adjust for any rounding errors

	my $legnum = 0;
	while ($tot_frames != $num_frames) {
		# add/remove frames to each leg until even
		if ($tot_frames > $num_frames) {
			$legs[$legnum]->{frames}--;
			$tot_frames --;
		} else {
			$legs[$legnum]->{frames}++;
			$tot_frames ++;
		}
		$legnum++;
		$legnum=0 if ($legnum == @legs);
	}

#print "legs breakdown: ";
#foreach my $ll (@legs) {
#	print "[$ll->{frames}] ";
#}
#print "\n";


	# now calculate the frames (into @coords)

	for (my $j=0; $j<@legs; $j++) {
		my $i = $legs[$j];
		my $frames_to_reach = $i->{frames}; # removed "+1"
		# disabled - needed?
		#$frames_to_reach -- if ($i == @legs-1);

		for (my $f=0; $f < $i->{frames}; $f++) { # changed here

			my $this_scale = $i->{scale_a} + ($f+1)*(($i->{scale_b} - $i->{scale_a})/$frames_to_reach);
			my $this_alpha = $i->{alpha_a} + ($f+1)*(($i->{alpha_b} - $i->{alpha_a})/$frames_to_reach);
			my $this_file = $files[(scalar @coords + $main_start_frame)%(scalar @files)];
			my $this_xc = $i->{xa} + ($f+1)*(($i->{xb} - $i->{xa})/$frames_to_reach);
			my $this_yc = $i->{ya} + ($f+1)*(($i->{yb} - $i->{ya})/$frames_to_reach);
			my $this_x = $this_xc - ($size_x*$this_scale)/2;
			my $this_y = $this_yc - ($size_y*$this_scale)/2;
			my $this_xs = $this_scale * $size_x;
			my $this_ys = $this_scale * $size_y;

			my %this_entry = ( x => $this_x,
					y => $this_y,
					xc => $this_xc,
					yc => $this_yc,
					file => $this_file,
					alias => $alias,
					scale => $this_scale,
					alpha => $this_alpha,
					xs => $this_xs,
					ys => $this_ys,
					);

			if ($f==0) {
				foreach my $comp (keys %allowed_components) {
					if (defined($i->{$comp . "_a"})) {
						$this_entry{$comp} = $i->{$comp . "_a"};
#print "Set $alias $comp to $this_entry{$comp} for frame " . ($f+$global_start_frame) . "\n";
						push @{ $key_frames{$alias}{$comp} } , $f+$global_start_frame;
					}
				}
			}

			if ($f==$i->{frames}-1) {
				# last run
				foreach my $comp (keys %allowed_components) {
					if (defined($i->{$comp . "_b"})) {
						$this_entry{$comp} = $i->{$comp . "_b"};
#print "B Set $alias $comp to $this_entry{$comp} for frame " . ($f+$global_start_frame) . "\n";
						push @{ $key_frames{$alias}{$comp} } , $f+$global_start_frame;
					}
				}
				push @{ $key_frames{$alias}{ranges} }, [ $global_start_frame, $f+$global_start_frame ];
#print "B ranges for alias $alias is " . Dumper($key_frames{$alias}{ranges}) . "\n";
			}

			push @coords, \%this_entry;
		}
	}
#print "final entry $alias is " . Dumper($coords[-1]) . "\n";
	return \@coords;
}
	
#===============================================

sub smooth_coords {
	my $coordref = shift @_;
	my @coord_list = @{$coordref};

	for (my $rep=0; $rep<=15; $rep++) {

		my ($ave_x, $ave_y, $diff_x, $diff_y);

		for (my $i=3; $i<(@coord_list - 3); $i++) {
			$ave_x = $ave_y = 0;
			for (my $j=-3; $j<=3; $j++) {
				$ave_x += $coord_list[$i+$j]->{xc};
				$ave_y += $coord_list[$i+$j]->{yc};
			}

			$ave_x = $ave_x/7;
			$ave_y = $ave_y/7;


			$diff_x = $ave_x - $coord_list[$i]->{xc};
			$diff_y = $ave_y - $coord_list[$i]->{yc};

			$coord_list[$i]->{x} += $diff_x;
			$coord_list[$i]->{y} += $diff_y;
			$coord_list[$i]->{xc} += $diff_x;
			$coord_list[$i]->{yc} += $diff_y;
		}
	}

	return \@coord_list;
}



#===============================================

sub render_components {
	my $coordref = shift @_;

	foreach my $alias (sort keys %key_frames) {
		push my @ranges, shift @{ $key_frames{$alias}{ranges} };
		foreach my $r (@{ $key_frames{$alias}{ranges} }) {
			if ($r->[0] == $ranges[-1][1]+1 or $r->[0] == $ranges[-1][1]) {
				$ranges[-1][1] = $r->[1];
			} else {
				push @ranges, $r;
			}
		}

#print "Ranges $alias : " .Dumper(\@ranges) . "\n";
		foreach my $r (@ranges) {
			my ($start, $finish) = @{$r};
			foreach my $comp (sort keys %allowed_components) {
				my @keys = ();
				my $nokeys = 0;
				if (defined($key_frames{$alias}{$comp})) {
					foreach my $k (@{ $key_frames{$alias}{$comp} }) {
						push @keys, $k if ($k>= $start and $k <= $finish);
					}
					if ($keys[0] != $start) {
						unshift @keys, $start;
						set_frame_alias_comp_val($coordref, $start,  $alias, $comp, $allowed_components{$comp});
					}
#print "finish is $finish, keys right now [" . join("][", @keys) ."]\n";
					if ($keys[-1] != $finish) {
#print "HERE knef\n";
						#while ($finish >= round($root_config{duration}*$framerate)) {
						#	$finish--; # KLUDGE!
						#}
						push @keys, $finish;
						my $nv = get_frame_alias_comp_val($coordref, $keys[-2], $alias, $comp);
die "nv $alias $comp [" . $keys[-2] . "] is undef: obj is " . Dumper($coordref->[$keys[-2]]) . "prev obj is " . Dumper($coordref->[$keys[-2]-1]) . "next obj is " . Dumper($coordref->[$keys[-2]+1]) . "" if (!defined($nv));
						set_frame_alias_comp_val($coordref, $finish, $alias, $comp, $nv);
					}
				} else {
#print "HERE sf\n";
					@keys = ($start, $finish);
					set_frame_alias_comp_val($coordref, $start,  $alias, $comp, $allowed_components{$comp});
					set_frame_alias_comp_val($coordref, $finish, $alias, $comp, $allowed_components{$comp});
					$nokeys=1;
				}
#print "keys $alias $comp: [" . join("][", @keys) . "]\n";
				for (my $i=0; $i<@keys-1; $i++) {
					my $a = $keys[$i];
					my $b = $keys[$i+1];
#unless ($nokeys) {
#	print "Start frame $a is " . Dumper($coordref->[$a]) . "\n";
#	print "End frame $b is " . Dumper($coordref->[$b]) . "\n";
#}

					my $av = get_frame_alias_comp_val($coordref, $a, $alias, $comp);
					my $bv = get_frame_alias_comp_val($coordref, $b, $alias, $comp);
#					print "Range $alias $comp $a to $b, vals $av to $bv\n" unless ($nokeys);
#exit(1) unless($nokeys or $comp le "rot");
					for (my $f=$a; $f<=$b; $f++) {
						my $newval = ($b-$a==0 ? $av :$av + ($f-$a)*(($bv-$av)/($b-$a)));
						#print "a $alias c $comp f $f v $newval\n" unless ($nokeys);
						set_frame_alias_comp_val($coordref, $f, $alias, $comp, $newval);
					}
				}
			}
		}
	}


	return $coordref;
}

#===============================================

sub set_frame_alias_comp_val {
	my ($coordref, $frame, $alias, $comp, $val) = @_;
#print "set $alias $comp f $frame v $val\n";
	# find pos in list for that frame
	my $pos = 0;
	my $found = 0;

	foreach (@{ $coordref->[$frame] }) {
		if ($coordref->[$frame]->[$pos]->{alias} eq $alias) {
			$coordref->[$frame]->[$pos]->{$comp} = $val;
			$found = 1;
			last;
		}
		$pos++;
	}

}

#===============================================

sub get_frame_alias_comp_val {
	my ($coordref, $frame, $alias, $comp) = @_;
	my $val = undef;
#print "get $alias $comp f $frame\n";
	# find pos in list for that frame
	my $pos = 0;
	my $found = 0;

	foreach (@{ $coordref->[$frame] }) {
		if ($coordref->[$frame]->[$pos]->{alias} eq $alias) {
			$val = $coordref->[$frame]->[$pos]->{$comp};
			$found = 1;
			last;
		}
		$pos++;
	}

	if (!$found) {
		print "couldn't find alias [$alias] in frame [$frame] following: " . Dumper($coordref->[$frame]) . "\n";
		exit(1);
	}

	return $val;
}

#===============================================

sub alias_is_in_frame {
	my ($coordref, $wanted_alias, $f) = @_;
	my @coords = @{$coordref};

	my $ret = 0;

	for (my $i = 0; $i < @{$coords[$f]}; $i++) {
		if ($wanted_alias eq $coords[$f][$i]{alias}) {
			$ret = 1;
			last;
		}
	}
	return $ret;
}

#===============================================

sub get_vector_length {
	my ($xa, $ya, $xb, $yb) = @_;

	my $ret = ( (($xa - $xb)**2) + (($ya - $yb)**2) ) ** .5;
	$ret ||= 0.0001;

	return $ret;
}

#===============================================

sub read_root_config {
	my $cfg_file = shift @_;

	$root_config{numformat} = "\%d";

	open (CFG, "<$cfg_file") or die "$cfg_file: $!";
	while (my $line = <CFG>) {
		chomp($line);
		$line =~ s/\s\s+/ /g;
		$line =~ s/\s+$//;
		$line =~ s/^\s+//;

		next if ($line eq "");
		next if ($line =~ m/^#/);

		my ($tag, $rest) = split(' ', $line, 2);
		$tag = lc($tag);

		if ($tag eq "duration") {

			$root_config{$tag} = $rest;

		} elsif ($tag eq "numformat") {

			$root_config{$tag} = $rest;

		} elsif ($tag eq "size") {

			if ($rest =~ m/^(\d+) (\d+)$/) {
				$root_config{$tag}->{x} = $1;
				$root_config{$tag}->{y} = $2;
			} else {
				die "Size [$line] not valid";
			}

		} elsif ($tag =~ m/^layer\d+/) {
		
			$root_config{$tag} = $rest;

		} else {
			die "Can't handle [$line] in root config";
		}

	}
	close(CFG);
}

#===============================================

sub read_layer_config {
	my $cfg_file = shift @_;
	my %gen_durations = ();


	open (CFG, "<$cfg_file") or die "$cfg_file: $!";
	while (my $line = <CFG>) {
		chomp($line);
print "line is [$line]\n";
		$line =~ s/\s\s+/ /g;
		$line =~ s/\s+$//;
		$line =~ s/^\s+//;

		next if ($line eq "");
		next if ($line =~ m/^#/);

		my ($tag, $rest) = split(' ', $line, 2);
		$tag = lc($tag);

		if ($tag eq "duration") {

			$duration = $rest;

		} elsif ($tag eq "filter") {

			$end_filter = $rest;

		} elsif ($tag eq "alias") {

			my ($alias_name, $file_name) = split(" ", $rest);
			$alias{$alias_name} = $file_name;

		} elsif ($tag eq "line" or $tag eq "curve") {

			if ($rest =~ m/^(\d+\.*\d*)\s+(\d+\.*\d*)\s+\(\s*(.*)\s*\)\s+(.*)$/) {
				my ($start_sec, $end_sec, $coord_str, $this_file) = ($1, $2, $3, $4);
				#$start_sec = sprintf("%.3f", $start_sec);
				#$end_sec = sprintf("%.3f", $end_sec);
				my $start_frame = int($start_sec*$framerate);
				my $end_frame = round($end_sec*$framerate);
				my $this_dur = $end_frame - $start_frame;
				my @keys = ();
				my $got_extra = 0;
#print "line [$line]\ntag [$tag] rest [$rest]\nstart_sec [$start_sec] end_sec [$end_sec]\ncoord_str [$coord_str] this_file [$this_file]\n";
				foreach my $entry (split(/\s*\)\s*\(\s*/, $coord_str)) {
					my %this_hash = ();

					my @components = split(/\s*\|\s*/, $entry);
					my $this_entry = shift @components;

					if ($this_entry =~ m/^\s*(\-*\d+)\s*,\s*(\-*\d+)$/) {
						my ($this_x, $this_y) = ($1,$2);
						$this_hash{x} = $this_x;
						$this_hash{y} = $this_y;
					} else {
						die "Bad entry [$entry] in [$line]?";
					}

					foreach my $comp (@components) {
						if (lc($comp) =~ m/^\s*([a-z]+)\s*(\-*[\d\.]+)\s*$/) {
							my ($type, $val) = ($1, $2);
							my @type_list;
							if ($type eq "sc") {
								@type_list = ("scx","scy");
							} else {
								push @type_list, $type;
							}
							foreach $type (@type_list) {
								if (defined($allowed_components{$type})) {
									$this_hash{$type} = $val;
									$got_extra = scalar @keys + 1;
								} else {
									die "Unknown component [$type] in [$entry]";
								}
							}
						} else {
							die "bad component format [$comp] in [$entry]";
						}
					}

					push @keys, \%this_hash;
				}

				my $this_alias = $this_file;
				if (defined($alias{$this_file})) {
					$this_file = $alias{$this_file};
				} else {
					$alias{$this_file} = $this_file;
				}

				$start_frames{$this_alias} = round($start_sec*$framerate)
					unless(defined($start_frames{$this_alias}));
if ($got_extra) {
#	print "key [$got_extra] is " . Dumper($keys[$got_extra-1]) . "\n";
}

				$gen_durations{$this_alias} += $this_dur;

#print "total duration for $this_alias is going to be $gen_durations{$this_alias}\n";

				my $coords = gen_coords($this_file, $this_alias, $this_dur, \@keys, 
					int($start_sec*$framerate)-$start_frames{$this_alias}, 
					int($start_sec*$framerate), $got_extra);

				if ($tag eq "curve") {
					$coords = smooth_coords($coords);
				}

				for (my $f=0; $f<$start_sec*$framerate; $f++) {
					@{$frames[$f]} = ()
						if (!defined($frames[$f]));
				}

				for (my $i=0; $i<@{$coords}; $i++) {
					my $this_frame_num = int($start_sec*$framerate + $i);
					$coords->[$i]->{frame_num} = $i;
					if (defined($used{$this_frame_num}{$coords->[$i]->{alias}})) {
#print "Overwriting alias $coords->[$i]->{alias} frame $this_frame_num\n";
#print "Old obj: " .  Dumper($frames[$this_frame_num][$used{$this_frame_num}{$coords->[$i]->{alias}}]) . "\n";
#print "new obj: " . Dumper($coords->[$i]) . "\n";
						foreach my $comp (keys %allowed_components) {
							$coords->[$i]->{$comp} = $frames[$this_frame_num][$used{$this_frame_num}{$coords->[$i]->{alias}}]->{$comp}
								if (defined($frames[$this_frame_num][$used{$this_frame_num}{$coords->[$i]->{alias}}]->{$comp}));
						}
#print "new obj now: " . Dumper($coords->[$i]) . "\n";

						$frames[$this_frame_num][$used{$this_frame_num}{$coords->[$i]->{alias}}] = $coords->[$i];
					} else {
						if (!defined($duration) or ($this_frame_num < $framerate*$duration)) {
							push @{$frames[$this_frame_num]}, $coords->[$i];
							$used{$this_frame_num}{$coords->[$i]->{alias}} = scalar @{$frames[$this_frame_num]} -1;
							#$used{$this_frame_num}{$coords->[$i]->{alias}} = 1;
#print "{$this_frame_num}{$coords->[$i]->{file}} set to 1\n";
						}
					}
				}

			} else {
				die "Bad format for tag [$tag]? [$line]";
			}

		} elsif ($tag eq "fade") {

			print "fade TODO\n";

		} else {

			die "Tag [$tag] unrecognized\n";

		}
	}
	close(CFG);

	@frames = @{render_components(\@frames)};
}

#===============================================

sub cat_img {
	my $filename = shift @_;
	my $gen = shift @_;
	$gen = "" unless (defined($gen));
	my $gen_file;
	my $ret;

	die "$filename doesn't exist" unless (-e $filename);

	if ($filename =~ m/\.p[ngpa]m$/i) {
		$ret = "cat $filename";
		$gen_file = 1 if ($gen);
	} elsif ($filename =~ m/\.gif$/i) {
		if ($gen eq "alpha") {
			$ret = "giftopnm -alphaout=- $filename | ppmtopgm";
		} elsif ($gen eq "mask") {
#			$ret = "giftopnm -alphaout=- $filename | ppmtopgm | pgmtopbm -threshold -value 0.0001";
			$ret = "giftopnm -alphaout=- $filename | ppmtopgm";
		} else {
			$ret = "giftopnm $filename";
		}
	} elsif ($filename =~ m/\.jpe*g$/i) {
		$ret = "jpegtopnm $filename";
		$gen_file = 1 if ($gen);
	} elsif ($filename =~ m/\.tga$/i) {
		$ret = "tgatoppm $filename";
		$gen_file = 1 if ($gen);
	} elsif ($filename =~ m/\.bmp$/i) {
		$ret = "bmptopnm $filename";
		$gen_file = 1 if ($gen);
	} elsif ($filename =~ m/\.png$/i) {
		if ($gen eq "alpha") {
			$ret = "pngtopnm -alpha $filename | ppmtopgm";
		} elsif ($gen eq "mask") {
#			$ret = "pngtopnm -alpha $filename | ppmtopgm | pgmtopbm -threshold -value 0.0001";
			$ret = "pngtopnm -alpha $filename | ppmtopgm";
		} else {
			$ret = "pngtopnm $filename";
		}
	} else {
		die "Can't detect extension of $filename\n";
	} 

	if ($gen_file) {
		my $size = get_image_size($filename);
		if ($gen eq "alpha") {
			$ret = "ppmmake '#FFFFFF' $size->[0] $size->[1] | ppmtopgm";
		} else {
#			$ret = "ppmmake '#FFFFFF' $size->[0] $size->[1] | ppmtopgm | pgmtopbm -threshold -value 0.0001";
			$ret = "ppmmake '#FFFFFF' $size->[0] $size->[1] | ppmtopgm";
		}
	}

	return $ret;
}

#===============================================

sub get_image_size {
	my $filename = shift @_;
#	$filename = $alias{$filename};

	if (defined($sizes{$filename})) {
		return $sizes{$filename};
	}

	die "$filename doesn't exist" unless (-e $filename);

	my ($ret, $retstr, $cmd);

	my $new_filename = $filename;
	do {
		$filename = $new_filename;
		$new_filename =~ s|\w+[/\\]\.\.[/\\]||;
	} while ($filename ne $new_filename);

	$filename = $new_filename;
	$filename =~ s|\\|/|g;

	$cmd = cat_img($filename) . " | pamfile";

	$retstr = `$cmd`;
	chomp($retstr);

	if ($retstr =~ m/(\d+)\s*by\s*(\d+)/) {
		$ret = [ $1 , $2 ];
	} else {
		die "Failed to get size of $filename: retstr [$retstr]";
	}

	$sizes{$filename} = $ret;

	return $ret;
}

#===============================================

sub get_file {
	my $obj = shift @_;
	my $ret;

	( my $pnmname = $obj->{file} ) =~ s|^.*/(.*?)\.\w\w\w$|$ROOT/scratch/$1.pnm|;
	( my $pnmname_alpha = $pnmname ) =~ s/\.pnm$/_-_alpha.pgm/;
	my $pnmname_mask = mask_name($pnmname);

	unless (-e $pnmname) {
		# source image not converted to pnm yet - do it now
		my $cmd = cat_img($obj->{file}) . " > $pnmname";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
		$cmd = cat_img($obj->{file},"alpha") . " > $pnmname_alpha";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
		$cmd = cat_img($obj->{file},"mask") . " > $pnmname_mask";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
	}

	# now generate the processed file if need be

	( my $processed_file = $pnmname ) =~ s/\.pnm$//;
	$processed_file .= "_s" . $obj->{xs} . "x" . $obj->{ys};
	foreach my $c (sort keys %allowed_components) {
		next if ($c eq "al");
		if (!defined($obj->{$c})) {
			print "no comp $c in obj : " . Dumper($obj) . "\n";
			exit(1);
		}
		$processed_file .= "_$c" . $obj->{$c};
	}
	$processed_file .= ".pnm";
	( my $processed_file_alpha = $processed_file ) =~ s/\.pnm$/_-_alpha.pgm/;
	my $processed_file_mask = mask_name($processed_file);

	unless (-e $processed_file) {
		my $xsize = round($obj->{xs}*$obj->{scx});
		my $ysize = round($obj->{ys}*$obj->{scy});

		while ($obj->{rot} >= 360) { $obj->{rot} -= 360 };
		while ($obj->{rot} < 0) { $obj->{rot} += 360 };
		# rot is now rotation to right
		$obj->{rot} = 360 - $obj->{rot} unless ($obj->{rot} == 0);
		# and now it's to the left for pnmflip

		my $rotate_cmd = "";

		if ($obj->{rot} >= 270) {
			$rotate_cmd .= "| pnmflip -r270 ";
			$obj->{rot} -= 270;
		}

		if ($obj->{rot} >= 180) {
			$rotate_cmd .= "| pnmflip -r180 ";
			$obj->{rot} -= 180;
		}

		if ($obj->{rot} >= 90) {
			$rotate_cmd .= "| pnmflip -r90 ";
			$obj->{rot} -= 90;
		}

		if ($obj->{rot} > 0) {
			if ($obj->{rot} > 45) {
				$rotate_cmd .= "| pnmflip -r90 | pnmrotate -noantialias " . ($obj->{rot}-90) . " ";
			} else {
				$rotate_cmd .= "| pnmrotate -noantialias $obj->{rot} ";
			}
		}



		my $interim = "";
		if ($obj->{br} > 0) {
			$interim .= "| ppmflash $obj->{br}";
		} elsif ($obj->{br} < 0) {
			$interim .= "| ppmdim " . ($obj->{br}+1);
		}

		my $cmd = "cat $pnmname | pnmscale -xsize=$xsize -ysize=$ysize $interim $rotate_cmd > $processed_file";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
		$cmd = "cat $pnmname_alpha | pnmscale -xsize=$xsize -ysize=$ysize $rotate_cmd > $processed_file_alpha";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
#		$cmd = "cat $pnmname_mask | pnmscale -xsize=$xsize -ysize=$ysize $rotate_cmd | pgmtopbm -threshold -value 0.001 > $processed_file_mask";
		$cmd = "cat $pnmname_mask | pnmscale -xsize=$xsize -ysize=$ysize $rotate_cmd | ppmtopgm > $processed_file_mask";
		$ret = _system($cmd);
		if ($ret) {
			die "cmd [$cmd] failed";
		}
	}

	# adjust x,y coords unless rot = 0
	unless ($obj->{rot} % 360 == 0) {
		my $sizes = get_image_size($processed_file);
		$obj->{x} = $obj->{xc} - ($sizes->[0]/2);
		$obj->{y} = $obj->{yc} - ($sizes->[1]/2);
	}

	# got the file, return its name


	return $processed_file;
}

#===============================================

sub mask_name {
	my $filename = shift @_;
	( my $ret = $filename ) =~ s/\.p.m$/_-_mask.pbm/;
	return $ret;
}

#===============================================

sub alpha_name {
	my $filename = shift @_;
	( my $ret = $filename ) =~ s/\.pnm$/_-_alpha.pgm/;
	return $ret;
}

#===============================================


if (@ARGV < 2) {
	die "Usage: $0 <root> <layer> (startframe)\n";
}

$ROOT = $ARGV[0];
my $layer = $ARGV[1];
my $start_frame_number = $ARGV[2];

$start_frame_number = 0 if (!defined($start_frame_number));

$ROOT =~ s/\\/\//g;

#print "Line " . __LINE__ . "\n";

read_root_config("$ROOT/config.cfg");

#print "Line " . __LINE__ . "\n";

#print Dumper(\@frames);

# now have all our instructions in @frames
#print "Line " . __LINE__ . "\n";


foreach my $dir ("$ROOT/movie","$ROOT/src","$ROOT/scratch","$ROOT/rects") {
	unless (-d $dir) {
		print "creating dir $dir...\n";
		mkdir $dir;
	}
}
print "Line " . __LINE__ . "\n";


# generate grand command

#foreach my $ff (glob("$ROOT/scratch/*.*")) {
#	unlink($ff);
#}



unless ($start_frame_number) {
	{
		#(my $path = "$ROOT/scratch/*.*") =~ s|/|\\|g;
		#system ("rm $path");
		system "rm -rf $ROOT/scratch";
		mkdir "$ROOT/scratch"; 
	}

#	print "Line " . __LINE__ . "\n";

	foreach my $ff (glob("$ROOT/$layer/mask/*.pnm")) {
		unlink($ff);
	}

#	print "Line " . __LINE__ . "\n";

	foreach my $ff (glob("$ROOT/movie/*.pnm")) {
		unlink($ff);
	}

#	print "Line " . __LINE__ . "\n";
	
	foreach my $ff (glob("$ROOT/movie/*.bmp")) {
		unlink($ff);
	}

#	print "Line " . __LINE__ . "\n";
	
	foreach my $ff (glob("$ROOT/$layer/frames/*.pnm")) {
		unlink($ff);
	}
}

if ($layer =~ m/^layer/i) {

	foreach my $dir ("$ROOT/$layer/mask","$ROOT/$layer/frames") {
		unless (-d $dir) {
			print "creating dir $dir...\n";
			mkdir $dir;
		}
	}

	read_layer_config("$ROOT/$layer/config.cfg");
	my $framenum = 0;
	open(LOG, ">$layer.log") or die $!;
	foreach my $fref (@frames) {
		#if ($framenum < $start_frame_number) {
		#	$framenum++;
		#	next;
		#}
		last if (defined($duration) and $framenum >= $duration*$framerate);
		my $cmd = "ppmmake '#000000' " . $root_config{size}->{x} . " " . $root_config{size}->{y} . " ";
		my $alpha_cmd = "ppmmake '#000000' " . $root_config{size}->{x} . " " . $root_config{size}->{y} . " ";
		my @list = @{$fref};
		print LOG "===================================================\n";
		print LOG "Frame $framenum\n";
		print LOG "===================================================\n";
		print LOG Dumper(\@list) . "\n";
		foreach my $obj (@list) {
			my $name = get_file($obj);
			$cmd .= "| pnmcomp -xoff=" . round($obj->{x}) . " -yoff=" . round($obj->{y}) . " -alpha=" . alpha_name($name) . " -opacity=1 $name ";
			$alpha_cmd .= "| pnmcomp -xoff=" . round($obj->{x}) . " -yoff=" . round($obj->{y}) . " -alpha=" . alpha_name($name) . " -opacity=" . ($obj->{al}) . " " . mask_name($name);
		}
		my $framestr = sprintf("frame" . $root_config{numformat} . ".pnm", $framenum);
		$cmd .= " | ppmlabel -x 0 -y 230 -text $framenum " if ($debug);

		$cmd .= " | $end_filter " if (defined($end_filter));
		$cmd .= " > $ROOT/$layer/frames/$framestr";
		$alpha_cmd .= " | ppmtopgm > $ROOT/$layer/mask/$framestr";

		if ($framenum >= $start_frame_number) {
			my $r = _system($cmd);
			if ($r) {
				die "cmd [$cmd] failed";
			}
	
			$r = _system($alpha_cmd);
			if ($r) {
				die "alpha_cmd [$alpha_cmd] failed";
			}

			print STDERR "Frame $framestr\n";
		}

		$framenum++;
	}
	close(LOG);
} else {

#print "Line " . __LINE__ . "\n";


	# generate movie
	print "generating movie...\n";
	my %layer_length;

#	print "root config: " . Dumper(\%root_config) . "\n";

	my $movie_duration;
	my @layer_keys = sort { 
		my $_a = $a;
		my $_b = $b;
		$_a =~ s/^layer//i;
		$_b =~ s/^layer//i;

		$_a <=> $_b

		} grep(/^layer/i, keys %root_config);


	my $max = 0;
	foreach my $l (@layer_keys) {
		my @list = glob("$ROOT/$l/frames/frame*.pnm");
		my $n = @list;
		print "$n frames in $l\n";
		$layer_length{$l} = $n;
		$max = $n if ($n > $max);
	}

#print "lengths: " . Dumper(\%layer_length) . "\n";

	if ($root_config{duration} =~ m/^\d+\.*\d*$/) {
		$movie_duration = round($root_config{duration} * $framerate);
	} else {
		$movie_duration = $max;
	}

#	print "duration is now $movie_duration\n";

	my $listfilenum = 0;
	my $listfile;
	for (my $f=0; $f < $movie_duration; $f++) {
		if ($f % 5000 == 0) {
			close(LISTFILE) if (defined($listfile));
			$listfile = "$ROOT/movie/tgalist" . ($f/5000 +1) . ".lst";
			open(LISTFILE, ">$listfile") or die "$listfile: $!";
		}
		print LISTFILE "$ROOT/movie/frame$f.tga\n";
		my $cmd = "ppmmake '#000000' " . $root_config{size}->{x} . " " . $root_config{size}->{y} . " ";

		foreach my $l (@layer_keys) {
			my $layer_stem = "$ROOT/$l";
			my ($this_frame, $mask_frame);
			my $frame_name = sprintf("frame" . $root_config{numformat} . ".pnm", $f);
	
			unless (-e "$layer_stem/frames/$frame_name") {
				my $mode = lc($root_config{$l});
				if ($mode eq "loop") {
#					$frame_name = "frame" . ($f % $layer_length{$l}) . ".pnm";
					$frame_name = sprintf("frame" . $root_config{numformat} . ".pnm",  ($f % $layer_length{$l}));
				} elsif ($mode eq "static") {
					$frame_name = sprintf("frame" . $root_config{numformat} . ".pnm",  ($layer_length{$l}-1));
				} elsif ($mode eq "once") {
					# NOP
					next;
				} else {
					die "mode of layer $layer [$mode] unknown";
				}
			}
			$this_frame = "$layer_stem/frames/$frame_name";
			$mask_frame = "$layer_stem/mask/$frame_name";

			if (@layer_keys == 1) {
				# overwrite cmd so it's just a copy
				$cmd = cat_img($this_frame) . " "; # no masking
			} else {
				$cmd .= " | pnmcomp -xoff=0 -yoff=0 -alpha=$mask_frame $this_frame ";
			}
		}
#		$cmd .= " | ppmtobmp -bpp 24 > $ROOT/movie/frame$f.bmp";
		$cmd .= " | ppmtotga -rgb -norle > $ROOT/movie/frame$f.tga";
#		print STDERR "cmd is [$cmd]\n";
		my $r = _system($cmd);
		if ($r) {
			die "cmd [$cmd] failed\n";
		}
		print STDERR "Frame $f\n";
	}
	close(LISTFILE);

	for (my $x=1; $x<= int($movie_duration/5000)+1; $x++) {
		system("tga2avi.sh $ROOT/movie/tgalist$x.lst");
	}

	#system("bmp2avi $ROOT/movie/frame");
	#( my $name = $ROOT ) =~ s|^.*/||;
	#rename("out.avi", "$name.avi");
}

