#!/usr/bin/perl

#to check whether "my" is declared before any variable creation. otherwise pops error
use strict;
use warnings;

#to tell the user to send the automated script along with the report file. otherwise skips it. 
if (!defined $ARGV[0]) {
    die "Usage: perl timing_parser.pl <report.rpt>\n";
}

#store the report file in scalar variable. so that this perl script file can be used as a common one & can extract value from any file. 
my $filename = $ARGV[0];

#initial declaration
my $design   = "";
my $period   = 0;
my $wns      = undef;
my $tns      = undef;
my $whs      = undef;

open(my $fh,  "<", $filename)           or die "Cannot open $filename: $!"; #read mode
open(my $out, ">", "timing_summary.log") or die "Cannot open output: $!"; #write mode into the log file, from where we can see the output

while (my $line = <$fh>) {
    chomp $line; #it will trail the newline at the end of each line from the file which is opened
    if ($line =~ /^Design\s+:\s+(\w+)/) {
        $design = $1; #extracting the design name by using regex. only if it's matches perfectly, extracted otherwise skipped!
    }
    if ($line =~ /^Period\(ns\)\s*:\s*(\d+\.\d+)/) {
        $period = $1; #same process like before to get the clk period
    }
    my @vals = parse_timing($line); #to get these value from subroutine aka function. 
    if (defined $vals[0]) { #checking whether anything is extracted from the file. only then, we will assign otherwise no need to assign!
        $wns = $vals[0];
        $tns = $vals[1];
        $whs = $vals[2];
    }
}
close($fh); #closing the file which is opened 

# print formatted table
printf $out "==========================================\n";
printf $out "  Vivado Timing Summary -- %s\n", $design;
printf $out "==========================================\n";
printf $out "  Clock Period  : %7.3f ns\n", $period;
printf $out "  WNS           : %7.3f ns  [%s]\n", $wns, $wns > 0 ? "CLEAN" : "VIOLATED";
printf $out "  TNS           : %7.3f ns\n", $tns;
printf $out "  WHS           : %7.3f ns  [%s]\n", $whs, $whs > 0 ? "CLEAN" : "VIOLATED";
printf $out "  Setup Status  : %s\n",       $wns > 0 ? "MET" : "VIOLATED";
printf $out "==========================================\n";

close($out); #closing the file in which the output summary is written

sub parse_timing { #subroutine 
    my ($line) = @_; #collect the variable in built-in array
    if ($line =~ /^(\d+\.\d+)\s+(\d+\.\d+)\s+\d+\s+(\d+\.\d+)/) { # checking any matches are there
        return ($1, $2, $3); #if matches are found, then return those value
    }
    return (); #if not, return none/empty array. 
}

