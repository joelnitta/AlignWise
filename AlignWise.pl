#! /home/nittaj/miniconda3/envs/eupoly2_capture/bin/perl

# Load perl modules #
use warnings;
use strict;
use Bio::SeqIO;
use Bio::AlignIO;
use Getopt::Long;
use Pod::Usage;
use File::Temp qw(tempdir);
use Cwd 'abs_path';
use Parallel::ForkManager;
use Fcntl qw/ :flock /;

Getopt::Long::Configure ("bundling");
my $dir = tempdir( CLEANUP => 1); #Temporary directory where blast output and alignment will be stored. This will be automatically deleted once the program finishes.

## Read in options and set variables
my $verbose = '';
my $isortho = '';
my $replace = '';
my $force = '';
my $man = 0;
my $help = 0;
my $pwd = abs_path($0);
$pwd =~ s/AlignWise\.pl$//;
my $protdb = $pwd . "/Blastdb/ens_min_prot";
my $refseq = $pwd . "/Blastdb/ens_min_cds";
my $maxgaps = 25;
my $minorthos = 4;
my $minpid = 20;
my $maxlen = 20;
my $threads = 1;
my $continue = '';
my $fast = '';
my $annot = '';
my $extend = '';
my $method = 'both';
## Parse options and print usage if there is a syntax error,
## or if usage was explicitly requested.
GetOptions('help|?|h' => \$help,
			'man|m' => \$man,
			'ortho|o' => \$isortho,
			'v' => sub {$verbose = 1},
			'verbose' => sub {$verbose = 2},
			'prot_db|p=s' => \$protdb,
			'nucl_db|n=s' => \$refseq,
			'replace_stops|r' => \$replace,
			'force|f' => \$force,
			'continue|c' => \$continue,
			'fast|a' => \$fast,
			'G=i' => \$maxgaps,
			'O=i' => \$minorthos,
			'I=i' => \$minpid,
			'L=i' => \$maxlen,
			'T=i' => \$threads,
			'extend|e' => \$extend,
			'method|M=s' => \$method,
			'save_blastx|x' => \$annot) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-verbose => 2) if $man;
 
## If no arguments were given, then allow STDIN to be used only
## if it's not connected to a terminal (otherwise print usage)
pod2usage("$0: No files given.")  if ((@ARGV == 0) && (-t STDIN));

pod2usage("** Invalid parameter provided **\n") if (($maxgaps < 0) || ($minorthos < 2) || ($minpid < 0) || ($maxlen < 0) || ($method ne 'both' && $method ne 'alignfs' && $method ne 'genewise'));

pod2usage("** Correctly formatted BLAST database cannot be located **\n") if ((!-e "$protdb.pin" || -z "$protdb.pin") || (!-e "$refseq.nin" || -z "$refseq.nin"));
	
my $file = $ARGV[0];
if (!-e $file || -z $file){
	pod2usage("** Input file does not exist **\n");
}
my $name = $file;
$name =~ s/\.f.+$//;
my $annotfile = $name . "_blastx.xml";
my $prot = $name . "_Awise_prot.fas";
my $orfout = $name . "_Awise_orf.fas";
my $logfile = $name . "_Awise_log.txt";
if ($method eq 'genewise'){
	$prot =~ s/Awise/gwise/;
	$orfout =~ s/Awise/gwise/;
	$logfile =~ s/Awise/gwise/;
}elsif ($method eq 'alignfs'){
	$prot =~ s/Awise_//;
	$orfout =~ s/Awise_//;
	$logfile =~ s/Awise_//;
}
	
my $lastone;
my $donehash;
if ($continue){ ## If file has already been semi-processed, find where it left off
	
	my $id = `tail -n 20 $orfout | grep ">" | head -n 1`;
	chomp $id;
	$id =~ s/ .*$//;
	$id =~ s/^>//;
	$lastone = $id;
	open(TMP, $orfout);
	while (my $line = <TMP>){
		chomp $line;
		if ($line =~ /^>/){
			my $id = $line;
			$id =~ s/ .*$//;
			$id =~ s/^>//;
			$donehash->{$id} = 1;
		}
	}
	close(TMP);
	
}else{ # remove outfiles with same name
	if (-e $prot){
		system("rm $prot $orfout");
	}
	if (-e $annotfile){
		system("rm $annotfile");
	}
	if (-e $logfile){
		system("rm $logfile");
	}
}

my $totcount = `grep -c ">" $file`;
my $counter = 0;
my $donecount = 0;

if ($isortho && $threads > 1){
	print "Only one sequence to process, so will not use multiple threads\n";
	$threads = 1;
}

if ($threads > 3){
	$threads = int($threads/2);
}elsif ($threads == 3){
	$threads = 2;
}

my $pm;
if ($threads > 1){ # Set up the parallel fork manager
	if ($verbose && $verbose == 1){
		print "Verbosity is not recommended while using threads, and so has been turned off. To force verbosity use '--verbose'.\n";
		$verbose = '';
	}
	if ($verbose && $verbose == 2){
		$verbose = 1;
	}
	$pm = Parallel::ForkManager->new($threads);

	$pm->run_on_finish(
    	sub { 
    		$donecount++;
    		my $per = int(($donecount/$totcount)*100);
			print "\rProgress: $per%" unless $verbose;
    	}
  	);
}

my $gotit = 0;
#Read in the sequences
my $inseq = Bio::SeqIO->new(-file => $file, -format => 'fasta');
while (my $ori = $inseq->next_seq){
	$counter++;
	
	if ($continue && $gotit == 0){
		if ($ori->display_id eq $lastone){
			$gotit++;
		}
		$donecount++;
		next;
	}
	if ($continue && $gotit > 0){
		if (exists $donehash->{$ori->display_id}){
			$donecount++;
			next;
		}
	}
	
	if ($isortho && $counter > 1){
		last;
	}
	
	print "Seq: " . $ori->display_id . "\n" if $verbose;
	
	if ($counter > 1000){
		$counter = 0;
	}
	
	if ($threads > 1){
		$pm->start and next; #start fork
	}
	
	runprog($ori,$counter); #This runs the whole program
	
	if ($threads > 1){
		$pm->finish; # end fork
	}
	
	if (!$isortho && $threads == 1){
		$donecount++;
		my $per = int(($donecount/$totcount)*100);
		print "\rProgress: $per%" unless $verbose;
	}
}

if ($threads > 1){
	$pm->wait_all_children;
}

print "\n" unless $verbose;

exit;

## Subroutines ##

sub runprog {
	my $ori = $_[0];
	my $c = $_[1];
	
	# Create temporary files
	my $seqtmp = $dir . "/" . $c . "blasttmp.fa";
	my $outxtmp = $dir . "/" . $c . "blastxoutmp.txt";
	
	my $log = $ori->display_id;
		
	# Print sequence to file
	open (TMP, ">$seqtmp");
	print TMP ">" . $ori->display_id . "\n";
	print TMP $ori->seq . "\n";
	close(TMP);
	
	# Run BLASTx
	my $add = ' ';
	if ($fast){
		$add = '-word_size 4 -threshold 20';
	}
	if ($threads > 2){
		$add .= ' -num_threads 2';
	}
	
	my $blast = "blastx -db $protdb -query $seqtmp -out $outxtmp -outfmt '6 std qframe qseq sseq' -max_target_seqs 1 $add";
	if ($annot){
		$blast = "blastx -db $protdb -query $seqtmp -out $outxtmp -outfmt 5 $add";
	}
	print "Running BLASTx\n" if $verbose;
	system($blast);
	
	# Process results
	my @res;
	if ($annot){
		@res = process_xml($outxtmp);
	}else{
		@res = process_tab($outxtmp);
	}
		
	my $sta = $res[0];
	my $end = $res[1];
	my $fail = $res[3];
	
	if ($end == 0 || $fail > 0){
		print "No BLASTX hits\n" if $verbose;
		$log .= "\tNo BLASTx hits";
		writelog($log);
		return;
	}

	print "Protein coding region: $sta - $end\n" if $verbose && $verbose==2;
	
#	if ($genewise){
#		genewise($ori,$c,$res[5]);
#	}else{
#		original(\@res,$c,$ori);
#	}
	compare_res(\@res,$c,$ori);
	
}

sub original {
	my @res = @{$_[0]};
	my $c = $_[1];
	my $ori = $_[2];
	
	my $sta = $res[0];
	my $end = $res[1];
	my $neg = $res[2];
	my $fail = $res[3];
	my $hsp = $res[4];

	my $f;
	if ($force && $hsp == 1){
		print "Only one HSP so will not use -f option\n" if $verbose;
	}elsif ($force){
		$f = 1;
	}
	
	my $newfile = $dir .  "/" . $c . "_seq.fas";
	my $seqtmp = $dir . "/" . $c . "blasttmp.fa";
	my $outxtmp = $dir . "/" . $c . "blastxoutmp.txt";
	my $outntmp = $dir . "/" . $c . "blastnoutmp.txt";
	my $aln = $dir . "/" . $c . "_aln.fas";
	
	if ($isortho){
		$newfile = $file;
	}
	
	if (!$isortho){
		getorthos($ori,$seqtmp,$outntmp,$newfile); #Runs BLASTn
		
		my $seqcount = `grep -c ">" $newfile`;
		if ($seqcount < $minorthos){
			print "Not enough orthologous sequences\n" if $verbose;
			my @fres = justprot($ori,$c);
			return(\@fres,"top HSP used; not enough orthologs found");
		}
	}else{
		my $seqcount = `grep -c ">" $file`;
		if ($seqcount < $minorthos){
			print "Not enough sequences, did you mean to use -o option?\n";
			return;
		}
	}
	
	# Create alignment
	if (-e $aln){
		system("rm $aln");
	}
	print "Building alignment\n" if $verbose;
	
	system("muscle -in $newfile -out $aln -quiet -maxhours 0.5");
	if (!-e $aln){
		print "MUSCLE failed\n" if $verbose;
		my @fres = justprot($ori,$c);
		return(\@fres,"top HSP used; MUSCLE failed");
	}
		
	my $alnsta = $sta;
	my $alnend = $end;
	
	my $tmp = $ori;
	my @seqs;
	my $gaps = 0;
	my %gaphash;
	my $gaphash;
	my @gaparray;
	my $aseq;
	my $log;
	
	#Locate BLASTx region within alignment
	my $alnin = Bio::AlignIO->new(-file => $aln, -format => 'fasta');
	while (my $a = $alnin->next_aln){
		foreach my $s ($a->each_seq){
			if ($s->display_id eq $ori->display_id){
				$aseq = $s;
				my @chars = split //, $s->seq;
				my $pos = 0;
				my $count = 0;
				my $gotsta = 0;
				foreach my $e (@chars){
					$pos++;
					if ($e ne '-'){
						$count++;
					}
					if ($count == $alnsta && $gotsta == 0){
						$alnsta = $pos;
						$gotsta++;
					}
					if ($count == $alnend){
						$alnend = $pos;
						last;
					}
				}
			}
		}
		
		# Truncate to that region
		my $trunc = $a->slice($alnsta,$alnend);
		
		## truncate to new region if all homologs begin with ---ATG
		my $seqstart;
		my $go = 0;
		my $t = 0;
		foreach my $s ($trunc->each_seq){
			if ($s->display_id ne $ori->display_id){
				$t = length($s->seq);
				if (!$seqstart){
					if ($s->seq =~ /^(-+ATG)/){
						$seqstart = $1;
						$go++;
					}else{
						$seqstart = "O";
					}
				}else{
					if ($s->seq =~ /^$seqstart/){
						$go++;
					}
				}
			}
		}
		if ($go == $minorthos-1){
			print "Alignment starts with just gaps and ATG, will trim this region off\n" if $verbose && $verbose==2;
			my $n = length($seqstart)-3;
			$alnsta += $n;
			$trunc = $a->slice($alnsta,$alnend);
		}
		
		
		print "%Identity: "  . $trunc->overall_percentage_identity . "\n" if $verbose && $verbose==2;
		if (!$f && $trunc->overall_percentage_identity < $minpid){
			print "Alignment has less than $minpid% overall identity\n" if $verbose;
			$log = "top HSP used; Alignment <$minpid% overall identity";
			$fail++;
			last;
		}
		# Locate gaps which are not divisible by 3
		foreach my $seq ($trunc->each_seq){
			print ">" . $seq->display_id . "\n" . $seq->seq . "\n" if $verbose && $verbose==2;
			my $str = $seq->seq;
			my @chars = split //, $str;
			my $pos = 0;
			my $gapstart = 0;
			my $gapend = 0;
			my $ingap = 0;
			my $g = grep /-/, @chars;
			print "Percent gaps: " . ($g/@chars)*100 . "\n" if $verbose && $verbose==2;
			if (!$f && ($g/@chars)*100 > $maxgaps){
				print "More than $maxgaps% gaps\n" if $verbose;
				$log = "top HSP used; Alignment has more than $maxgaps% gaps";
				$fail++;
				last;
			}
			foreach my $base (@chars){
				$pos++;
				if ($base eq '-'){
					if ($ingap == 0){
						$gapstart = $pos;
					}
					$ingap++;
				}else{
					if ($ingap > 0){
						$gapend = $pos;
						if (($gapend-$gapstart)%3 != 0){
							$gaps++;
							if (!exists($gaphash->{$gapstart})){
								push(@gaparray, $gapstart);
							}else{
								if ($gaphash->{$gapstart}->{'len'} != $gapend-$gapstart){
									print "Inconsistent gap\n" if $verbose && $verbose==2;
									my $x = grep {$gaparray[$_] == $gapstart} 0..$#gaparray;
									splice(@gaparray,$x,1);
								}
							}
							$gaphash->{$gapstart}->{'len'} = $gapend-$gapstart;
							$gaphash->{$gapstart}->{'id'}->{$seq->display_id}++;
						}
					}
					$ingap = 0;
				}
			}
		}
	}
	if ($fail > 0){
		my @fres = justprot($ori,$c);
		return(\@fres,$log);
	}
	if ($gaps == 0 ){
		print "No gaps found!\n" if $verbose;
		$log = "No gaps in alignment";
		my $reg = $tmp->trunc($sta,$end);
		push(@seqs, $reg->seq);
	}else{
		# Process gaps
		print "Have gaps which require processing\n" if $verbose;
		@gaparray = sort {$a<=>$b} @gaparray;
		GAPLOOP:{
		$log = ();
		my $a = 0;
		if (@gaparray == 0){
			print "No gaps found!\n" if $verbose && $verbose==2;
			$log = "No consistent gaps in alignment";
			my $reg = $tmp->trunc($sta,$end);
			push(@seqs, $reg->seq);
		}			
		foreach my $p (@gaparray){ # For each gap...
			print "Gap: " . $p . "\n" if $verbose && $verbose==2;
			my $gsta = $alnsta;
			my $gend = $alnend;
			my $len = $gaphash->{$p}->{'len'};
			my $hit = 0;
			my $inq = 0;
			foreach my $i (keys %{$gaphash->{$p}->{'id'}}){ # Which sequences was the gap present in? 
				$hit++;
				if ($i eq $ori->display_id){
					$inq++;
				}
			}
			# If the gap is inconsistent between sequences, or right at the start of the BLASTx region it is skipped.
			if (($inq == 0 && $hit < 3) || $p < 3 || ($hit > 1 && $inq > 0) || ($gaparray[$a+1] && ($gaparray[$a+1]-($p+$len) < 3))){
				print "Gap not consistent in all orthologs, or located at the start of the HSP. Will skip this gap\n" if $verbose && $verbose==2;
				splice(@gaparray,$a,1);
				@seqs = ();
				redo GAPLOOP;
			}
			if (!$f && $len > $maxlen){
				print "Gap longer than $maxlen\n" if $verbose;
				if ($hsp == 1 || $p < 50 || @seqs == 0){ # If the longest gap is close to the front of the BLASTx region, or there is only 1 HSP then we use the top HSP seq.
					$log = "top HSP used; gap is longer than $maxlen";
					$fail++;
				}else{
					$log .= " ORF ended at gap longer than " . $maxlen . "bp";
				}
				last; # Otherwise just end the ORF here
			}
			my $ne = $gaparray[$a+1];
			if ($ne){ # Next gap 
				print "Next gap: $ne\t" if $verbose && $verbose==2;
				my $mid = int(($ne+$len-$p)/2);
				print "Mid point: $mid\n" if $verbose && $verbose==2;
				$gend = $alnsta+$p+$mid;
			}
			my $pe = $gaparray[$a-1];
			if ($a > 0){ # Previous gap
				my $plen = $gaphash->{$pe}->{'len'};
				print "Previous gap: $pe\t" if $verbose && $verbose==2;
				my $mid = int(($p+$plen-$pe)/2);
				print "Mid point: $mid\n" if $verbose && $verbose==2;
				$gsta = $alnsta+$pe+$mid+1;
			}
			print "Looking from $gsta to $gend\n" if $verbose && $verbose==2;
			if ($len > 4){ # Long gaps are split into two ends, each of which is processed seperately.
				print "Gap longer than 4bp, will process each end individually\n"  if $verbose && $verbose==2;
				my $alnin = Bio::AlignIO->new(-file => $aln, -format => 'fasta');
				while (my $aln = $alnin->next_aln){
					my $trunc = $aln->slice($alnsta,$alnend);
					foreach my $seq ($aln->each_seq){
						if ($seq->display_id ne $ori->display_id){
							print ">" . $seq->display_id . "\n" if $verbose && $verbose==2;
							my @chars = split //, $seq->seq;
							my $pos = 0;
							my $count = 0;
							my $gogo =0;
							my $rem1;
							my $rem2;
							foreach my $c (@chars){
								$pos++;
								if ($c ne '-'){
									$count++;
								}
								if ($pos == $gsta){
									$gogo++
								}
								if ($gogo > 0){
									print " $c" if $verbose && $verbose==2;
									if ($count == 3){
										print " |" if $verbose && $verbose==2;
									}
								}
								if ($pos == $p+$alnsta-2){
									print "*" if $verbose && $verbose==2;
									$rem1 = 3-$count;
								}
								if ($pos == $p+$alnsta+$len-2){
									print "*" if $verbose && $verbose==2;
									$rem2 = 3-$count;
								}
								if ($pos == $gend){
									$gogo = 0;
								}
								if ($count == 3){
									$count = 0;
								}
							}
							print "\n" if $verbose && $verbose==2;
							print "Start: $rem1\tEnd: $rem2\n" if $verbose && $verbose==2;
							if ($rem2 > 0){ # The end of the long gap is out of frame, so we treat it as a new gap.
								my $r;
								if ($rem2 == 2 || $rem2 == 3){
									$r = 1;
								}elsif ($rem2 == 1){
									$r = 2;
								}
								print "Adding in new gap, change of $r\n" if $verbose && $verbose==2;
								my $newp = $p+$len-$r;
								print "New gap:$newp\n" if $verbose && $verbose==2;
								splice(@gaparray,$a+1,0,"$newp");
								$gaphash->{$newp}->{'len'}=$r;
								foreach my $i (keys %{$gaphash->{$p}->{'id'}}){
									$gaphash->{$newp}->{'id'}->{$i}++;
								}
							}
							$len = $rem1;
							$gaphash->{$p}->{'len'} = $rem1;
							my $ne = $gaparray[$a+1];
							if ($ne){
								print "Next gap: $ne\t" if $verbose && $verbose==2;
								my $mid = int(($ne+$len-$p)/2);
								print "Mid point: $mid\n" if $verbose && $verbose==2;
								$gend = $alnsta+$p+$mid;
							}							
							last;
						}
					}
				}
				print "Now looking from $gsta to $gend\n" if $verbose && $verbose==2;
			}
			if ($len == 4){ #Gaps which are 4 bases long are considered as 1+3
				print "Gap is 4 bases long. Will reset to 1\n" if $verbose && $verbose==2;
				$len = 1;
			}
			my $reg = $aseq->trunc($gsta,$gend);
			my $str = $reg->seq;
			print "Original:\t" . $str . "\n" if $verbose && $verbose==2;
			my $dif = $gsta-$alnsta;
			my $gap = $p-$dif;
			if ($inq == 0){ # Gap was not in EST, so need to remove bases
				print "Need to remove $len bases\n" if $verbose && $verbose==2;
				print "Process:\t" . substr($str,0,$gap-1) if $verbose && $verbose==2;
				print " Gap starts " if $verbose && $verbose==2;
				print substr($str,$gap-1,$len) if $verbose && $verbose==2;
				print " Gap Ends " if $verbose && $verbose==2;
				print substr($str,$gap+$len-1,$gend) if $verbose && $verbose==2;
				print "\n" if $verbose && $verbose==2;
				my $newstr = substr($str,0,$gap-1) . substr($str,$gap+$len-1,$gend);
				print "Result:  \t" . $newstr . "\n" if $verbose && $verbose==2;
				push(@seqs, $newstr);
				if ($len > 0){
					$log .= " -$len";
				}
			}else{ # Gap was in EST, need to add bases
				print "Need to add $len bases\n" if $verbose && $verbose==2;
				print "Process:\t" . substr($str,0,$gap-1) if $verbose && $verbose==2;
				print " Gap starts " if $verbose && $verbose==2;
				my $insert = "N"x$len;
				print $insert if $verbose && $verbose==2;
				print " Gap Ends " if $verbose && $verbose==2;
				print substr($str,$gap+$len-1,$gend) if $verbose && $verbose==2;
				print "\n" if $verbose && $verbose==2;
				my $newstr = substr($str,0,$gap-1) . $insert . substr($str,$gap+$len-1,$gend);
				print "Result:  \t" . $newstr . "\n" if $verbose && $verbose==2;
				push(@seqs, $newstr);
				if ($len > 0){
					$log .= " +$len";
				}
			}
			print "\n" if $verbose && $verbose==2;
			$a++;
		}
		} #end of GAPLOOP
		if ($fail > 0){
			my @fres = justprot($ori,$c);
			return(\@fres,$log);
		}
	}
	
	my $orf = "@seqs";
	$orf =~ s/\s+//g;
	$orf =~ s/-//g;
	
	LOOP: { # Checks the length of the ORF is divisible by three.
		if (length($orf)%3 != 0){
			print "ORF not divisible by three!\n" if $verbose;
			print "Length: " . length($orf) . "\n" if $verbose && $verbose==2;
			$orf =~ s/.$//;
			redo LOOP;
		}
	}
	
	my @fres = printseq($orf,$neg,$ori,$c);
	return(\@fres,$log); # Prints the sequence
	
}

sub genewise {
	my $ori = $_[0];
	my $c = $_[1];
	my $hid = $_[2];
	
	$hid =~ s/^ref\|//;
	$hid =~ s/\|$//;
	
	my $newfile = $dir .  "/" . $c . "_seq.fas";
	my $aln = $dir . "/" . $c . "_aln.fas";
	my $newfile2 = $dir . "/" . $c . "_seq2.fas";
	
	print "Running Genewise\n" if $verbose;
	
	system("blastdbcmd -entry $hid -db $protdb > $newfile2");
	
	open(OUT, ">$newfile");
	print OUT ">" . $ori->display_id . "\n";
	print OUT $ori->seq . "\n";
	close(OUT);
	
	system("genewise $newfile2 $newfile -alg 333 -cdna -sum -both -silent > $aln");
	
	if (! -e $aln){
		print "Genewise failed\n" if $verbose;
		my @fres = justprot($ori,$c);
		return(\@fres,"top HSP used; Genewise failed");
	}
	
	open(IN, $aln);
	my $sep = 0;
	my $regs;
	my $gogo = 0;
	while (<IN>){
		chomp;
		if (/^\/\//){
			$sep++;
			@{$regs->{$sep}->{'s'}} = ();
			$gogo =0;
		}
		if (/^>/){
			$gogo++;
		}elsif ($gogo > 0){
			push(@{$regs->{$sep}->{'s'}},$_);
		}
		if (/^\d/){
			my @data = split /\s+/;
			$regs->{$sep+1}->{'i'} = $data[7];
		}
	}
	
	$gogo = 0;
	
	my $longest;
	my $long = 0;
	my $log;
	
	foreach my $sep (sort {$a<=>$b} keys %{$regs}){
		my @seqs = @{$regs->{$sep}->{'s'}};
		if (!@seqs){
			next;
		}
		$gogo++;
		
		my $orf = "@seqs";
		$orf =~ s/\s+//g;
		$orf =~ s/-//g;
		
		LOOP: { # Checks the length of the ORF is divisible by three.
			if (length($orf)%3 != 0){
				print "ORF not divisible by three!\n" if $verbose;
				print "Length: " . length($orf) . "\n" if $verbose && $verbose==2;
				$orf =~ s/.$//;
				redo LOOP;
			}
		}
		
		if (length($orf) > $long){
			$long = length($orf);
			$longest = $orf;
			if (exists $regs->{$sep}->{'i'}){
				$log = $regs->{$sep}->{'i'};
			}
		}
	}
	
	if ($log){
		$log = "-$log";
	}else{
		$log = "no gaps in alignment";
	}
	
	my @fres = printseq($longest,0,$ori,$c);
	return(\@fres,$log); # Prints the sequence
	
}

sub compare_res { # Compare output from AlignFS and Genewise
	my @res = @{$_[0]};
	my $c = $_[1];
	my $ori = $_[2];
	
	my $log = $ori->display_id;
	
	my @aout;
	my @AlignFS;
	my @gout;
	my @genewise;
	
	if ($method ne 'genewise'){	
		@aout = original(\@res,$c,$ori);
		@AlignFS = @{$aout[0]};
	}
	if ($method ne 'alignfs'){
		@gout = genewise($ori,$c,$res[5]);
		@genewise = @{$gout[0]};
	}
	
	if ($method eq 'alignfs'){
		final_print($AlignFS[0],$ori);
		writelog($log . "\tAlignFS\t" . $aout[1]);
		return;
	}
	if ($method eq 'genewise'){
		final_print($genewise[0],$ori);
		writelog($log . "\tGenewise\t" . $gout[1]);
		return;
	}
	
	if (!$aout[0] && !$gout[0]){
		print "Neither program found an ORF\n" if $verbose;
		return;
	}elsif (!$aout[0]){
		print "AlignFS didn't find an ORF\n" if $verbose;
		final_print($genewise[0],$ori);
		writelog($log . "\tGenewise\t" . $gout[1]);
		return;
	}elsif (!$gout[0]){
		print "Genewise didn't find an ORF\n" if $verbose;
		final_print($AlignFS[0],$ori);
		writelog($log . "\tAlignFS\t" . $aout[1]);
		return;
	}
	
	print "AlignFS log: $aout[1]\nGenewise log: $gout[1]\n" if $verbose && $verbose == 2;
	
	print "Genewise:\n$genewise[1]\nAlignFS:\n$AlignFS[1]\n" if $verbose && $verbose == 2;
	
	my $tmp = $AlignFS[1];
	$tmp =~ s/X//;
	
	if ($AlignFS[1] eq $genewise[1] || $tmp eq $genewise[1]){
		print "AlignFS and Genewise proteins are identical\n" if $verbose;
		final_print($AlignFS[0],$ori);
		writelog($log . "\tIdentical\tAlignFS:" . $aout[1]);
		return;
	}
	
	my $best;
	
	my @ares = b2seq($AlignFS[1],$c);
	my @gres = b2seq($genewise[1],$c);
	
	if ($ares[0] == 0 && $gres[0] == 0){
		print "Neither have a BLASTP result!\n" if $verbose;
		writelog($log . "\tNeither have BLASTP result");
		return;
	}elsif ($ares[0] == 0){
		print "AlignFS result does not have BLASTP result\n" if $verbose;
		final_print($genewise[0],$ori);
		writelog($log . "\tGenewise\t" . $gout[1]);
	}elsif ($gres[0] == 0){
		print "Genewise result does not have BLASTP result\n" if $verbose;
		final_print($AlignFS[0],$ori);
		writelog($log . "\tAlignFS\t" . $aout[1]);
	}elsif ($ares[2] > 0 && $gres[2] == 0){
		print "AlignFS is longer than BLASTP alignment, will use genewise\n" if $verbose;
		final_print($genewise[0],$ori);
		writelog($log . "\tGenewise\t" . $gout[1]);
	}elsif ($gres[2] > 0 && $ares[2] == 0){
		print "Genewise is longer than BLASTP alignment, will use AlignFS\n" if $verbose;
		final_print($AlignFS[0],$ori);
		writelog($log . "\tAlignFS\t" . $aout[1]);
	}else{
		if ($gres[2] > 0 && $ares[2] > 0){
			print "Both alignments are shorter than proteins output\n" if $verbose;
		}
		if ($ares[0] > $gres[0]){
			print "AlignFS has biggest %identity by length\n" if $verbose;
			final_print($AlignFS[0],$ori);
			writelog($log . "\tAlignFS\t" . $aout[1]);
		}elsif($gres[0] > $ares[0]){
			print "Genewise has better %identity by length\n" if $verbose;
			final_print($genewise[0],$ori);
		 	writelog($log . "\tGenewise\t" . $gout[1]);
		}else{
			print "Equal %identity by length\n" if $verbose;
			final_print($AlignFS[0],$ori);
			writelog($log . "\tEqual %identity\tAlignFS:" . $aout[1]);
		}
	}		
}


sub b2seq { #BLAST2Seq to find best protein
	my $seq = $_[0];
	my $c = $_[1];
	
	my $btmp = $dir . "/" . $c . "tmp.fa";
	open(TMP, ">$btmp");
	print TMP ">Query\n";
	print TMP $seq . "\n";
	close(TMP);
	
	my $btmp2 = $dir . "/" . $c . "tmp2.txt";
	
	my $newfile2 = $dir . "/" . $c . "_seq2.fas";
	
	my $blast = "blastp -query $btmp -subject $newfile2 -out $btmp2 -outfmt 6 -max_target_seqs 1";
	system($blast);

	my $res = `grep -e "^Query" $btmp2 | head -n 1`;
	chomp $res;
	my @data = split /\t/, $res;
	print "@data\n" if $verbose && $verbose == 2;
	if (! $data[10]){
		return (0,0);
	}
	my $fail = 0;
	if ($data[7] - $data[6] + 1 < length($seq)-5){
		$fail++;
	}
	my $newid = $data[2] * (($data[7] - $data[6] + 1)/length($seq));
	
	my $newmis = $data[4]/$data[3]*100;
	#print "Mismatches: $data[4]\nOver length: $data[3]\nEquals: $newmis\n";
	
	return ($newid,$data[11],$fail,$data[2]);
	
}


sub getorthos { # Run BLASTn and process results, pulling back homologous sequences
	my $ori = $_[0];
	my $seqtmp = $_[1];
	my $outntmp = $_[2];
	my $newfile = $_[3];
	
	my $add = ' ';
	if ($threads > 2){
		$add = "-num_threads 2";
	}
	
	my $blastn = "blastn -task blastn -db $refseq -query $seqtmp -out $outntmp -outfmt '6 std hspnum' -max_target_seqs " . ($minorthos-1) . " $add ";
	print "Running BLASTn\n" if $verbose;
	system($blastn);
	
	open(OUT, ">$newfile");
	print OUT ">" . $ori->display_id . "\n";
	print OUT $ori->seq . "\n";
	close(OUT);
	
	my @hits;
	open (IN, "$outntmp");
	while (my $line = <IN>){
		chomp $line;
		my @data = split /\t/, $line;
		if ($data[10] < 1e-10){
			$data[1] =~ s/^\w+\|//;
			$data[1] =~ s/\|$//;
			if (!grep/$data[1]/,@hits){
				push (@hits, $data[1]);
				my $getseq;
				if ($data[8] > $data[9]){
					$getseq = "blastdbcmd -entry $data[1] -strand minus -db $refseq >> $newfile";
				}else{
					$getseq = "blastdbcmd -entry $data[1] -strand plus -db $refseq >> $newfile";
				}
				system($getseq);
			}
		}
	}
	close(IN);
}


sub process_xml{ # Process BLASTx results in XML format
	my $outxtmp = $_[0];
	
	my $hid;
	my $sta = 999999999999999;
	my $end = 0;
	my $hsp = 0;
	my $last;
	my $fail = 0;
	my $neg = 0;
	
	my $s;
	my $e;
	
	open (OUT, "$outxtmp");
	while (my $line = <OUT>){
		chomp $line;
		$line =~ s/^\s+//;
		if ($line =~ /^<Hsp>/){
			$hsp++;
		}
		if ($line =~ /^<Hsp_evalue>/){
			$line =~ s/^<Hsp_evalue>//;
			$line =~ s/<\/Hsp_evalue>$//;
			if ($line > 1e-03){
				last;
			}
		}
		if ($line =~ /^<Hsp_query-frame>/){
			$line =~ s/^<Hsp_query-frame>//;
			$line =~ s/<\/Hsp_query-frame>//;
			if ($hsp == 1){
				$last = $line;
			}else{
				#If hit has hsps in different strands, skip this sequence
				if (($last > 0 && $line < 0) || ($last < 0 && $line > 0)){
					$fail++;
				}
			}
			if ($line < 0){
				$neg++;
			}
		}
		if ($line =~ /^<Hsp_query-from>/){
			$line =~ s/^<Hsp_query-from>//;
			$line =~ s/<\/Hsp_query-from>$//;
			if ($line < $sta){
				$sta = $line;
			}
		}
		if ($line =~ /^<Hsp_query-to>/){
			$line =~ s/^<Hsp_query-to>//;
			$line =~ s/<\/Hsp_query-to>$//;
			if ($line > $end){
				$end = $line;
			}
		}
		if ($line =~ /^<Hit_accession>/){
			$line =~ s/^<Hit_accession>//;
			$line =~ s/<\/Hit_accession>//;
			$hid = $line;
		}
		if ($line =~ /^<\/Hit>/){
			last;
		}
	}
	close(OUT);
	
	return ($sta,$end,$neg,$fail,$hsp,$hid);
}

sub process_tab { # Process BLASTx results in tabular format
	my $outxtmp = $_[0];
	
	my $hid;
	my $sta = 999999999999999;
	my $end = 0;
	my $hsp = 0;
	my $last;
	my $fail = 0;
	my $neg = 0;
	
	open (OUT, "$outxtmp");
	while (my $line = <OUT>){
		chomp $line;
		my @data = split /\t/, $line;
		if ($data[10] > 1e-03){
			last;
		}
		#print $data[10] . "\n";
		$hsp++;
		$hid = $data[1];
		my $qstr = $data[12];
		#print $qstr . "\n";
		if ($hsp == 1){
			$last = $data[12];
		}else{
			#If hit has hsps in different strands, skip this sequence
			if (($last > 0 && $data[12] < 0) || ($last < 0 && $data[12] > 0)){
				$fail++;
			}
		}
		if ($data[12] < 0){
			#print "revcom\n";
			$neg++;
		}
		my $s = $data[6];
		my $e = $data[7];
		if ($e < $s){
			$s = $data[7];
			$e = $data[6];
		}
		if ($s < $sta){
			$sta = $s;
		}
		if ($e > $end){
			$end = $e;
		}
		if ($verbose && $verbose == 2){
			print "Hit: $hid\tHsp: $hsp\tStart: $s\tEnd: $e\tEvalue: $data[10]\tStrand: $qstr\n";
		}
	}
	close(OUT);
	
	return ($sta,$end,$neg,$fail,$hsp,$hid);
}

sub justprot{ # Take the top HSP sequence
	my $ori = $_[0];
	my $c = $_[1];
	my $outxtmp = $dir . "/" . $c . "blastxoutmp.txt";
	print "Will just use top HSP\n" if $verbose;
	#Just use top protein HSP to find ORF
	my $s;
	my $e;
	open(TMP, $outxtmp);
	if ($annot){ #XML format
		while (my $line = <TMP>){
			chomp $line;
			$line =~ s/^\s+//;
			if ($line =~ /^<Hsp_query-from>/){
				$line =~ s/^<Hsp_query-from>//;
				$line =~ s/<\/Hsp_query-from>$//;
				$s = $line;
			}
			if ($line =~ /^<Hsp_query-to>/){
				$line =~ s/^<Hsp_query-to>//;
				$line =~ s/<\/Hsp_query-to>$//;
				$e = $line;
			}
			if ($line =~ /^<Hsp_query-frame>/){
				$line =~ s/^<Hsp_query-frame>//;
				$line =~ s/<\/Hsp_query-frame>$//;
				if ($line < 0){
					my $tmp = $s;
					$s = $e;
					$e = $tmp;
				}
			}
			if ($line =~ /^<\/Hsp>/){
				last;
			}
		}
	}else{ #Tabular format
		while (my $line = <TMP>){
			chomp $line;
			my @data = split /\t/, $line;
			$s = $data[6];
			$e = $data[7];
			last;
		}
	}
	close(TMP);
	
	if (!$e || !$s){
		return;
	}
	
	my $seq;
	if ($e < $s){
		$seq = $ori->trunc($e,$s);
		$seq = $seq->revcom();
	}else{
		$seq = $ori->trunc($s,$e);
	}
	
	#my @res = printseq($seq->seq,0,$ori,$c);
	return printseq($seq->seq,0,$ori,$c);
}

sub printseq { #Get final sequences
	my $orf = $_[0];
	my $ori = $_[2];
	my $c = $_[3];
	my $sep = $_[4];
			
	my $seqobj2 = Bio::Seq->new(-seq => $orf);
	if ($_[1] > 0){ # Reverse compliment sequence ORF on reverse strand
		$seqobj2 = $seqobj2->revcom;
		$orf = $seqobj2->seq;
	}
	$seqobj2 = $seqobj2->translate;
	
	if ($replace){ # Replace STOP codons with 'A' and 'NNN'
		$orf = replace($orf);
		$seqobj2 = Bio::Seq->new(-seq => $orf);
		$seqobj2 = $seqobj2->translate;
	}
	
	if ($extend){ # Extend ORF to nearest ATG and STOP
		$orf = extend_seq($orf,$ori);
		$seqobj2 = Bio::Seq->new(-seq => $orf);
		$seqobj2 = $seqobj2->translate;
	}
	
	if ($annot){ # Save XML files
		cat_annot($c);
	}
	return($orf,$seqobj2->seq,$sep);
}

sub final_print{ #Print sequences to outfiles
	my $orf = $_[0];
	my $ori = $_[1];
	my $sep = $_[2];
	
	my $seqobj2 = Bio::Seq->new(-seq => $orf);
	$seqobj2 = $seqobj2->translate;
	
	print "ORF\n" . $orf . "\n" if $verbose;
	print "PROT\n" . $seqobj2->seq . "\n" if $verbose;
	
	# Print sequences to outfiles safely
	open(ORF, ">>$orfout");
	if ($threads > 1){
		flock ORF, LOCK_EX;
	}
	print ORF ">" . $ori->display_id;
	if ($sep){
		print ORF "_" . $sep;
	}
	print ORF " ORF\n";
	print ORF $orf . "\n";
	close(ORF);
	
	open(PROT, ">>$prot");
	if ($threads > 1){
		flock PROT, LOCK_EX;
	}
	print PROT ">" . $ori->display_id;
	if ($sep){
		print PROT "_" . $sep;
	}
	print PROT " PROT\n";
	print PROT $seqobj2->seq . "\n";
	close(PROT);
}

sub cat_annot{ #Print XML files out safely
	my $c = $_[0];
	my $outxtmp = $dir . "/" . $c . "blastxoutmp.txt";
	
	
	open(ANNOT, ">>$annotfile");
	open(IN, $outxtmp);
	if ($threads){
		flock ANNOT, LOCK_EX;
	}
	while (<IN>){
		print ANNOT;
	}
	print ANNOT "\n";
	close(ANNOT);
	close(IN);
}

sub writelog{
	my $log = $_[0];
	open(OUT, ">>$logfile");
	if ($threads){
		flock OUT, LOCK_EX;
	}
	print OUT $log . "\n";
	close(OUT);
}

sub replace { # Replace STOP codons.
	my $orf = $_[0];
	print "Replacing any STOP codons\n" if $verbose;
	my @chars;
	for (my $a = 0;$a <= length($orf); $a+=3){
		my $sub = substr($orf, $a, 3);
		if ($sub eq 'TAA' || $sub eq 'TAG' || $sub eq 'TGA'){
			$sub = 'NNN';
		}
		push (@chars, $sub);
	}
	my $str = join ("", @chars);
	return $str;
}

sub extend_seq{ #Extend ORF to nearest ATG and STOP codons
	my $orf = $_[0];
	my $ori = $_[1]->seq;
	
	my @new;
	
	if (substr($orf,0,3) ne 'ATG' && $ori =~ /^(\w+)$orf/){
		my $max = length($1);
		my @keep;
		while ($max > 0){
			my $cod = substr($1,$max-3,3);
			unshift(@keep,$cod);
			if ($cod eq 'ATG'){
				last;
			}
			$max -= 3;
		}
		if ($max > 0){
			print "Extending 5 prime\n" if $verbose;
			push(@new,join("",@keep));
		}
	}
	push(@new,$orf);
	if ($ori =~ /$orf(\w+)$/){
		my $pos = 0;
		my @keep;
		while ($pos < length($1)){
			my $cod = substr($1,$pos,3);
			if ($cod eq 'TAA' || $cod eq 'TAG' || $cod eq 'TGA'){
				last;
			}
			push(@keep,$cod);
			$pos += 3;
		}
		if ($pos < length($1)){
			print "Extending 3 prime\n" if $verbose;
			push(@new,join("",@keep));
		}
	}
	return join("",@new);
}
	
	


__END__
 
=head1 NAME
 
EST Translate - Identify the ORF in EST sequences while correcting for frame shifts
 
=head1 SYNOPSIS
 
AlignWise.pl [options] [FASTA file]
 
 Options:
  -M [--method]        method, 'alignfs' or 'genewise'. Default: 'both'
  -o [--ortho]         input file contains EST and orthologs
  -p [--prot_db]       name of protein BLAST database. Default: ens_min_prot
  -n [--nucl_db]       name of CDS BLAST database. Default: ens_min_cds
  -v [--verbose]       running details, -v for limited, --verbose for full
  -r [--replace_stops] replace STOP codons with 'X' (aa) and 'NNN' (nucl)
  -f [--force]         forces use of alignment to process EST
  -e [--extend]        extend the corrected ORF to nearest ATG and STOP
  -x [--save_blastx]   BLASTx results are printed into an XML file
  -c [--continue]      continue analysing previously opened file
  -a [--fast]          run faster, less sensitive BLASTx
  -O                   minimum number of orthologs to align. Default: 4
  -G                   maximum gap percentage. Default: 25
  -I                   minimum %identity parameter. Default: 20
  -L                   maximum length of gap. Default: 20
  -T                   number of threads on which to run. Default: 1
  -h [--help]          more detailed help message
  -m [--man]           show full documentation
 
=head1 OPTIONS
 
=over 8

=item B<-M> [--method]

Method choice, can either use the native AlignFS algorithm, the Genewise algorithm or both. If using both, the best protein result will be selected as the final ORF, the choice made is written to the log file. Using the genewise algorithm negates the use of -n, -o, -f, -O, -G, -I and -L. Note only the longest ORF is output from Genewise. By default, both algorithms are used.

=item B<-o> [--ortho]

Input file contains EST and known orthologs, therefore no BLASTn is run as the other sequences in the file are used to create the alignment. EST must be the first sequence in the file.

=item B<-p> [--prot_db]

Full name and path of the protein BLAST database. Database should ideally contain non-redundant full length protein sequences from a range of species. Default: 'Blastdb/ens_min_prot'.

=item B<-n> [--nucl_db]

Full name and path of the nucleotide CDS BLAST database. Database must have been indexed using the makeblastdb '-parse_seqids' command. Default: 'Blastdb/ens_min_cds'.

=item B<-v> [--verbose]

Print out the alignment and gap positions while running. -v shows a more limited output than --verbose.

=item B<-r> [--replace_stops]

Will replace all STOP codons with 'NNN', leading to an 'X' in the protein sequence.

=item B<-f> [--force]

If there is more than one HSP indicating a frame shift, than the program will use the alignment to process gaps irrespective of the alignment quality (options -G, -I and -L).

=item B<-e> [--extend]

The identified protein-coding regions are extended to the nearest ATG and STOP codons. WARNING: use with caution, this feature may result in the inclusion of non-coding bases.

=item B<-x> [--save_blastx]

For the sequences with an identified ORF, the BLASTx results are printed in XML format. This file can then be used to annotate the sequences using programs such as Blast2Go.

=item B<-c> [--continue]

If program terminated prematurely on a file, use this option to continue from the previous position. 

=item B<-a> [--fast]

Run a less sensitive, but faster BLASTx. Adds the parameters '-word_size 4 -threshold 20' to the command.

=item B<-O>

Set the minimum number of orthologous sequences to be aligned, including the EST. If insufficient orthologs are identified, then the program will resort to using just the top HSP. Minimum value: 2, Default: 4

=item B<-G>

Set the maximum percentage of gaps, if the EST contains more than n% gaps within the truncated alignment then the alignment is ignored and the top HSP retained. Default: 25

=item B<-I>

Set the minimum percent identity parameter, the overall percentage identity of the truncated alignment must be greater than this value or only the top HSP will be retained. Default: 20

=item B<-L>

Set the maximum length of an in/del. If there is more than one HSP, or the indel is positioned more than 50bp into the alignment then the program stops and the sequence is saved in it's current state. However, if there is only one HSP, the indel is less than 50bp within the alignment or there if this is the first gap encountered then only the top HSP is retained. Default: 20

=item B<-T>

The number of processors to be used. Default: 1 
 
=item B<-h> [--help]
 
Print a brief help message and exits.
 
=item B<-m> [--man]
 
Prints the manual page and exits.
 
=back
 
=head1 DESCRIPTION
 
B<AlignWise.pl> will read the given input file and for each sequence, identify the protein-coding region and correct any frame-shifts. To do this it requires the use of the NCBI BLAST+ suite of tools, the multiple aligner MUSCLE and Genewise. 
 
=cut
