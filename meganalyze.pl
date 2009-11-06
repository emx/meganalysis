#!/usr/bin/perl
use Time::Stopwatch;
use Term::ProgressBar;
use PDL;
use PDL::NiceSlice;
use Storable;
use PDL::IO::Storable;
use FileHandle;
use Chart::Gnuplot;
use Chart::Gnuplot::Pie;

tie $timer, 'Time::Stopwatch';
use constant DAYSEC => 24*60*60;
$|=1;
my $file = $ARGV[0];
my $stateFile = ".state.$file";

sub clocker
{
	my $text = shift;
	printf"[%5.2f] %10s\n", $timer, $text;
}

sub dataLoad
{
	my $csvfile = shift;
	my $cachestate = 0;
	if (-s $stateFile) 
	{ 
		&clocker("State file found for $csvfile, restoring state"); 
		$cachestate = 1;
		$state = retrieve($stateFile);
	}
	else 
	{ 
		&clocker("No state file found, parsing $csvfile");
		$PDL::IO::Misc::colsep = ",";
		($ts, $pid, $sub, $time) = rcols($csvfile, {perlcols => [4], DEFTYPE => long});
	}
	return $cachestate;
}

sub countSubs
{
	my $cachestate = shift;
	return $state->{'totalsubs'} if $cachestate;
	%count = ();
	for ($i=0; $i<$sub->nelem; $i++) { $count{$sub->at($i)}++ }
	return scalar keys %count;
}

sub storeState
{
	my ($totalsubs, $averages, $selection, $initials, $inc, $drop, $neg, $trans) = @_;
	my $pdlcount = pdl (values %count);
	my $hash = 
	{
		'totalsubs'    => $totalsubs,
		'transactions' => $trans,
		'averages'     => $averages,
		'initials'	   => $initials,
		'repurchasers' => $inc, 
		'dropped'	   => $drop, 
		'negative'	   => $neg,
		'purchases'    => $pdlcount,
		'selection'	   => $selection
	};
	store $hash, $stateFile;
	&clocker("State saved for $file");
}

sub lapsesCalc
{
	my ($inc, $drop, $neg, $trans);
	$scount = $inc = $drop = $neg = 0;
	$avg = zeroes $totalsubs; # dimension arrays for max size
	$sel = zeroes $totalsubs;
	$ini = zeroes $totalsubs;
	my $progress = Term::ProgressBar->new({count => $totalsubs, name => 'Analysis', ETA => 'linear'});
	$progress->minor(0); $progress->max_update_rate(1);
	foreach (keys %count)
	{
		$progress->update($scount++);
		next if $count{$_} < 2; # no repurchases
		($pTimes, $pDurations) = where($ts, $time, $sub == $_);
		$intervals = $pTimes(1:-1) - $pTimes(0:-2);
		$lapses = $intervals - $pDurations(0:-2) * DAYSEC;
		$reals = which($intervals > DAYSEC); # repurchase at least 24h later
		$avg_lapses = ($lapses->index($reals))->avg; # excludes < 24h
		if ($avg_lapses) 
		{ 
			$avg($inc)   .= $avg_lapses;
			$sel($inc)   .= $pDurations->uniq->nelem;
			$ini($inc++) .= $pDurations(:0);
		} 
		else { $drop++ }
		$neg++ if $avg_lapses < 0; # repurchase before expiry
	}
	$progress->update($totalsubs); 
	($averages, $selection, $initials) = where($avg, $sel, $ini, $avg != 0); # remove empty subs
	#$initials->sever; $selection->sever; 
	$trans = $sub->nelem;
	&storeState($totalsubs, $averages, $selection, $initials, $inc, $drop, $neg, $trans);
	return ($inc, $drop, $neg, $trans);
}

sub barGrapher
{
	my ($package, $data, @range) = @_;
	my ($xaxis, $yaxis) = $data->hist(@range);
	my $chart = Chart::Gnuplot->new
	(
		output => "hist-$package.png", 
		title  => "Repurchase delay ($package package)", 
		xlabel => "Time (days)", 
		ylabel => "Repurchasers"
	);
	my @xdata = list $xaxis; 
	my @ydata = list $yaxis;
	my $dataSet = Chart::Gnuplot::DataSet->new
	(
		xdata => \@xdata, 
		ydata => \@ydata, 
		title => $file, 
		style => "boxes fs solid 1"
	);
	$chart->plot2d($dataSet);
}

sub pieGrapher
{
	my ($title, @array) = @_;

	my $chart = Chart::Gnuplot::Pie->new
	(
		output => "purchases-$title.png", 
		title  => $title
	); 	
	my $dataSet = Chart::Gnuplot::Pie::DataSet->new
	(
		data  => \@array, 
		title => $file
	);
	$chart->plot3d($dataSet);
}

sub plotGraphs
{
	my @carray = my @parray = my @barray = ();
	my $p = 0;
	my @range1 = (-50, +150, 1);
	my @range2 = (1, 5, 1);
	my @range3 = (0.5, 5.5, 1);
	$averages /= DAYSEC; # convert to days
	&clocker("Generating global repurchase histogram");
	&barGrapher('global', $averages, @range1);
	foreach (list $initials->uniq)
	{
		&clocker("Generating histogram for amount $_");
		($avghere, $inihere) = where($averages, $initials, $initials == $_);
		&barGrapher($_, $avghere, @range1);
		$parray[$p++] = [$_, $inihere->nelem];
	}
	
	&clocker("Generating pie chart (packages bought)");
	($xaxis, $yaxis) = $selection->hist(@range3);
	print "HIST:\n X = ", $xaxis, " Y = ", $yaxis, "\n";
	for (my $i=0; $i<$yaxis->nelem; $i++) { $barray[$i] = [int($xaxis->at($i)), $yaxis->at($i)] }
	&pieGrapher("Bought", @barray);
	
	&clocker("Generating pie chart (initial package)");
	&pieGrapher("Package", @parray);
	
	&clocker("Generating pie chart (purchases count)");
	($xaxis, $yaxis) = $pcount->hist(@range3);
	print "HIST:\n X = ", $xaxis, " Y = ", $yaxis, "\n";
	for (my $i=0; $i<$yaxis->nelem; $i++) { $carray[$i] = [int($xaxis->at($i)), $yaxis->at($i)] }
	&pieGrapher("Count", @carray);
}

sub analyze
{
	my $cacheState = shift;
	my ($inc, $drop, $neg, $transactions);
	if ($cacheState)
	{
		$transactions = $state->{'transactions'};
		($inc, $drop, $neg) = ($state->{'repurchasers'}, $state->{'dropped'}, $state->{'negative'});
		$averages = $state->{'averages'};
		$initials = $state->{'initials'};
		$pcount = $state->{'purchases'};
		$selection = $state->{'selection'};
	}
	else
	{
		($inc, $drop, $neg, $transactions) = &lapsesCalc;		
		$pcount = pdl (values %count);
	}
	print "\nAnalyzed a total of $transactions payment transactions:\n";
	print "Identified $totalsubs subscribers\n";
	print "Found $inc real repurchasers (ignored $drop fakes), $neg of them were negative\n";
	printf "Global repurchase: %d days, %d hours\n",(gmtime ($averages->avg))[7,2];
	&plotGraphs;
}

# MAIN

$cached = &dataLoad($file);
&clocker("Data load complete");

$totalsubs = &countSubs($cached);
&clocker("Found $totalsubs subscriptions");

&analyze($cached);
&clocker("Repurchase analysis complete");

