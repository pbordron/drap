#!/usr/bin/perl

use strict;
use Pod::Usage;
use Getopt::Long;
use File::Basename;
use Statistics::R;
use POSIX;

my ($man, $help, $file, $log, $regexp, $output, $png, $is_sam);
my $mapq = 0;

GetOptions(
	'f=s'  => \$file,
	'r=s'  => \$regexp,
	'o=s'  => \$output,
	'l'    => \$log,
	'p'    => \$png,
	'q=i'  => \$mapq,
	'S'    => \$is_sam,
	'help' => \$help,
	'man'  => \$man,
);

pod2usage(1) if ($help);
pod2usage(-exitstatus => 0, -verbose => 2) if ($man);
pod2usage("No BAM file given as parameter") unless (@ARGV || $file);
$regexp ||= '(.+)\.[bs]am';
$output ||= 'asm_fwd_rev_stat';
my $sam = $is_sam ? '-S' : '';

my (@bam_files, %conditions, @conditions);
if (open(LIST, $file)) {
	chomp(@bam_files = <LIST>);
	close LIST;
}
else {
	@bam_files = @ARGV;
}
# check files before processing
foreach (@bam_files) {
	die "No such file $_\n" unless (-f $_);
	die "Unable to read $_ using samtools view $sam\n" unless (open(BAM, "samtools view $sam $_ |"));
	close BAM;
	my ($condition) = basename($_) =~ /$regexp/;
	die "Unable to get condition name from $_ using regexp /$regexp/\n" unless ($condition);
	$conditions{$_} = $condition;
	push(@conditions, $condition);
}

my (%bins, %contigs, @t);
my @bins = map { sprintf("%.1f",$_/10) } 0..10;
my $chart = dirname($bam_files[0])."/$output.html";
$png = dirname($bam_files[0])."/$output.png" if ($png); 
my $data = dirname($bam_files[0])."/$output.tsv";
print "BAM\tCondition\tProcessed contigs\n";
foreach my $bam (@bam_files) {
	open(BAM, "samtools view -q $mapq $sam $bam |");
	while(<BAM>) {
		@t = split(/\t/,$_);
		next if ($t[1] & 4); # next if unmapped read
		$t[1] & 16 ? $contigs{$t[2]}->{$conditions{$bam}}->{r}++ : $contigs{$t[2]}->{$conditions{$bam}}->{f}++;
	}
	close BAM;
	print join("\t", basename($bam), $conditions{$bam}, scalar(keys %contigs))."\n";
	my ($value, $round);
	map { $bins{$conditions{$bam}}->{$_} = 0 } @bins;
	foreach my $contig (keys %contigs) {
		eval { $value = $contigs{$contig}->{$conditions{$bam}}->{f}/($contigs{$contig}->{$conditions{$bam}}->{f}+$contigs{$contig}->{$conditions{$bam}}->{r}); };
		unless ($@) { # contigs wihtout any reads are not considered
			#$trunc = sprintf("%.1f",int($value*10)/10); #$contigs{$contig}->{$conditions{$bam}}->{v} = $trunc;	#$trunc == 1 ? $bins{0.9}++ : $bins{$trunc}++;
			$round = sprintf("%.1f", $value);
			$bins{$conditions{$bam}}->{$round}++;
			$contigs{$contig}->{$conditions{$bam}}->{v} = $round;
		}
	}
}
my @draw;
foreach my $condition (@conditions) {
	my @v = map { $bins{$condition}->{$_} || 'null' } @bins; # replace O by null if log scale
	push(@draw, \@v);
}
highcharts($chart, $log, \@conditions, \@bins, \@draw);
if ($png) {
	splice(@draw);
	foreach my $condition (@conditions) {
		my @v = map { $log ? $bins{$condition}->{$_} || 'NA' : $bins{$condition}->{$_} } @bins; # replace O by NA if log scale
		push(@draw, \@v);
	}
	R($png, $log, \@conditions, \@bins, \@draw);
}
	
open(TSV, ">$data") or die "Unable to write into file $data\n";
foreach my $contig (sort keys %contigs) {
	my @values = map { sprintf("%s,%d,%d,%.1f", $_, $contigs{$contig}->{$_}->{f} || 0, $contigs{$contig}->{$_}->{r} || 0, exists $contigs{$contig}->{$_}->{v} ? $contigs{$contig}->{$_}->{v} : '#') }  @conditions;
	print TSV $contig."\t".join(';', @values)."\n";
}
close TSV;

sub R {
	my ($png, $log, $conditions, $bins, $datasets) = @_;
	my $plot_width = 300; # plot size in pixel
	my $plot_height = 300; # height size in pixel
	my $columns = scalar(@$conditions) >= 4 ? 4 : scalar(@$conditions); # 4 columns max
	my $lines = ceil(scalar(@$conditions)/$columns);
	my $width = $plot_width*$columns;
	my $height = $plot_height*$lines;
	my $names = join(', ', @$bins);
	$log = $log ? ', log="y"' : '';
	my $R = Statistics::R->new();
	$R->run(qq|png("$png", $width, $height)|);
	$R->run(qq|par(mfrow=c($lines, $columns), oma=c(0, 0, 2, 0))|);
	$R->run(qq|bins <- c($names)|);
	for (my $i = 0; $i < scalar(@$conditions); $i++) {
		my $data = join(', ', @{$$datasets[$i]});
		$R->run(qq|values <- c($data)|);
		$R->run(qq|barplot(values$log, col="light blue", names.arg=bins, space=0, ylab="Total contigs", xlab="Fwd/(Fwd+Rev)", main="$$conditions[$i]")|);
	}
	$R->run(qq|title("Contigs composition of forward and reverse reads", outer=TRUE)|);
	$R->run(q|graphics.off()|);
}

sub highcharts {
	my ($chart, $log, $conditions, $bins, $datasets) = @_;
	my $max_columns = 4;
	my $chart_width = 400;
	my $chart_height = 400;
	my (@charts, @containers);
	for (my $i = 0; $i < scalar(@$conditions); $i++) {
		push(@charts, get_charts($i, $$conditions[$i], \@{$$datasets[$i]}));
		push(@containers, sprintf(
			"<div id='container%d' style='width: %dpx; height: %dpx; margin: 0;%s'></div>",
			$i, $chart_width, $chart_height, ($i+1) % $max_columns ? ' float:left;' : '')
		);
	}
	my @categories = @$bins;
	open(HTML, ">$chart") or die "Unable to write into file $chart\n";
	printf HTML (q|<!DOCTYPE HTML>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>Contigs composition of forward and reverse reads</title>
<script type="text/javascript" src="http://snp.toulouse.inra.fr/~sigenae/highcharts/jquery.js"></script>
<script type="text/javascript" src="http://snp.toulouse.inra.fr/~sigenae/highcharts/highcharts.js"></script>
<script type="text/javascript" src="http://snp.toulouse.inra.fr/~sigenae/highcharts/exporting.js"></script>
<script type="text/javascript">
    Highcharts.setOptions({
		chart: { type: 'column' },
		title: { style: { color: '#4572A7' } },
		credits: { enabled: false },
		exporting: { enabled: false },
		legend: { enabled: false },
		xAxis: { 
			title: { text: 'F/(F+R)' },
			categories: [%s]
		},
		yAxis: {
			title: { text: 'Total contigs' },
			labels: { style: { color: '#4572A7' } },
			type: '%s'
		},
		tooltip: { 
			formatter: function() {
				var b = this.x == '0' ? '0' : (parseFloat(this.x)-0.05).toFixed(2);
				var e = this.x == '1' ? '1' : (parseFloat(this.x)+0.05).toFixed(2);
				var c = this.x == '0' ? '[' : ']';
				c += b+', '+e;
				c += this.x == '1' ? ']' : '[';
				return '<b>'+c+'</b><br>= '+this.y
			}
		},
		plotOptions: { 
			column: { borderWidth: 0 },
			series: { pointWidth: 20 }
		}
	});
	var chartData = [%s];
	var charts = [];
	function renderChart() {
		if(charts.length < 1){
			for (var c in chartData) {
				charts[c] = new Highcharts.Chart(chartData[c]);
			}
		}else{
			for (var c in chartData) {
				charts[c].destroy();
				charts[c] = new Highcharts.Chart(chartData[c]);
			}
		}
	};
	function toggleAxis() {
		document.getElementById("toggle").innerHTML = "Set "+charts[0].options.yAxis.type+" yAxis";
		var t = charts[0].options.yAxis.type == 'linear' ? 'logarithmic' : 'linear';
		Highcharts.setOptions({
			yAxis: { 
				labels: { style:{ color:'#ff5c00' } },
				type: t
			}
		});
		renderChart();
	};
	$(document).ready(function() {
	    renderChart();
	});	
</script>
<style>
.button,.button:visited{background:#222;display:inline-block;padding:5px 10px 6px;color:#fff;text-decoration:none;border-radius:6px;-moz-border-radius:6px;-webkit-border-radius:6px;-moz-box-shadow:0 1px 3px rgba(0,0,0,0.6);-webkit-box-shadow:0 1px 3px rgba(0,0,0,0.6);text-shadow:0 -1px 1px rgba(0,0,0,0.25);border-bottom:1px solid rgba(0,0,0,0.25);position:relative;cursor:pointer}
.button:hover{background-color:#111;color:#fff;}
.button:active{top:1px;}
.small.button,.small.button:visited{font-size:11px}
.button,.button:visited,.medium.button,.medium.button:visited{font-size:13px;font-weight:bold;line-height:1;text-shadow:0 -1px 1px rgba(0,0,0,0.25);}
.orange.button,.orange.button:visited{background-color:#ff5c00;}
.orange.button:hover{background-color:#d45500;}
</style>
</head>
<body>
<div %sstyle='font-family:"Lucida Grande","Lucida Sans Unicode",Verdana,Arial,Helvetica,sans-serif;font-weight:bold; color:#4572A7'>
	Contigs composition of forward and reverse reads? <a id="toggle" class="small button orange" onclick="toggleAxis()">Set %s yAxis</a>
</div>
%s
</body>
</html>|,
join(', ', map { s/\.0//; quotify($_) } @categories), $log ? 'logarithmic' : 'linear',
join(", ", @charts), scalar(@$conditions) < $max_columns ? '' : "align='center' ", $log ? 'linear' : 'logarithmic',
join("\n", @containers)
);
	close HTML;
}

sub get_charts {
	my ($i, $title, $data) = @_;
	return sprintf(q|{
		chart: { renderTo: 'container%d' },
		title: { text: '%s' },
		series: [{ data: [%s] }]
	}|,
	$i, $title, join(', ', @$data)
	);
}

sub quotify {
	return "'$_[0]'";
}

=head1 NAME

asm_check_forward_reverse.pl

=head1 SYNOPSIS

asm_check_forward_reverse.pl OPTIONS {-f <list of SAM|BAM files> | <SAM|BAM1> <SAM|BAM2>}

=head1 OPTIONS

=over 8

=item B<-man>

	Print the man page and exits.

=item B<-help>
	
	Print a brief help message and exits.

=item B<-r REGEXP>

	Regular expression allowing to extract condition name from SAM|BAM file names.
	Give regexp between single quotes. Default is '(.+)\.[bs]am'.

=item B<-l>

	Set logarithmic scale for histograms Y axis. Default is linear.

=item B<-p>

	By default, histograms are drawn using Highcharts (http://www.highcharts.com). 
	With the -p option, histograms are also printed into a png file.

=item B<-S>

	Input files are SAM files.

=item B<-f FILE>

	SAM/BAM files are given as a list.

=item B<-o STRING>

	Basename output files. Default is asm_pairs_stat.

=item B<-q INTEGER>

	Mapping quality threshold. Alignments with mapping quality lower than the threshold
	will not be considered.	Default is 0.

=back

=head1 DESCRIPTION
  
	Read SAM|BAM input files and extract the mapping read strand information from the SAM flag.
	Output files are generated in the directory of the first SAM|BAM file given as input.
	Output histograms and data are ordered following SAM|BAM input files order.
	The HTML|PNG file shows histograms of F/R+F values for each SAM|BAM file.
	The TSV file presents data for each contig using format:
	contig    condition1,F,R,F/R+F;condition2,F,R,F/R+F;...
  
=head1 AUTHORS

 Cedric Cabau - INRA Toulouse - sigenae-support@listes.inra.fr

=head1 VERSION

 1

=head1 DATE

 2013

=head1 KEYWORDS

 sam bam forward reverse strand assembly contig

=cut
