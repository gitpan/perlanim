use strict;
use File::Copy;
use Data::Dumper;

my $multiplier = 1;

sub _system {
	my $cmd = shift @_;

	$cmd =~ s/^\s*cat\s+(.*?)\s*\|(.*?)([\|\>])/$2 \< $1 $3/;

print "_system cmd is [$cmd]\n";
	return system($cmd);
}

sub round {
	my $num = shift @_;
	my $i = int($num);
	my $f = $num - $i;

	if ($f >= 0.5) {
		return $i+1;
	} else {
		return $i;
	}
}


if (@ARGV < 3) {
	die "Usage: $0 image x y\n";
}

my $start_time = time;
my @lines = ();

my %keyframes;

my ($image, $x_window, $y_window) = @ARGV;

my ($preview, $render, $analyze);

$analyze = 0;
my @anal_coords = ();

{
	my $args = join(' ', @ARGV);
	if ($args =~ /\s+preview(\d*)\s*($|)/i) {
		$preview = 1;
		if ($1) {
			$render = 0;
		} else {
			$render = 1;
		}
	} else {
		$preview =0;  $render = 1;
	}

	if ($args =~ /analyze/i) {
		$analyze = 1;
	}

	if ($args =~ /\bmult(\d+)/) {
		$multiplier = $1;
	}
}
print "preview is $preview render is $render\n";
my $framerate = 25;

unless (-e $image) {
	die "Image [$image] doesn't exist\n";
}
$image =~ s/\\/\//g;
( my $ext = lc($image) ) =~ s/^.*\.//;

unless ($ext =~ m/^(gif|bmp|jpg|jpeg|png|ppm)$/) {
	die "Extension [$ext] unrecognized\n";
}

( my $dir = $image ) =~ s|^(.*)/.*$|$1|;
( my $script = $image ) =~ s|^.*/(.*)$|$1|;
$script =~ s/\.$ext$/_$ext/;
my $org_dir = $dir;
my $avi = $org_dir . "/" . $script . ".avi";
$dir .= "/$script";
$script = $org_dir . "/" . $script . ".scr";

my $avi_stem = $dir . "/frame";

unless (-e $script) {
	die "Script [$script] doesn't exist\n";
}

unless (-d $dir) {
	mkdir $dir, 0777 or die "Failed to create dir [$dir]: $!\n";
}

my $frame_num = 0;

if ($preview) {
	open (PREVIEW, ">$dir/preview.htm") or die "Cannot create $dir/preview.htm: $!\n";
}

my @frame_coords = ();

my $listcount = 0;
my $listfile;

sub add_to_listfile {
	my $f = shift @_;
	return if ($f =~ m/\.png$/);
	if ($f =~ m/(\d+)\.tga/) {
		my $num = $1;
		if ($num % 5000 == 0) {
			close(LISTFILE) if (defined($listfile));
			$listcount++;
			$listfile = "$dir/tgalist$listcount.lst";
			open (LISTFILE, ">$listfile") or die "$listfile: $!";
		}
		print LISTFILE "$f\n";
	} else {
		die "weird file: [$f] - no num\n";
	}
}

open (SCRIPT, "<$script") or die "Cannot open [$script]: $!";
while (my $script_line = <SCRIPT>) {
	chomp($script_line);
	next if ($script_line eq "");
	next if ($script_line =~ m/^\s*#/);
	if ($script_line =~ m|^(\d+)[\s,]+(\d+)[\s,]+(\d+)[\s,]+([\d\*]+)\s*>\s*(\d+)[\s,]+(\d+)[\s,]+([\d\*]+)[\s,]+([\d\*]+)\s+(\d+)|) {
		my ($start_x, $start_y, $start_w, $start_h) = ($1, $2, $3, $4);
		my ($end_x, $end_y, $end_w, $end_h) = ($5, $6, $7, $8);
		my $duration = $9;

		if ($end_w eq $end_h and $end_h eq "*") {
			die "Can't have two wildcards in line [$script_line]\n";
		}

		my $frames_to_create = int($duration * $framerate);

		for (my $fr=0; $fr < $frames_to_create; $fr++) {

			my $this_x = $start_x + int((($end_x - $start_x)/$frames_to_create)*$fr);
			my $this_y = $start_y + int((($end_y - $start_y)/$frames_to_create)*$fr);

			my ($this_h, $this_w);

			my $ar = $x_window/$y_window;
			if ($end_h eq "*") {
				$end_h = int($end_w/$ar)
			} elsif ($end_w eq "*") {
				$end_w = int($end_h * $ar);
			}

			if ($start_h eq "*") {
				$start_h = int($start_w/$ar)
			} elsif ($start_w eq "*") {
				$start_w = int($start_h * $ar);
			}

			$this_h = $start_h + int((($end_h - $start_h)/$frames_to_create)*$fr);
			$this_w = $start_w + int((($end_w - $start_w)/$frames_to_create)*$fr);

			my $cmd;
			if ($frame_num == 0) {
				$cmd = "jpegtopnm" if ($ext =~ /^jpe*g$/);
				$cmd = "giftopnm"  if ($ext eq "gif");
				$cmd = "pngtopnm"  if ($ext eq "png");
				$cmd = "bmptopnm"  if ($ext eq "bmp");
				$cmd = "cat"       if ($ext eq "ppm");
	
				$cmd .= " $image ";
				$cmd .= " | pnmscale $multiplier " unless ($multiplier == 1);
				$cmd .= " | tee startimage_$$.ppm ";
			} else {
				$cmd = "cat startimage_$$.ppm ";
			}

			# the first crop

			push @frame_coords, { x => $this_x, y => $this_y, w => $this_w, h => $this_h ,
				boundary => (($fr==0)?1:0) 
#				boundary => (($fr==0 or $fr==$frames_to_create-1)?1:0) 
			};

			$cmd .= "| pamcut -pad -left $this_x -top $this_y -width $this_w -height $this_h ";

			push @anal_coords, [ $this_x, $this_y, $this_w, $this_h ];

			if ($this_w != $x_window or $this_h != $y_window) {
				# scale to window
				$cmd .= "| pnmscale -xsize=$x_window -ysize=$y_window ";
			}

			# write to file

			my $dstr = sprintf("%06d", $frame_num);

			my $this_file;
			if ($preview) {
				$this_file = sprintf("%s/frame$dstr.png", $dir);
			} else {
				$this_file = sprintf("%s/frame$dstr.tga", $dir);
			}
			$this_file =~ s|\\|/|g;
#			$cmd .= "| pnmpad -bottom 76 | ppmtobmp -bpp=24 > $this_file";
#			$cmd .= "| ppmtobmp -bpp=24 > $this_file";
			if ($preview) {
				$cmd .= "| pnmtopng  > $this_file";
			} else {
				$cmd .= "| ppmtotga -rgb -norle > $this_file";
			}
			add_to_listfile($this_file);

			# cue command

			if (!$analyze && (($render || $frame_num == 0) && ((!$preview) or
			    ($preview && $fr%25==0)
				))) {

				print "Generating frame $frame_num...\n";

				my $ret = _system($cmd);
				if ($ret) {
					$ret /= 256;
					die ("cmd [$cmd] failed, returning $ret\n");
				}

				if ($preview) {
					print PREVIEW "<IMG SRC=\"frame$frame_num.png\"> &nbsp; \n";
				}
			}
			$frame_num++;
		}
	} elsif ($script_line =~ m/^(\d+)[\s,]+(\d+)[\s,]+([\d\*]+)[\s,]+([\d\*]+)\s*(pause|fade|line|curve)\s*([\d\.]+)\s*(?:\((.*)\)|)/i) {
		my ($start_x, $start_y, $start_w, $start_h) = ($1, $2, $3, $4);
		my $movement = lc($5);
		my $duration = $6;
		my $arg = $7;

		$start_x *= $multiplier if ($start_x =~ m/^[\d\.]+$/);
		$start_y *= $multiplier if ($start_y =~ m/^[\d\.]+$/);
		$start_w *= $multiplier if ($start_w =~ m/^[\d\.]+$/);
		$start_h *= $multiplier if ($start_h =~ m/^[\d\.]+$/);

		$arg = "" if (!defined($arg));
		my @args = ($arg?split(/\s*,\s*/, $arg):());
		my $frames_to_create = int($duration*$framerate);

#		my $prev_frame = sprintf("%s/frame%d.bmp", $dir, $frame_num-1);
		my $prev_frame = "";

		for (my $i = 0; $i < @args; $i++) {
			if ($args[$i] =~ m/^[\d\.]+$/) {
				$args[$i] *= $multiplier;
			}
		}

######################

		my @coord_list = ();

		for (my $fr=0; $fr < $frames_to_create; $fr++) {

			my ($this_x, $this_y, $this_h, $this_w);

			if ($fr == 0) {
				# calculate coord list
				my ($end_x, $end_y, $end_w, $end_h);
				my @legs = ();

				if ($movement =~ m/^(pause|fade)$/) {
					($end_x, $end_y, $end_w, $end_h) = ($start_x, $start_y, $start_w, $start_h);

						my $ar = $x_window/$y_window;
						if ($end_h eq "*") {
							$end_h = round($end_w/$ar)
						} elsif ($end_w eq "*") {
							$end_w = round($end_h * $ar);
						}

						if ($start_h eq "*") {
							$start_h = round($start_w/$ar)
						} elsif ($start_w eq "*") {
							$start_w = round($start_h * $ar);
						}


					push @legs, { start_x => $start_x, start_y => $start_y, 
					              start_h => $start_h, start_w => $start_w, 
					              end_x => $end_x, end_y => $end_y, 
					              end_h => $end_h, end_w => $end_w
					            };

				} elsif ($movement =~ m/^(line|curve)$/) {
					if (@args %4 != 0) {
						die "line args must be in multiple of 4";
					}
					while (@args > 0) {
						$end_x = shift @args; $end_y = shift @args;
						$end_w = shift @args; $end_h = shift @args;

						my $ar = $x_window/$y_window;
						if ($end_h eq "*") {
							$end_h = round($end_w/$ar)
						} elsif ($end_w eq "*") {
							$end_w = round($end_h * $ar);
						}

						if ($start_h eq "*") {
							$start_h = round($start_w/$ar)
						} elsif ($start_w eq "*") {
							$start_w = round($start_h * $ar);
						}


						push @legs, { start_x => $start_x, start_y => $start_y, 
						              start_h => $start_h, start_w => $start_w, 
						              end_x => $end_x, end_y => $end_y, 
						              end_h => $end_h, end_w => $end_w
						            };

						($start_x, $start_y, $start_w, $start_h) = ($end_x, $end_y, $end_w, $end_h);
					}
				} else {
					die "Unrecognized movement [$movement]";
				}


				# work out centre point and distance of each leg - max accuracy

				my $total_distance = 0;

				foreach my $l (@legs) {
					$l->{start_centre_x} = $l->{start_x} + $l->{start_w}/2;
					$l->{start_centre_y} = $l->{start_y} + $l->{start_h}/2;

					$l->{end_centre_x} = $l->{end_x} + $l->{end_w}/2;
					$l->{end_centre_y} = $l->{end_y} + $l->{end_h}/2;

					my $distance1 = ( ($l->{start_centre_x} - $l->{end_centre_x})**2 + ($l->{start_centre_y} - $l->{end_centre_y})**2 ) ** .5;
					my $distance2 = ( ($l->{start_x} - $l->{end_x})**2 + ($l->{start_y} - $l->{end_y})**2 ) ** .5;

					$l->{distance} = ($distance1 > $distance2 ? $distance1 : $distance2);

					$total_distance += $l->{distance};
				}

				# work out each duration, in frames - refer to frames_to_create

				foreach my $l (@legs) {
					if ($total_distance > 0) {
						$l->{num_frames} = round( ( $l->{distance} / $total_distance ) * $frames_to_create );
					} else {
						# Assume fade/pause
						$l->{num_frames} = $frames_to_create;
					}
				}

				# have all info needed - calculate coords into coord_list

				foreach my $l (@legs) {
					($start_x, $start_y, $start_w, $start_h) = ($l->{start_x}, $l->{start_y}, $l->{start_w}, $l->{start_h});
					($end_x, $end_y, $end_w, $end_h) = ($l->{end_x}, $l->{end_y}, $l->{end_w}, $l->{end_h});

					if (@coord_list > 0) {
						$keyframes{$frame_num+$#coord_list} = 1;
					} else {
						$keyframes{$frame_num} = 1;
					}

					for (my $fr_num=0; $fr_num < $l->{num_frames}; $fr_num++) {

						$this_x = $start_x + round((($end_x - $start_x)/$l->{num_frames})*$fr_num);
						$this_y = $start_y + round((($end_y - $start_y)/$l->{num_frames})*$fr_num);

						$this_h = $start_h + round((($end_h - $start_h)/$l->{num_frames})*$fr_num);
						$this_w = $start_w + round((($end_w - $start_w)/$l->{num_frames})*$fr_num);

						push @coord_list, {x => $this_x, y => $this_y, w => $this_w, h => $this_h,
							centre_x => round($this_x+$this_w/2), centre_y => round($this_y+$this_h/2),
							org_centre_x => round($this_x+$this_w/2), org_centre_y => round($this_y+$this_h/2),
						};
					}

					$keyframes{$frame_num+$#coord_list} = 1;

				}

				if ($movement eq "curve" or $movement eq "line") {
					for (my $l=1; $l < @coord_list; $l++) {
						push @lines, "line " . $coord_list[$l-1]->{org_centre_x} . "," . $coord_list[$l-1]->{org_centre_y} . " " . 
						     $coord_list[$l]->{org_centre_x} . "," . $coord_list[$l]->{org_centre_y};
					}
				}

				if (@coord_list - $frames_to_create == 1) {
					pop @coord_list;
				}
				if (@coord_list - $frames_to_create == -1) {
					push @coord_list, $coord_list[-1];
				}

				if (@coord_list != $frames_to_create) {
					die "MISMATCH: Frames to create: $frames_to_create  Coords listed: ". scalar @coord_list;
				}

				# smooth path if curved

				if ($movement eq "curve") {
					# smooth path - ignore first and last 3 entries so we have a start and end vector

					for (my $rep=0; $rep<=15; $rep++) {

						my ($ave_x, $ave_y, $diff_x, $diff_y);

						for (my $i=3; $i<(@coord_list - 3); $i++) {
							$ave_x = $ave_y = 0;
							for (my $j=-3; $j<=3; $j++) {
								$ave_x += $coord_list[$i+$j]->{centre_x};
								$ave_y += $coord_list[$i+$j]->{centre_y};
							}

							$ave_x = round($ave_x/7);
							$ave_y = round($ave_y/7);

							$diff_x = $ave_x - $coord_list[$i]->{centre_x};
							$diff_y = $ave_y - $coord_list[$i]->{centre_y};

							$coord_list[$i]->{x} += $diff_x;
							$coord_list[$i]->{y} += $diff_y;
							$coord_list[$i]->{centre_x} += $diff_x;
							$coord_list[$i]->{centre_y} += $diff_y;

						}
					}

					my $horiz = 0;
					my $vert = 0;
					for (my $l=1; $l < @coord_list; $l++) {
						push @lines, "bline " . $coord_list[$l-1]->{centre_x} . "," . $coord_list[$l-1]->{centre_y} . " " . 
						     $coord_list[$l]->{centre_x} . "," . $coord_list[$l]->{centre_y}
							if (1);

						my $prev_x = $coord_list[$l-1]->{x};
						my $prev_y = $coord_list[$l-1]->{y};

						if ($prev_x < $coord_list[$l]->{x}) {
							if ($horiz != -1) {
								$horiz = -1;
								push @lines, sprintf("rectangle %d,%d %d,%d", $coord_list[$l-1]->{x}, $coord_list[$l-1]->{y},
									$coord_list[$l-1]->{x}+$coord_list[$l-1]->{w}, $coord_list[$l-1]->{y}+$coord_list[$l-1]->{h});
							}
						} elsif ($prev_x > $coord_list[$l]->{x}) {
							if ($horiz != 1) {
								$horiz = 1;
								push @lines, sprintf("rectangle %d,%d %d,%d", $coord_list[$l-1]->{x}, $coord_list[$l-1]->{y},
									$coord_list[$l-1]->{x}+$coord_list[$l-1]->{w}, $coord_list[$l-1]->{y}+$coord_list[$l-1]->{h});
							}
						}

						if ($prev_y > $coord_list[$l]->{y}) {
							if ($vert != -1) {
								$vert = -1;
								push @lines, sprintf("rectangle %d,%d %d,%d", $coord_list[$l-1]->{x}, $coord_list[$l-1]->{y},
									$coord_list[$l-1]->{x}+$coord_list[$l-1]->{w}, $coord_list[$l-1]->{y}+$coord_list[$l-1]->{h});
							}
						} elsif ($prev_y < $coord_list[$l]->{y}) {
							if ($vert != 1) {
								$vert = 1;
								push @lines, sprintf("rectangle %d,%d %d,%d", $coord_list[$l-1]->{x}, $coord_list[$l-1]->{y},
									$coord_list[$l-1]->{x}+$coord_list[$l-1]->{w}, $coord_list[$l-1]->{y}+$coord_list[$l-1]->{h});
							}
						}

					}
				}
			} 

			# read from coord_list


			($this_x, $this_y, $this_w, $this_h) = ($coord_list[$fr]->{x}, $coord_list[$fr]->{y}, $coord_list[$fr]->{w}, $coord_list[$fr]->{h});
			

			my $cmd;
			if ($frame_num == 0) {
				$cmd = "jpegtopnm" if ($ext =~ /^jpe*g$/);
				$cmd = "giftopnm"  if ($ext eq "gif");
				$cmd = "pngtopnm"  if ($ext eq "png");
				$cmd = "bmptopnm"  if ($ext eq "bmp");
				$cmd = "cat"       if ($ext eq "ppm");
	
				$cmd .= " $image ";
				$cmd .= " | pnmscale $multiplier " unless ($multiplier == 1);
				$cmd .= " | tee startimage_$$.ppm ";
			} else {
				$cmd = "cat startimage_$$.ppm ";
			}

			# the first crop

			push @frame_coords, { x => $this_x, y => $this_y, w => $this_w, h => $this_h ,
				boundary => (defined($keyframes{$frame_num})?1:0) 
#				boundary => (($fr==0 or $fr==$frames_to_create-1)?1:0) 
			};

			$cmd .= "| pamcut -pad -left $this_x -top $this_y -width $this_w -height $this_h ";

			push @anal_coords, [ $this_x, $this_y, $this_w, $this_h ];

			if ($this_w != $x_window or $this_h != $y_window) {
				# scale to window
				$cmd .= "| pnmscale -xsize=$x_window -ysize=$y_window ";
			}

			# write to file

			my $dstr = sprintf("%06d",$frame_num);

			my $this_file;
			if ($preview) {
				$this_file = sprintf("%s/frame$dstr.png", $dir);
			} else {
				$this_file = sprintf("%s/frame$dstr.tga", $dir);
			}
			$this_file =~ s|\\|/|g;
#			$cmd .= "| pnmpad -bottom 76 | ##CMD##  ppmtobmp -bpp=24 > $this_file";
#			$cmd .= "| ##CMD##  ppmtobmp -bpp=24 > $this_file";
			if ($preview) {
				$cmd .= "| ##CMD##  pnmtopng  > $this_file";
			}else {
				$cmd .= "| ##CMD##  ppmtotga -rgb -norle > $this_file";
			}
			add_to_listfile($this_file);

			# cue command

			if (($render || $frame_num == 0) && ((!$preview) or
			    ($preview && ($fr%25==0)))) {
				print "Generating frame $frame_num...\n";

				if ($movement eq "pause") {
					if ($prev_frame) {
						# just copy
						$cmd = "cp $prev_frame $this_file";
					} else {
						# blat CMD as everything is done
						$cmd =~ s/##CMD##//;
					}

				} elsif ($movement eq "fade") {
					if (@args != 2) {
						print "Usage: fade <dur> (<start>, <end>)\n";
						exit(1);
					}
					my ($start_alpha, $end_alpha) = @args;
					my $pos = $fr / $frames_to_create;

					# pos now 0 <-> 1

					my $this_alpha = ($start_alpha + (($end_alpha - $start_alpha) * $pos))/100;

					my $new_cmd = "ppmdim $this_alpha | ";

					$cmd =~ s~##CMD##~$new_cmd~;

				} else {
					$cmd =~ s/##CMD##//;
				}

				unless ($analyze) {
					my $ret = _system($cmd);
					if ($ret) {
						$ret /= 256;
						die ("cmd [$cmd] failed, returning $ret\n");
					}
				}

				if ($preview && $render) {
					my $frame_num_str = sprintf("%06d", $frame_num);
					print PREVIEW "<IMG SRC=\"frame$frame_num_str.png\"> &nbsp; \n";
				}
			}
			$prev_frame ||= $this_file;
			$frame_num++;
		}

######################
		
	} else {
		die "didn't recognise line [$script_line]\n";
	}
}
close(SCRIPT);
close(LISTFILE);

unless ($preview) {
	for (my $x=1; $x<= int($frame_num/5000)+1; $x++) {
		system("tga2avi.sh $dir/tgalist$x.lst");
	}
}

if ($preview) {
	unlink ("$dir/preview.mgk");
	# convert image to png
	my $c = "cat startimage_$$.ppm | ppmtobmp > $dir/preview.bmp";
	#$c =~ s/pans\//pans\\/;
	my $r = _system($c);
	unlink ("$dir/preview.mgk");
	if ($r) {
		die "First mogrify failed";
	}
	print PREVIEW "<IMG SRC=\"preview.bmp\"><p>\n";
	close(PREVIEW);

	# now do the rectangle thing

	my $last;
	foreach my $ref (@frame_coords) {

		if ((!defined $last) or 
			!($last->{x} == $ref->{x} && 
			  $last->{y} == $ref->{y} && 
			  $last->{w} == $ref->{w} && 
			  $last->{h} == $ref->{h})) {

			if ($ref->{boundary}) {

				push @lines, sprintf("brectangle %d,%d %d,%d", $ref->{x}, $ref->{y}, $ref->{x}+$ref->{w}, $ref->{y}+$ref->{h});	

			} else {

				push @lines, sprintf("point %d,%d", $ref->{x}, $ref->{y});
				push @lines, sprintf("point %d,%d", $ref->{x}+$ref->{w}, $ref->{y});
				push @lines, sprintf("point %d,%d", $ref->{x}, $ref->{y}+$ref->{h});
				push @lines, sprintf("point %d,%d", $ref->{x}+$ref->{w}, $ref->{y}+$ref->{h});

			}
		}
		

		$last->{x} = $ref->{x};
		$last->{y} = $ref->{y};
		$last->{w} = $ref->{w};
		$last->{h} = $ref->{h};

	}

	# got line coords, draw them

	my $line_list = "";
	my $max_line = 32000;
	my $current_fill = "none";
	my $counter = 0;
	my @rects = grep /^rectangle/, @lines;
	my @brects = grep /^brectangle/, @lines;
	my @points = grep /point/, @lines;
	my @dlines = grep /^line/, @lines;
	my @blines = grep /bline/, @lines;

	foreach my $list_ref (\@rects, \@points, \@dlines, \@blines, \@brects) {
		my ($stroke, $fill);
		next if (!defined($list_ref->[0]));
		if ($list_ref->[0] =~ /^rectangle/) {
			print "doing rectangles\n";
			$stroke = "-stroke \"#FFFF00\"";
			$fill = "";
		} elsif ($list_ref->[0] =~ /^brectangle/) {
			print "doing brectangles\n";
			$fill = "";
			$stroke = "-stroke \"#0000FF\"";
		} elsif ($list_ref->[0] =~ /^line/) {
			print "doing lines\n";
			$stroke = "";
			$fill = "-fill \"#FF0000\"";
		} elsif ($list_ref->[0] =~ /^bline/) {
			print "doing blines\n";
			$stroke = "";
			$fill = "-fill \"#00FF00\"";
		} else {
			print "doing points\n";
			$stroke = "";
			$fill = "-fill \"#FFFF00\"";
		}

		my $cmd = "mogrify $stroke $fill ";
		$counter = 0;

		foreach my $e (@{$list_ref}) {
			$e =~ s/bline/line/;
			$e =~ s/brectangle/rectangle/;

			$counter ++;
			if (length($cmd) > $max_line) {
				# run cmd
				$cmd .= "$dir/preview.bmp";
				print STDERR "\r" . ((scalar @{$list_ref}) - $counter) . " to go             ";
				my $r = _system $cmd;
				unlink ("$dir/preview.mgk");
				if ($r) {
					print "mogrify failed\n";
					exit(1);
				}
				$cmd = "mogrify $stroke $fill ";
			} else {
				if ($e =~ m/rectangle\s+(\d+)\D+(\d+)\D+(\d+)\D+(\d+)/) {
					my ($xa, $ya, $xb, $yb) = ($1, $2, $3, $4);
					$cmd .= "-draw \"line $xa, $ya, $xb, $ya\" ";  # top
					$cmd .= "-draw \"line $xa, $ya, $xa, $yb\" ";  # left

					$cmd .= "-draw \"line $xb, $ya, $xb, $yb\" ";  # right
					$cmd .= "-draw \"line $xa, $yb, $xb, $yb\" ";  # bottom
				} else {
					$cmd .= "-draw \"$e\" ";
				}
			}
		}
		unless ($cmd eq "mogrify $stroke $fill ") {
				# run cmd
				$cmd .= "$dir/preview.bmp";
				my $r = _system $cmd;
				unlink ("$dir/preview.mgk");
				if ($r) {
					print "mogrify failed\n";
					exit(1);
				}
		}

	}

} else {
	print "Generating AVI [$avi]...\n";
   if (0) {
	my $ret = system("bmp2avi -o $avi $avi_stem");
	if ($ret) {
		warn "bmp2avi failed!";
	}

	$ret = system("avi2mpg -n $avi");
	if ($ret) {
		warn "avi2mpg failed!";
	} else {
		# remove frame BMPs
		system("rm $dir/frame*.bmp");
	}
   }
}

if ($analyze) {
	my $framenum = 0;
	print "analysis\n";
	my $max_dist = 0;
	my @distrib = (1,0,0,0,0,0,0,0);
	foreach my $r (@anal_coords) {
		my ($x, $y, $w, $h) = @{$r};
		my $xc = $x + $w/2;
		my $yc = $y + $h/2;

		$r->[4] = $xc;
		$r->[5] = $yc;

		my ($dist, $diststr);
		if ($framenum == 0) {
			$diststr = "---------";
		} else {
			my $lxc = $anal_coords[$framenum-1][4];
			my $lyc = $anal_coords[$framenum-1][5];

			$dist = ( ($lxc - $xc) ** 2 + ($lyc - $yc) ** 2 ) ** .5;
			$dist *= ($x_window/$w);
			$max_dist = $dist if ($dist > $max_dist);
			$distrib[int($dist)] ++;
			$diststr = sprintf("%7.2f", $dist);
		}
		my $str = sprintf("%5d : %5d %5d | %5d %5d | %5d %5d | %s\n", $framenum, $x, $y, $w, $h, $xc, $yc, $diststr);
		print $str;
		$framenum++;
	}
	print "$framenum frames, max_dist $max_dist\n";
	for (my $d =0; $d < 8; $d++) {
		print "$d: $distrib[$d] ";
	}
	print "\n";
}

my $endtime = time;

my $duration = $endtime - $start_time;

my $mins = int($duration/60);
my $secs = $duration - $mins*60;

print "Operation took $mins:$secs\n";

exit(0);

END {
	unlink("startimage_$$.ppm");
}

