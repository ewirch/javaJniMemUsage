#!/bin/perl
use strict;
use warnings;
use Math::BigInt;
use Data::Dumper;

my $usage = <<EO_MY_USAGE;
 javaJniMemUsage.pl [OPTIONS] PID|proc-maps-file
   OPTIONS
    -c - print output as CSV
    -h - print CSV header line before data line
   PID - process id of process to retrieve memory maps information.
   proc-maps-file - contains memory maps information. Can be directly /proc/PID/maps.
EO_MY_USAGE

my @cmdParams = @ARGV;
my $procMapsFile;
my $printCsv = 0;
my $printCsvHeaderLine = 0;			


sub printUsage();
sub handleCmdLine();
sub bigIntSubtract($$);
sub removeMappedFiles($$);
sub parseLine($);
sub removeSystemMappings($$);
sub removeNativeHeap($$);
sub humanReadableBytes($);
sub removeStackBlocks($$);
sub readOnly($);
sub removeThreadHeapBlocks($$);
sub removeJavaHeapBlocks($$);
sub collectRemainingSize($$);
sub printStats();
sub printMemoryBlocks($);
sub printCsvStats();







handleCmdLine();

my @blocks;

#READ
open(IN,"<",$procMapsFile) or die "cannot open '$procMapsFile': $!";
while (<IN>) {
	chomp;
	my $line = parseLine($_);
	if (defined $line) {
		push @blocks, $line;
	}
}
close(IN);
my @blocksCopy = @blocks;

#anylyze
my %stats;
removeMappedFiles(\@blocks, \%stats);
removeSystemMappings(\@blocks, \%stats);
removeNativeHeap(\@blocks, \%stats);
removeThreadHeapBlocks(\@blocks, \%stats);
removeStackBlocks(\@blocks, \%stats);
removeJavaHeapBlocks(\@blocks, \%stats);
collectRemainingSize(\@blocks, \%stats);

if ($printCsv) {
	printCsvStats();
} else {
	foreach (@blocks) {
		printf "%12s - %12u (%10s), $_->{perm}, $_->{inode}, $_->{path}\n", $_->{addr}, $_->{size}, humanReadableBytes($_->{size});
	}
	printStats();
}

#foreach (@blocksCopy) {
#	printf "%12s - %12u (%10s), $_->{perm}, $_->{inode}, $_->{path}\n", $_->{addr}, $_->{size}, humanReadableBytes($_->{size});
#}









sub printCsvStats() {
	my $formatString = "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\n";
	
	if ($printCsvHeaderLine) {
		printf $formatString, "JAVA-RSS","JAVA-VSZ",	"FILES-VSZ",  "NATIVE-HEAP-RSS",  "STACKS-RSS", "STACKS-VSZ",  "THREAD-HEAPS-RSS", "THREAD-HEAPS-VSZ",  "UNKNOWN-RSS", "UNKNOWN-VSZ", "SUM-RSS", "SUM-VSZ";
	}
	
	my $javaHeapRss = 0;
	my $javaHeapVsz = 0;
	my $filesVsz;
	my $nativeHeapRss;
	my $stacksRss;
	my $stacksVsz;
	my $threadHeapRss;
	my $threadHeapVsz;
	my $unknownRss;
	my $unknownVsz;
	my $sumRss;
	my $sumVsz;
	
	
	if (defined $stats{'java-blocks'}) {
		my @sizes = getMemoryBlockSum($stats{'java-blocks'});
		$javaHeapRss = $sizes[0];
		$javaHeapVsz = $sizes[1];
		$sumRss += $sizes[0];
		$sumVsz += $sizes[1];
	}
	
	$filesVsz = $stats{sizeInMappedFiles};
	$sumVsz += $stats{sizeInMappedFiles};
	
	$sumVsz += $stats{sizeInSystemMappings};

	$nativeHeapRss = $stats{'main-arena'};
	$sumRss += $stats{'main-arena'};
	$sumVsz += $stats{'main-arena'};

	my @sizes = getMemoryBlockSum($stats{stacks});
	$stacksRss = $sizes[0];
	$stacksVsz = $sizes[1];
	$sumRss += $sizes[0];
	$sumVsz += $sizes[1];

	@sizes = getMemoryBlockSum($stats{'t-heaps'});
	$threadHeapRss = $sizes[0];
	$threadHeapVsz = $sizes[1];
	$sumRss += $sizes[0];
	$sumVsz += $sizes[1];

	$unknownRss = $stats{remaining}->{rss};
	$unknownVsz = $stats{remaining}->{vsz};
	
	$sumRss += $stats{remaining}->{rss};
	$sumVsz += $stats{remaining}->{vsz};
	
	printf $formatString, $javaHeapRss,$javaHeapVsz,$filesVsz,$nativeHeapRss,$stacksRss,$stacksVsz,$threadHeapRss,$threadHeapVsz,$unknownRss,$unknownVsz,$sumRss,$sumVsz;
}

sub printStats() {
	my $sumRss = 0;
	my $sumVsz = 0;
	
	if (defined $stats{'java-blocks'}) {
		print "Java-Blocks =\n"; printMemoryBlocks($stats{'java-blocks'});
		my @sizes = getMemoryBlockSum($stats{'java-blocks'});
		$sumRss += $sizes[0];
		$sumVsz += $sizes[1];
	}
	
	print "sizeInMappedFiles = ".humanReadableBytes($stats{sizeInMappedFiles})."\n";
	$sumVsz += $stats{sizeInMappedFiles};
	
	print "sizeInSystemMappings = ".humanReadableBytes($stats{sizeInSystemMappings})."\n";
	$sumVsz += $stats{sizeInSystemMappings};

	print "main-arena = ".humanReadableBytes($stats{'main-arena'})."\n";
	$sumRss += $stats{'main-arena'};
	$sumVsz += $stats{'main-arena'};

	print "stacks =\n"; printMemoryBlocks($stats{stacks});
	my @sizes = getMemoryBlockSum($stats{stacks});
	$sumRss += $sizes[0];
	$sumVsz += $sizes[1];

	print "libc arenas =\n"; printMemoryBlocks($stats{'t-heaps'});
	@sizes = getMemoryBlockSum($stats{'t-heaps'});
	$sumRss += $sizes[0];
	$sumVsz += $sizes[1];

	print "unknown rss =" . humanReadableBytes($stats{remaining}->{rss}) . ", vsz = " . humanReadableBytes($stats{remaining}->{vsz}) . "\n";
	$sumRss += $stats{remaining}->{rss};
	$sumVsz += $stats{remaining}->{vsz};

	print "sum rss =".humanReadableBytes($sumRss).", vsz =".humanReadableBytes($sumVsz)."\n";
}

sub printMemoryBlocks($) {
	my $blocks = shift;
	for (keys %$blocks) {
		my $blockSize = $_;
		my $element = $blocks->{$blockSize};
		
		if ($blockSize > 0) {
			printf "%7s\n", humanReadableBytes($blockSize);
		}
		printf "%13s%s\n", "count=", $element->{count};
		if (defined $element->{addresses}) {
			my $addresses = $element->{addresses};
			printf "%13s[%s]\n", "addr=", join(",", @$addresses)
		}
		printf "%13s%s\n","rss=",humanReadableBytes($element->{rss});
		printf "%13s%s\n","vsz=",humanReadableBytes($element->{vsz});
	}
}

sub getMemoryBlockSum() {
	my $blocks = shift;
	my $rss = 0;
	my $vsz = 0;
	for (keys %$blocks) {
		my $blockSize = $_;
		my $element = $blocks->{$blockSize};
		$rss += $blocks->{$blockSize}->{rss};
		$vsz += $blocks->{$blockSize}->{vsz};
	}

	return ($rss, $vsz);
}

sub collectRemainingSize($$) {
	my $data = shift;
	my $stats = shift;
	my $rss = 0;
	my $vsz = 0;
	foreach (@$data) {
		my $element = $_;
		$vsz += $element->{size};
		if (!readOnly($element)) {
			$rss += $element->{size};
		}
	}
	$stats->{remaining}->{rss} = $rss;
	$stats->{remaining}->{vsz} = $vsz;
}

sub humanReadableBytes($) {
	my $bytes = shift;
	my $hrB;
	use integer; # do integer division
	if($bytes >= (1024*1024*1024)){ 
	   $hrB = sprintf( " %uG", $bytes/1024/1024/1024);                   
	   $bytes = $bytes % (1024*1024*1024);
	}
	if ($bytes >= (1024*1024)){       
	   $hrB .= sprintf( " %uM", $bytes/1024/1024); 
	   $bytes = $bytes % (1024*1024);
	}
	if ($bytes >= 1024){
	   $hrB .= sprintf( " %uK", $bytes/1024 ); 
	   $bytes = $bytes % 1024;
	}
	if ($bytes > 0) {
		$hrB .= sprintf( " %0.2f", $bytes );
	}
	
	if (!defined $hrB) {
		return "0";
	} else {
		return $hrB;
	}
}

sub removeMappedFiles($$) {
	my $data = shift;
	my $stats = shift;
	my $sizeInMappedFiles = 0;
	my $index = 0;
	while ($index < scalar(@$data)) {
		my $element = $data->[$index];
		if ($element->{inode} > 0) {
			$sizeInMappedFiles += $element->{size};
			#remove element from array
			splice @$data, $index, 1;
		} else {
			$index++;
		}
	}
	$stats->{sizeInMappedFiles} = $sizeInMappedFiles;
}

sub removeSystemMappings($$) {
	my $data = shift;
	my $stats = shift;
	my $sizeInSystemMappings = 0;
	my $index = 0;
	while ($index < scalar(@$data)) {
		my $element = $data->[$index];
		if ($element->{path} eq "[vdso]" ||
				$element->{path} eq "[vsyscall]") {
			$sizeInSystemMappings += $element->{size};
			#remove element from array
			splice @$data, $index, 1;
		} else {
			$index++;
		}
	}
	$stats->{sizeInSystemMappings} = $sizeInSystemMappings;
}

sub removeNativeHeap($$) {
	my $data = shift;
	my $stats = shift;
	my $index = 0;
	while ($index < scalar(@$data)) {
		my $element = $data->[$index];
		if ($element->{path} eq "[heap]") {
			$stats->{'main-arena'} = $element->{size};
			#remove element from array
			splice @$data, $index, 1;
			return;
		} else {
			$index++;
		}
	}
}

# Stack blocks usually look like this:
# 7f7c576ec000 -         4096 (   4.00 Kb), ---p, 0,
# 7f7c576ed000 -      1048576 (   1.00 Mb), rw-p, 0,
# there are several of same size and they have a guarding page *before* the stack page
sub removeStackBlocks($$){
	my $data = shift;
	my $stats = shift;
	
	# try to find possible stack blocks
	my %stackSizes;
	my $index = 0;
	while ($index < scalar(@$data)) {
		my $element = $data->[$index];
		if (readOnly($element)) {
			# no read, no write, no execute, probably guarding page
			$index++;
			if ($index < scalar(@$data)) {
				my $nextElement = $data->[$index];
				if (!readOnly($nextElement) && ($element->{addrEnd} eq	$nextElement->{addr})) {
					$stackSizes{$nextElement->{size}} += 1;
				}
			}
		}
		$index++;
	}
	
	#cleanup
	foreach (keys %stackSizes) {
		if ($stackSizes{$_} < 4) {
			delete $stackSizes{$_};
		}
	}

	# remove stack blocks from data list	
	my %stackStats;
	foreach (keys %stackSizes) {
		my $stackSize = $_;
		
		my $lastReadOnly = 0;
		my $previousElement;
		$index = 0;
		while ($index < scalar(@$data)) {
			my $element = $data->[$index];
			if ($lastReadOnly && !readOnly($element) && ($element->{size} == $stackSize) && ($previousElement->{addrEnd} eq	$element->{addr})) {
				$stackStats{$stackSize}->{count} += 1;
				$stackStats{$stackSize}->{rss} += $element->{size};
				$stackStats{$stackSize}->{vsz} += $element->{size} + $previousElement->{size};
				#remove previous element from array
				$index--;
				splice @$data, $index, 1;
				#remove current element from array
				splice @$data, $index, 1;
			} else {
				$index++;
			}

			if (readOnly($element)) {
				$lastReadOnly = 1;
			} else {
				$lastReadOnly = 0;
			}
			$previousElement = $element;
		}
	}

	$stats->{stacks} = \%stackStats;
}

sub removeThreadHeapBlocks($$){
	my $data = shift;
	my $stats = shift;
	my $minBlockSize = 64*1024*1024;
	
	# try to find possible stack blocks
	my %blockSizes;
	my $index = 0;
	while ($index < scalar(@$data)-1) {
		my $element = $data->[$index];

		if (!readOnly($element)) {
			my $nextElement = $data->[$index+1];
			my $size = $element->{size};
			if (readOnly($nextElement) && ($nextElement->{addr} eq $element->{addrEnd})) {
				$size += $nextElement->{size};
			}
			if ($size >= $minBlockSize && ($size % $minBlockSize == 0)) {
				$blockSizes{$size}++;
			}
		}
		$index++;
	}

	#cleanup
	foreach (keys %blockSizes) {
		if ($blockSizes{$_} < 2) {
			delete $blockSizes{$_};
		}
	}

	# remove stack blocks from data list	
	my %blockStats;
	foreach (keys %blockSizes) {
		my $blockSize = $_;
		my $tempBlockStats = getAndRemoveHeapBlocks($blockSize, $data);
		foreach (keys %$tempBlockStats) {
			$blockStats{$_} = $tempBlockStats->{$_};
		}
	}

	$stats->{'t-heaps'} = \%blockStats;
}

sub removeJavaHeapBlocks($$) {
	my $data = shift;
	my $stats = shift;

	my %blockStats;
	my $index = 0;
	while ($index < scalar(@$data)-1) {
		my $element = $data->[$index];

		# java seems to store its heaps below 7f1000000000
		if (isLoAddr($element->{addr})) {
			$blockStats{count}++;
			if (!readOnly($element)) {
				$blockStats{rss}+=$element->{size};
			}
			$blockStats{vsz}+=$element->{size};
			my $addresses = $blockStats{addresses};
			my @empty;
			if (!defined $addresses) {
				$addresses = \@empty;
				$blockStats{addresses} = $addresses;
			}
			push @$addresses, $element->{addr};

			splice @$data, $index, 1;
		} else {
			$index++;
		}
	}

	if (defined $blockStats{count} && $blockStats{count} > 0) {
		$stats->{'java-blocks'}->{"0"} = \%blockStats;
	}
}

sub isLoAddr($) {
	my $addr = shift;
	my $loAddrBorder = Math::BigInt->from_hex("7f1000000000");
	my $intAddr = Math::BigInt->from_hex($addr);
	if ($intAddr->bcmp($loAddrBorder) < 0) {
		return 1;
	}
	return 0;
}

sub getAndRemoveHeapBlocks($$) {
	my $blockSize = shift;
	my $data = shift;
	my %blockStats;
	
	my $index = 0;
	while ($index < scalar(@$data)-1) {
		my $element = $data->[$index];
		if (!readOnly($element)) {
			my $nextElement = $data->[$index+1];
			my $itemsToDelete = 1;
			my $rss = $element->{size};
			my $unused = 0;
			
			if (readOnly($nextElement) && ($nextElement->{addr} eq $element->{addrEnd})) {
				$unused = $nextElement->{size};
			}

			if (($rss+$unused) == $blockSize) {
				$blockStats{$blockSize}->{count}++;
				$blockStats{$blockSize}->{rss}+=$rss;
				$blockStats{$blockSize}->{vsz}+=$rss+$unused;
				my $addresses = $blockStats{$blockSize}->{addresses};
				my @empty;
				if (!defined $addresses) {
					$addresses = \@empty;
					$blockStats{$blockSize}->{addresses} = $addresses;
				}
				push @$addresses, $element->{addr};
				
				splice @$data, $index, 1;
				if ($unused > 0) {
					splice @$data, $index, 1;
				}
			} else {
				$index++;
			}
		} else {
			$index++;
		}
	}
	return \%blockStats;
}

sub readOnly($) {
	my $element = shift;
	return $element->{perm} =~ /^---/;
}

sub parseLine($) {
	my $line = shift;
	# 7f7c5e484000-7f7c5e485000 rw-p 00020000 09:00 33033173                   /lib/x86_64-linux-gnu/ld-2.13.so
	#              from addr      to addr          perm       offset           time       i-node  path
	if ($line =~ /^([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+([^\s]+)\s+([0-9a-fA-F]+)\s+([^\s]+)\s+(\d+)\s*(.*)$/) {
		my %parsedLine;
		$parsedLine{'addr'} = $1;
		$parsedLine{'addrEnd'} = $2;
		$parsedLine{'size'} = bigIntSubtract($2, $1);
		$parsedLine{'perm'} = $3;
		$parsedLine{'inode'} = $6;
		$parsedLine{'path'} = $7;
		return \%parsedLine;
	} else {
		print "unparseable line: $line\n";
		return undef;
	}
}

# subtracts b from a.  x =  a - b
sub bigIntSubtract($$) {
	my $a = Math::BigInt->from_hex(shift);
	my $b = Math::BigInt->from_hex(shift);
	$a->bsub($b);
	return $a->numify();
}
sub handleCmdLine() {
	while (scalar(@cmdParams) > 0) {
		my $param = shift @cmdParams;
		if ($param eq "-c") {
			$printCsv = 1;
		} elsif ($param eq "-h") {
			$printCsvHeaderLine = 1;			
		} elsif ($param =~ /^\d+$/ && !$procMapsFile) {
			$procMapsFile = "/proc/$param/maps";	
		} elsif (!$procMapsFile) {
			$procMapsFile = $param;	
		} else {
			printUsage();
			exit(1);
		}
	}
	if (!$procMapsFile) {
			printUsage();
			exit(1);
	}
}

sub printUsage() {
	print $usage;
}

1;
