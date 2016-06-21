#!/usr/bin/perl
##################################################################
# ABI Tracker 1.7
# A tool to visualize ABI changes timeline of a C/C++ software library
#
# Copyright (C) 2015-2016 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux (x86, x86_64)
#
# REQUIREMENTS
# ============
#  Perl 5 (5.8 or newer)
#  Elfutils (eu-readelf)
#  ABI Dumper (0.99.15 or newer)
#  Vtable-Dumper (1.1 or newer)
#  ABI Compliance Checker (1.99.21 or newer)
#  PkgDiff (1.6.4 or newer)
#  RfcDiff 1.41
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License or the GNU Lesser
# General Public License as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# and the GNU Lesser General Public License along with this program.
# If not, see <http://www.gnu.org/licenses/>.
##################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case", "permute");
use File::Path qw(mkpath rmtree);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use Cwd qw(abs_path cwd);
use Data::Dumper;

my $TOOL_VERSION = "1.7";
my $DB_NAME = "Tracker.data";
my $TMP_DIR = tempdir(CLEANUP=>1);

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $ABI_DUMPER = "abi-dumper";
my $ABI_DUMPER_VERSION = "0.99.16";
my $ABI_DUMPER_EE = 0;

my $ABI_CC = "abi-compliance-checker";
my $ABI_CC_VERSION = "1.99.20";

my $RFCDIFF = "rfcdiff";
my $PKGDIFF = "pkgdiff";
my $PKGDIFF_VERSION = "1.6.4";

my $ABI_VIEWER = "abi-viewer";

my ($Help, $DumpVersion, $Build, $Rebuild, $DisableCache,
$TargetVersion, $TargetElement, $Clear, $GlobalIndex, $Deploy,
$Debug);

my $CmdName = basename($0);
my $ORIG_DIR = cwd();
my $MD5_LEN = 5;

my %ERROR_CODE = (
    "Success"=>0,
    # Undifferentiated error code
    "Error"=>2,
    # System command is not found
    "Not_Found"=>3,
    # Cannot access input files
    "Access_Error"=>4,
    # Cannot find a module
    "Module_Error"=>9
);

my $HomePage = "http://abi-laboratory.pro/";

my $ShortUsage = "ABI Tracker $TOOL_VERSION
A tool to visualize ABI changes timeline of a C/C++ software library
Copyright (C) 2016 Andrey Ponomarenko's ABI Laboratory
License: GPLv2.0+ or LGPLv2.1+

Usage: $CmdName [options] [profile]
Example:
  $CmdName -build profile.json

More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$Help,
  "dumpversion!" => \$DumpVersion,
# general options
  "build!" => \$Build,
  "rebuild!" => \$Rebuild,
# internal options
  "v=s" => \$TargetVersion,
  "t|target=s" => \$TargetElement,
  "clear!" => \$Clear,
  "global-index!" => \$GlobalIndex,
  "disable-cache!" => \$DisableCache,
  "deploy=s" => \$Deploy,
  "debug!" => \$Debug
) or ERR_MESSAGE();

sub ERR_MESSAGE()
{
    printMsg("INFO", "\n".$ShortUsage);
    exit($ERROR_CODE{"Error"});
}

my $HelpMessage="
NAME:
  ABI Tracker ($CmdName)
  Visualize ABI changes timeline of a C/C++ software library

DESCRIPTION:
  ABI Tracker is a tool to visualize ABI changes timeline of a
  C/C++ software library.
  
  The tool is intended for developers of software libraries and
  Linux maintainers who are interested in ensuring backward
  binary compatibility, i.e. allow old applications to run with
  newer library versions.

  This tool is free software: you can redistribute it and/or
  modify it under the terms of the GPLv2.0+ or LGPLv2.1+.

USAGE:
  $CmdName [options] [profile]

EXAMPLES:
  $CmdName -build profile.json

INFORMATION OPTIONS:
  -h|-help
      Print this help.

  -dumpversion
      Print the tool version ($TOOL_VERSION) and don't do
      anything else.

GENERAL OPTIONS:
  -build
      Build reports.
  
  -rebuild
      Re-build reports.
  
  -v NUM
      Select only one particular version of the library to
      create reports for.
  
  -t|-target TYPE
      Select type of the reports to build:
      
        abidump
        abireport
        headersdiff
        pkgdiff
        changelog
        soname
        date
  
  -clear
      Remove all reports.
  
  -global-index
      Create list of all tested libraries.
  
  -disable-cache
      Enable this option if you've changed filter of checked
      symbols in the library (skipped types, skipped functions, etc.).
  
  -deploy DIR
      Copy all reports and css to DIR.
  
  -debug
      Enable debug messages.
";

my $Profile;
my $DB;
my $TARGET_LIB;
my $DB_PATH = undef;

# Regenerate reports
my $ObjectsReport = 0;

# Report style
my $LinkClass = " class='num'";
my $LinkNew = " new";
my $LinkRemoved = " removed";

sub get_Modules()
{
    my $TOOL_DIR = dirname($0);
    my @SEARCH_DIRS = (
        # tool's directory
        abs_path($TOOL_DIR),
        # relative path to modules
        abs_path($TOOL_DIR)."/../share/abi-tracker",
        # install path
        'MODULES_INSTALL_PATH'
    );
    foreach my $DIR (@SEARCH_DIRS)
    {
        if(not $DIR=~/\A\//)
        { # relative path
            $DIR = abs_path($TOOL_DIR)."/".$DIR;
        }
        if(-d $DIR."/modules") {
            return $DIR."/modules";
        }
    }
    exitStatus("Module_Error", "can't find modules");
}

sub loadModule($)
{
    my $Name = $_[0];
    my $Path = $MODULES_DIR."/Internals/$Name.pm";
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    require $Path;
}

sub readModule($$)
{
    my ($Module, $Name) = @_;
    my $Path = $MODULES_DIR."/Internals/$Module/".$Name;
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    return readFile($Path);
}

sub exitStatus($$)
{
    my ($Code, $Msg) = @_;
    printMsg("ERROR", $Msg);
    exit($ERROR_CODE{$Code});
}

sub printMsg($$)
{
    my ($Type, $Msg) = @_;
    if($Type!~/\AINFO/) {
        $Msg = $Type.": ".$Msg;
    }
    if($Type!~/_C\Z/) {
        $Msg .= "\n";
    }
    if($Type eq "ERROR") {
        print STDERR $Msg;
    }
    else {
        print $Msg;
    }
}

sub readProfile($)
{
    my $Content = $_[0];
    
    my %Res = ();
    
    if($Content=~/\A\s*\{\s*((.|\n)+?)\s*\}\s*\Z/)
    {
        my $Info = $1;
        
        if($Info=~/\"Versions\"/)
        {
            my $Pos = 0;
            
            while($Info=~s/(\"Versions\"\s*:\s*\[\s*)(\{\s*(.|\n)+?\s*\})\s*,?\s*/$1/)
            {
                my $VInfo = readProfile($2);
                if(my $VNum = $VInfo->{"Number"})
                {
                    $VInfo->{"Pos"} = $Pos++;
                    $Res{"Versions"}{$VNum} = $VInfo;
                }
                else {
                    printMsg("ERROR", "version number is missed in the profile");
                }
            }
        }
        
        # arrays
        while($Info=~s/\"(\w+)\"\s*:\s*\[\s*(.*?)\s*\]\s*(\,|\Z)//)
        {
            my ($K, $A) = ($1, $2);
            
            if($K eq "Versions") {
                next;
            }
            
            $Res{$K} = [];
            
            foreach my $E (split(/\s*\,\s*/, $A))
            {
                $E=~s/\A[\"\']//;
                $E=~s/[\"\']\Z//;
                
                push(@{$Res{$K}}, $E);
            }
        }
        
        # scalars
        while($Info=~s/\"(\w+)\"\s*:\s*(.+?)\s*\,?\s*$//m)
        {
            my ($K, $V) = ($1, $2);
            
            if($K eq "Versions") {
                next;
            }
            
            if($K eq "RfcDiff")
            { # alias
                $K = "HeadersDiff";
            }
            
            $V=~s/\A[\"\']//;
            $V=~s/[\"\']\Z//;
            
            $Res{$K} = $V;
        }
    }
    
    return \%Res;
}

sub skipVersion_T($)
{
    my $V = $_[0];
    
    if(defined $TargetVersion)
    {
        if($V ne $TargetVersion)
        {
            return 1;
        }
    }
    
    return 0;
}

sub skipVersion($)
{
    my $V = $_[0];
    
    if(defined $Profile->{"SkipVersions"})
    {
        my @Skip = @{$Profile->{"SkipVersions"}};
        
        foreach my $E (@Skip)
        {
            if($E=~/[\*\+\(\|\\]/)
            { # pattern
                if($V=~/\A$E\Z/) {
                    return 1;
                }
            }
            elsif($E eq $V) {
                return 1;
            }
        }
    }
    
    return 0;
}

sub buildData()
{
    my @Versions = getVersionsList();
    
    if($TargetVersion)
    {
        if(not grep {$_ eq $TargetVersion} @Versions)
        {
            printMsg("ERROR", "unknown version number \'$TargetVersion\'");
        }
    }
    
    foreach my $V (@Versions)
    {
        if(skipVersion_T($V)) {
            next;
        }
        if(my $Installed = $Profile->{"Versions"}{$V}{"Installed"})
        {
            if(not -d $Installed)
            {
                printMsg("ERROR", "$V is not installed");
            }
        }
    }
    
    if(checkTarget("date")
    or checkTarget("dates"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            detectDate($V);
        }
    }
    
    if(checkTarget("soname"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            detectSoname($V);
        }
    }
    
    if(checkTarget("changelog"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            createChangelog($V, $V eq $Versions[$#Versions]);
        }
    }
    
    if(checkTarget("abidump"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            createABIDump($V);
        }
    }
    
    if($Rebuild and not $TargetElement and $TargetVersion)
    { # rebuild previous ABI dump
        my $PV = undef;
        
        foreach my $V (reverse(@Versions))
        {
            if($V eq $TargetVersion)
            {
                if(defined $PV)
                {
                    createABIDump($PV);
                    last;
                }
            }
            $PV = $V;
        }
    }
    
    if(checkTarget("abiview"))
    {
        foreach my $V (@Versions)
        {
            if(skipVersion_T($V)) {
                next;
            }
            
            createABIView($V);
        }
    }
    
    foreach my $P (0 .. $#Versions)
    {
        my $V = $Versions[$P];
        my $O_V = undef;
        if($P<$#Versions) {
            $O_V = $Versions[$P+1];
        }
        
        if(skipVersion_T($V)) {
            next;
        }
        
        if(defined $O_V)
        {
            if(checkTarget("abireport"))
            {
                createABIReport($O_V, $V);
            }
            
            if(checkTarget("rfcdiff")
            or checkTarget("headersdiff"))
            {
                diffHeaders($O_V, $V);
            }
            
            if(checkTarget("pkgdiff")
            or checkTarget("packagediff"))
            {
                if($V ne "current") {
                    createPkgdiff($O_V, $V);
                }
            }
        }
    }
    
    if(defined $Profile->{"Versions"}{"current"})
    { # save pull/update time of the code repository
        if(-d $Profile->{"Versions"}{"current"}{"Installed"})
        {
            if(my $UTime = getScmUpdateTime()) {
                $DB->{"ScmUpdateTime"} = $UTime;
            }
        }
    }
    
    if(defined $TargetElement
    and $TargetElement eq "graph")
    {
        my $First = $Versions[$#Versions];
        my $Total = 0;
        
        foreach my $Md5 (sort keys(%{$DB->{"ABIDump"}{$First}}))
        {
            my $Dump = $DB->{"ABIDump"}{$First}{$Md5};
            if(skipLib($Dump->{"Object"})) {
                next;
            }
            
            $Total += countSymbolsF($Dump, $First);
        }
        
        my $Scatter = {};
        $Scatter->{$First} = 0;
        
        foreach my $P (0 .. $#Versions)
        {
            my $V = $Versions[$P];
            my $O_V = undef;
            if($P<$#Versions) {
                $O_V = $Versions[$P+1];
            }
            
            if(defined $DB->{"ABIReport"} and defined $DB->{"ABIReport"}{$O_V}
            and defined $DB->{"ABIReport"}{$O_V}{$V})
            {
                my $ABIReport = $DB->{"ABIReport"}{$O_V}{$V};
                
                my $Added = $ABIReport->{"Added"};
                my $Removed = $ABIReport->{"Removed"};
                
                my $AddedByObjects = $ABIReport->{"ObjectsAddedSymbols"};
                my $RemovedByObjects = $ABIReport->{"ObjectsRemovedSymbols"};
                
                $Scatter->{$V} = $Added - $Removed + $AddedByObjects - $RemovedByObjects;
            }
        }
        
        my @Order = reverse(@Versions);
        
        simpleGraph($Scatter, \@Order, $Total);
    }
}

sub countSymbolsF($$)
{
    my ($Dump, $V) = @_;
    
    if(defined $Dump->{"TotalSymbolsFiltered"})
    {
        if(not defined $DisableCache) {
            return $Dump->{"TotalSymbolsFiltered"};
        }
    }
    
    my $AccOpts = getABICC_Options();
    
    if($AccOpts=~/list|skip/)
    {
        my $Path = $Dump->{"Path"};
        printMsg("INFO", "Counting symbols in the ABI dump for \'".getFilename($Dump->{"Object"})."\' ($V)");
        
        my $Count = qx/$ABI_CC -count-symbols \"$Path\" $AccOpts/;
        chomp($Count);
        
        return ($Dump->{"TotalSymbolsFiltered"} = $Count);
    }
    
    if(not defined $Dump->{"TotalSymbols"})
    { # support for old data
        print STDERR "WARNING: TotalSymbols property is missed, reading ABI dump for ".$Dump->{"Object"}." ($V) ...\n";
        $Dump->{"TotalSymbols"} = countSymbols($Dump);
    }
    elsif(not defined $Dump->{"Version"}
    or cmpVersions_S($Dump->{"Version"}, "1.7")<0)
    { # TotalSymbols is fixed in 1.7
        print STDERR "WARNING: TotalSymbols property contains obsolete data, reading ABI dump for ".$Dump->{"Object"}." ($V) ...\n";
        $Dump->{"TotalSymbols"} = countSymbols($Dump);
    }
    
    return ($Dump->{"TotalSymbolsFiltered"} = $Dump->{"TotalSymbols"});
}

sub countSymbols($)
{
    my $Dump = $_[0];
    my $Path = $Dump->{"Path"};
    
    printMsg("INFO", "Counting symbols in the ABI dump for \'".getFilename($Dump->{"Object"})."\'");
    
    my $Total = qx/$ABI_CC -count-symbols \"$Path\"/;
    chomp($Total);
    
    return $Total;
}

sub simpleGraph($$$)
{
    my ($Scatter, $Order, $StartVal) = @_;
    
    my @Vs = @{$Order};
    
    if($Vs[$#Vs] eq "current") {
        pop(@Vs);
    }
    
    my $MinVer = $Vs[0];
    my $MaxVer = $Vs[$#Vs];
    
    my $MinRange = undef;
    my $MaxRange = undef;
    
    my $Content = "";
    my $Val_Pre = $StartVal;
    
    foreach (0 .. $#Vs)
    {
        my $V = $Vs[$_];
        
        my $Val = $Val_Pre + $Scatter->{$V};
        
        if(not defined $MinRange) {
            $MinRange = $Val;
        }
        
        if(not defined $MaxRange) {
            $MaxRange = $Val;
        }
        
        if($Val<$MinRange) {
            $MinRange = $Val;
        }
        elsif($Val>$MaxRange) {
            $MaxRange = $Val;
        }
        
        my $V_S = $V;
        
        if(defined $Profile->{"GraphShortXTics"})
        {
            if($V=~tr!\.!!>=2) {
                $V_S = getMajor($V);
            }
            elsif($V=~/\A(20\d\d)\d\d\d\d\Z/)
            { # 20160507
                $V_S = $1;
            }
            elsif($V=~/\A(.+)\-\d\d\d\d\d\d\d\d\Z/)
            { # 0.12-20140410
                $V_S = $1;
            }
        }
        
        $V_S=~s/\-(alpha|beta|rc)\d*\Z//g;
        
        $Content .= $_."  ".$Val;
        
        if($_==0 or $_==$#Vs
        or $_==int($#Vs/2)
        or $_==int($#Vs/4)
        or $_==int(3*$#Vs/4)) {
            $Content .= "  ".$V_S;
        }
        $Content .= "\n";
        
        $Val_Pre = $Val;
    }
    
    my $Delta = $MaxRange - $MinRange;
    
    $MinRange -= int($Delta*5/100);
    $MaxRange += int($Delta*5/100);
    
    if($MaxRange-$MinRange<20)
    {
        $MinRange -= 5;
        $MaxRange += 5;
    }
    
    my $Data = $TMP_DIR."/graph.data";
    
    writeFile($Data, $Content);
    
    my $Title = ""; # Timeline of ABI changes
    
    my $GraphPath = "graph/$TARGET_LIB/graph.png";
    mkpath(getDirname($GraphPath));
    
    my $Cmd = "gnuplot -e \"set title \'$Title\';";
    $Cmd .= "set xlabel '".showTitle()." version';";
    $Cmd .= "set ylabel 'ABI symbols';";
    $Cmd .= "set xrange [0:".$#Vs."];";
    $Cmd .= "set yrange [$MinRange:$MaxRange];";
    $Cmd .= "set terminal png size 400,300;";
    $Cmd .= "set output \'$GraphPath\';";
    $Cmd .= "set nokey;";
    $Cmd .= "set xtics font 'Times, 12';";
    $Cmd .= "set ytics font 'Times, 12';";
    $Cmd .= "set xlabel font 'Times, 12';";
    $Cmd .= "set ylabel font 'Times, 12';";
    $Cmd .= "set style line 1 linecolor rgbcolor 'red' linewidth 2;";
    $Cmd .= "set style increment user;";
    $Cmd .= "plot \'$Data\' using 2:xticlabels(3) with lines\"";
    
    system($Cmd);
    unlink($Data);
}

sub findObjects($)
{
    my $Dir = $_[0];
    
    my @Files = ();
    
    if($Profile->{"Mode"} eq "Kernel")
    {
        @Files = findFiles($Dir, "f", ".*\\.ko");
        @Files = (@Files, findFiles($Dir, "f", "", "vmlinux"));
    }
    else
    {
        @Files = findFiles($Dir, "f", ".*\\.so\\..*");
        @Files = (@Files, findFiles($Dir, "f", ".*\\.so"));
    }
    
    my @Res = ();
    
    foreach my $F (@Files)
    {
        if(-B $F) {
            push(@Res, $F);
        }
    }
    
    return @Res;
}

sub findHeaders($)
{
    my $Dir = $_[0];
    
    if(-d $Dir."/include") {
        $Dir .= "/include";
    }
    
    my @Files = findFiles($Dir, "f");
    my @Headers = ();
    
    foreach my $File (sort {lc($a) cmp lc($b)} @Files)
    {
        if($File=~/\.(so|pc)(\Z|\.)/) {
            next;
        }
        
        push(@Headers, $File);
    }
    
    return @Headers;
}

sub detectSoname($)
{
    if($Profile->{"Mode"} eq "Kernel") {
        return 0;
    }
    
    my $V = $_[0];
    
    if(not $Rebuild)
    {
        if(defined $DB->{"Soname"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"Soname"}{$V}); # empty cache
    delete($DB->{"Sover"}{$V}); # empty cache
    
    printMsg("INFO", "Detecting soname of $V");
    
    my $Installed = $Profile->{"Versions"}{$V}{"Installed"};
    
    if(not -d $Installed) {
        return 0;
    }
    
    my @Objects = findObjects($Installed);
    
    my %Sovers = ();
    
    foreach my $Path (@Objects)
    {
        my $RPath = $Path;
        $RPath=~s/\A\Q$Installed\E\/*//;
        
        if(skipLib($RPath)) {
            next;
        }
        
        if(readBytes($Path) eq "7f454c46")
        {
            if(my $Soname = getSoname($Path))
            {
                $DB->{"Soname"}{$V}{$RPath} = $Soname;
                
                if((my $Ver = getSover($Soname)) ne "") {
                    $Sovers{$Ver} = 1;
                }
            }
            else {
                $DB->{"Soname"}{$V}{$RPath} = "None";
            }
        }
    }
    
    my $Sover = "None";
    
    if(defined $Profile->{"SkipSoversions"})
    {
        foreach my $Skip (@{$Profile->{"SkipSoversions"}})
        {
            if(defined $Sovers{$Skip}) {
                delete($Sovers{$Skip});
            }
        }
    }
    
    if(my @S = sort keys(%Sovers))
    {
        if($#S==0) {
            $Sover = $S[0];
        }
        else
        {
            $Sover = join("/", @S);
        }
    }
    
    $DB->{"Sover"}{$V} = $Sover;
}

sub skipHeader($) {
    return matchFile($_[0], "SkipHeaders");
}

sub skipLib($) {
    return matchFile($_[0], "SkipObjects");
}

sub matchFile($$)
{
    my ($Path, $Tag) = @_;
    
    if(defined $Profile->{$Tag})
    {
        my $Name = getFilename($Path);
        my @Skip = @{$Profile->{$Tag}};
        
        foreach my $L (@Skip)
        {
            if($L eq $Name)
            { # exact match
                return 1;
            }
            elsif($L=~/\/\Z/)
            { # directory
                if($Path=~/\Q$L\E/) {
                    return 1;
                }
            }
            else
            { # file
                if($L=~/[\*\+\(\|\\]/)
                { # pattern
                    if($Name=~/\A$L\Z/) {
                        return 1;
                    }
                }
                elsif($Tag eq "SkipObjects")
                { # short name
                    $L = getObjectName($L, "Short");
                    
                    if($L eq getObjectName($Name, "Short")) {
                        return 1;
                    }
                }
            }
        }
    }
    
    return 0;
}

sub getSover($)
{
    my $Name = $_[0];
    
    my ($Pre, $Post) = (undef, undef);
    
    if($Name=~/\.so\.([\w\.\-]+)/) {
        $Post = $1;
    }
    
    $Name=~s/x11//ig;
    
    if($Name=~/(\d+[\d\.]*\-[\w\.\-]*)\.so(\.|\Z)/)
    { # libMagickCore6-Q16.so.1
        $Pre = $1;
    }
    elsif($Name=~/\-([a-zA-Z]?\d[\w\.\-]*)\.so(\.|\Z)/)
    { # libMagickCore-6.Q16.so.1
      # libMagickCore-Q16.so.7
        $Pre = $1;
    }
    elsif(not defined $Post and $Name=~/([\d\.])\.so(\.|\Z)/) {
        $Pre = $1;
    }
    
    my @V = ();
    if(defined $Pre) {
        push(@V, $Pre);
    }
    if(defined $Post) {
        push(@V, $Post);
    }
    
    if(@V) {
        return join(".", @V);
    }
    
    return undef;
}

sub getSoname($)
{
    my $Path = $_[0];
    
    my $Soname = `objdump -p \"$Path\"|grep SONAME`;
    chomp($Soname);
    
    if($Soname=~/SONAME\s+([^ ]+)/) {
        return $1;
    }
    
    return undef;
}

sub updateRequired($)
{
    my $V = $_[0];
    
    if($V eq "current")
    {
        if($DB->{"ScmUpdateTime"})
        {
            if(my $UTime = getScmUpdateTime())
            {
                if($DB->{"ScmUpdateTime"} ne $UTime)
                {
                    return 1;
                }
            }
        }
    }
    
    return 0;
}

sub createChangelog($$)
{
    my $V = $_[0];
    my $First = $_[1];
    
    if(defined $Profile->{"Versions"}{$V}{"Changelog"})
    {
        if($Profile->{"Versions"}{$V}{"Changelog"} eq "Off"
        or index($Profile->{"Versions"}{$V}{"Changelog"}, "://")!=-1)
        {
            return 0;
        }
    }
    
    if(not $Rebuild)
    {
        if(defined $DB->{"Changelog"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Creating changelog for $V");
    
    my $Source = $Profile->{"Versions"}{$V}{"Source"};
    my $ChangelogPath = undef;
    
    if(not -e $Source)
    {
        printMsg("ERROR", "Can't access \'$Source\'");
        return 0;
    }
    
    my $TmpDir = $TMP_DIR."/log/";
    mkpath($TmpDir);
    
    if($V eq "current")
    {
        $ChangelogPath = "$TmpDir/log";
        chdir($Source);
        
        my $Cmd_L = undef;
        if(defined $Profile->{"Git"})
        {
            $Cmd_L = "git log -100 --date=iso >$ChangelogPath";
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Cmd_L = "svn log -l100 >$ChangelogPath";
        }
        else
        {
            printMsg("ERROR", "Unknown type of source code repository");
            return 0;
        }
        qx/$Cmd_L/; # execute
        appendFile($ChangelogPath, "\n...");
        chdir($ORIG_DIR);
    }
    else
    {
        if(my $Cmd_E = extractPackage($Source, $TmpDir))
        {
            qx/$Cmd_E/; # execute
            if($?)
            {
                printMsg("ERROR", "Failed to extract package \'".getFilename($Source)."\'");
                return 0;
            }
        }
        else
        {
            printMsg("ERROR", "Unknown package format \'".getFilename($Source)."\'");
            return 0;
        }
        
        my @Files = listDir($TmpDir);
        
        if($#Files==0) {
            $TmpDir .= "/".$Files[0];
        }
        
        if(defined $Profile->{"Versions"}{$V}{"Changelog"})
        {
            my $Target = $Profile->{"Versions"}{$V}{"Changelog"};
            
            if($Target eq "On")
            {
                my $Found = findChangelog($TmpDir);
                
                if($Found and $Found ne "None") {
                    $ChangelogPath = $TmpDir."/".$Found;
                }
            }
            else
            { # name of the changelog
                if(-f $TmpDir."/".$Target
                and -s $TmpDir."/".$Target)
                {
                    $ChangelogPath = $TmpDir."/".$Target;
                }
            }
        }
    }
    
    my $Dir = "changelog/$TARGET_LIB/$V";
    
    if($ChangelogPath)
    {
        my $Html = toHtml($V, $ChangelogPath, $First);
        
        writeFile($Dir."/log.html", $Html);
        
        $DB->{"Changelog"}{$V} = $Dir."/log.html";
    }
    else
    {
        rmtree($Dir);
        $DB->{"Changelog"}{$V} = "Off";
    }
    
    rmtree($TmpDir);
}

sub toHtml($$$)
{
    my ($V, $Path, $First) = @_;
    my $Content = readFile($Path);
    
    my $LIM = 500000;
    
    if(not $First and $V ne "current") {
        $LIM /= 20;
    }
    
    if(length($Content)>$LIM)
    {
        $Content = substr($Content, 0, $LIM);
        $Content .= "\n...";
    }
    
    $Content = htmlSpecChars($Content, 1);
    
    my $Title = showTitle()." ".$V.": changelog";
    my $Keywords = showTitle().", $V, changes, changelog";
    my $Desc = "Log of changes in the package";
    
    $Content = "\n<div class='changelog'>\n<pre class='wrap'>$Content</pre></div>\n";
    
    if($V eq "current")
    {
        my $Note = "source repository";
        if(defined $Profile->{"Git"})
        {
            $Note = "Git";
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Note = "Svn";
        }
        
        $Content = "<h1>Changelog from $Note</h1><br/><br/>".$Content;
    }
    else {
        $Content = "<h1>Changelog for <span class='version'>$V</span> version</h1><br/><br/>".$Content;
    }
    $Content = getHead("changelog").$Content;
    
    $Content = composeHTML_Head($Title, $Keywords, $Desc, getTop("changelog"), "changelog.css", "")."\n<body>\n$Content\n</body>\n</html>\n";
    
    return $Content;
}

sub htmlSpecChars(@)
{
    my $S = shift(@_);
    
    my $Sp = 0;
    
    if(@_) {
        $Sp = shift(@_);
    }
    
    $S=~s/\&([^#])/&amp;$1/g;
    $S=~s/</&lt;/g;
    $S=~s/>/&gt;/g;
    
    if(not $Sp)
    {
        $S=~s/([^ ]) ([^ ])/$1\@SP\@$2/g;
        $S=~s/([^ ]) ([^ ])/$1\@SP\@$2/g;
        $S=~s/ /&nbsp;/g;
        $S=~s/\@SP\@/ /g;
        $S=~s/\n/\n<br\/>/g;
    }
    
    return $S;
}

sub findChangelog($)
{
    my $Dir = $_[0];
    
    foreach my $Name ("NEWS", "CHANGES", "CHANGES.txt", "RELEASE_NOTES", "ChangeLog", "Changelog",
    "RELEASE_NOTES.md", "RELEASE_NOTES.markdown")
    {
        if(-f $Dir."/".$Name
        and -s $Dir."/".$Name)
        {
            return $Name;
        }
    }
    
    return "None";
}

sub getScmUpdateTime()
{
    if(my $Source = $Profile->{"Versions"}{"current"}{"Source"})
    {
        if(not -d $Source) {
            return undef;
        }
        
        my $Time = undef;
        my $Head = undef;
        
        if(defined $Profile->{"Git"})
        {
            $Head = "$Source/.git/refs/heads/master";
            
            if(not -f $Head)
            { # is not updated yet
                $Head = "$Source/.git/FETCH_HEAD";
            }
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Head = "$Source/.svn/wc.db";
            
            if(not -f $Head)
            {
                $Head = undef;
            }
        }
        
        if($Head)
        {
            $Time = `stat -c \%Y \"$Head\"`;
            chomp($Time);
        }
        
        if($Time) {
            return $Time;
        }
    }
    
    return undef;
}

sub checkTarget($)
{
    my $Elem = $_[0];
    
    if(defined $TargetElement)
    {
        if($Elem ne $TargetElement)
        {
            return 0;
        }
    }
    
    return 1;
}

sub detectDate($)
{
    my $V = $_[0];
    
    if(not $Rebuild)
    {
        if(defined $DB->{"Date"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Detecting date of $V");
    
    my $Source = $Profile->{"Versions"}{$V}{"Source"};
    my $Date = undef;
    
    if($V eq "current")
    {
        if(defined $Profile->{"Git"})
        {
            chdir($Source);
            my $Log = `git log -1 --date=iso`;
            chdir($ORIG_DIR);
            
            if($Log=~/ (\d+\-\d+\-\d+ \d+:\d+:\d+) /)
            {
                $Date = $1;
            }
        }
        elsif(defined $Profile->{"Svn"})
        {
            chdir($Source);
            my $Log = `svn log -l1`;
            chdir($ORIG_DIR);
            
            if($Log=~/ (\d+\-\d+\-\d+ \d+:\d+:\d+) /)
            {
                $Date = $1;
            }
        }
        else
        {
            printMsg("ERROR", "Unknown type of source code repository");
            return 0;
        }
    }
    else
    {
        my @Files = listPackage($Source);
        my %Dates = ();
        
        my $Zip = ($Source=~/\.(zip|jar)\Z/i);
        
        foreach my $Line (@Files)
        {
            if($Line!~/\Ad/ # skip directories
            and $Line=~/ (\d+)\-(\d+)\-(\d+) (\d+:\d+) /)
            {
                my $Date = undef;
                my $Time = $4;
                
                if($Zip) {
                    $Date = $3."-".$1."-".$2;
                }
                else {
                    $Date = $1."-".$2."-".$3;
                }
                
                $Dates{$Date." ".$Time} = 1;
            }
        }
        
        if(my @Sorted = sort {$b cmp $a} keys(%Dates)) {
            $Date = $Sorted[0];
        }
    }
    
    if(defined $Date)
    {
        $DB->{"Date"}{$V} = $Date;
    }
}

sub listPackage($)
{
    my $Path = $_[0];
    
    my $Cmd = "";
    
    if($Path=~/\.(tar\.\w+|tgz|tbz2)\Z/i) {
        $Cmd = "tar -tvf \"$Path\"";
    }
    elsif($Path=~/\.zip\Z/i) {
        $Cmd = "unzip -l $Path";
    }
    
    if($Cmd)
    {
        my @Res = split(/\n/, `$Cmd 2>/dev/null`);
        return @Res;
    }
    
    return ();
}

sub createABIDump($)
{
    my $V = $_[0];
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIDump"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"ABIDump"}{$V}); # empty cache
    
    printMsg("INFO", "Creating ABI dump for $V");
    
    my $Installed = $Profile->{"Versions"}{$V}{"Installed"};
    
    if(not -d $Installed) {
        return 0;
    }
    
    my @Objects = findObjects($Installed);
    
    my $Dir = "abi_dump/$TARGET_LIB/$V";
    
    if(-d $Dir) {
        rmtree($Dir);
    }
    
    if(not @Objects)
    {
        printMsg("ERROR", "can't find objects");
        return;
    }
    
    my $TmpDir = $TMP_DIR."/objects";
    
    foreach my $Object (sort {lc($a) cmp lc($b)} @Objects)
    {
        my $RPath = $Object;
        $RPath=~s/\A\Q$Installed\E\/*//;
        
        if(skipLib($RPath)) {
            next;
        }
        
        printMsg("INFO", "Creating ABI dump for $RPath");
        
        my $Md5 = getMd5($RPath);
        
        my $ABIDir = $Dir."/".$Md5;
        my $ABIDump = $ABIDir."/ABI.dump";
        
        my $Cmd = $ABI_DUMPER." \"".$Object."\" -output \"".$ABIDump."\" -lver \"$V\"";
        
        if(not $Profile->{"PrivateABI"}
        or $Profile->{"PrivateABI"} eq "Off")
        { # set "PrivateABI":1 in the profile to check all symbols
            if($Profile->{"Mode"} eq "Kernel") {
                $Cmd .= " -kernel-export";
            }
            else
            {
                $Cmd .= " -public-headers \"$Installed\"";
                if($Profile->{"UseTUDump"})
                {
                    $Cmd .= " -use-tu-dump -cache-headers \"$TmpDir\"";
                    
                    if(my $IncPreamble = $Profile->{"IncludePreamble"}) {
                        $Cmd .= " -include-preamble \"$IncPreamble\"";
                    }
                    
                    if(my $IncPaths = $Profile->{"IncludePaths"}) {
                        $Cmd .= " -include-paths \"$IncPaths\"";
                    }
                }
                else {
                    $Cmd .= " -ignore-tags \"$MODULES_DIR/ignore.tags\"";
                }
                
                if($Profile->{"ReimplementStd"}) {
                    $Cmd .= " -reimplement-std";
                }
            }
        }
        
        if($ABI_DUMPER_EE)
        {
            $Cmd .= " -extra-dump";
            $Cmd .= " -extra-info \"".$Dir."/".$Md5."/debug/\"";
        }
        
        if($Debug) {
            printMsg("DEBUG", "executing $Cmd");
        }
        
        my $Log = `$Cmd`; # execute
        
        if(-f $ABIDump)
        {
            $DB->{"ABIDump"}{$V}{$Md5}{"Path"} = $ABIDump;
            $DB->{"ABIDump"}{$V}{$Md5}{"Object"} = $RPath;
            
            my $ABI = eval(readFile($ABIDump));
            $DB->{"ABIDump"}{$V}{$Md5}{"Lang"} = $ABI->{"Language"};
            
            my $TotalSymbols = countSymbols($DB->{"ABIDump"}{$V}{$Md5});
            $DB->{"ABIDump"}{$V}{$Md5}{"TotalSymbols"} = $TotalSymbols;
            
            $DB->{"ABIDump"}{$V}{$Md5}{"Version"} = $TOOL_VERSION;
            
            my @Meta = ();
            
            push(@Meta, "\"Object\": \"".$RPath."\"");
            push(@Meta, "\"Lang\": \"".$ABI->{"Language"}."\"");
            push(@Meta, "\"TotalSymbols\": \"".$TotalSymbols."\"");
            push(@Meta, "\"PublicABI\": \"1\"");
            push(@Meta, "\"Version\": \"".$TOOL_VERSION."\"");
            
            writeFile($Dir."/".$Md5."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
        }
        else
        {
            printMsg("ERROR", "can't create ABI dump");
            rmtree($ABIDir);
        }
    }
    
    if(-d $TmpDir) {
        rmtree($TmpDir);
    }
}

sub getObjectName($$)
{
    my ($Object, $T) = @_;
    
    my $Name = getFilename($Object);
    
    if($T eq "Short")
    {
        if($Name=~/\A(.+)\.(so|ko)[\d\.]*\Z/) {
            return $1;
        }
    }
    elsif($T eq "SuperShort")
    {
        if($Name=~/\A(.+?)(\d+[\d\.]*\-[\w\.\-]*)\.so\./) {
            return $1;
        }
        elsif($Name=~/\A(.+?)\-([a-zA-Z]?\d[\w\.\-]*)\.so\./) {
            return $1;
        }
        elsif($Name=~/\A(.+?)[\d\.\-\_]*\.so[\d\.]*\Z/) {
            return $1;
        }
    }
    
    return undef;
}

sub createABIView($)
{
    my $V = $_[0];
    
    if($Profile->{"Versions"}{$V}{"ABIView"} ne "On"
    and not (defined $TargetVersion and defined $TargetElement)) {
        return 0;
    }
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIView"}{$V})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    if(not getToolVer($ABI_VIEWER))
    {
        printMsg("ERROR", "ABI Viewer is not installed");
        return 0;
    }
    
    if(not $ABI_DUMPER_EE)
    {
        printMsg("ERROR", "ABI Dumper EE is not installed");
        return 0;
    }
    
    printMsg("INFO", "Creating ABI View for $V");
    
    if(not defined $DB->{"ABIDump"}{$V})
    {
        createABIDump($V);
    }
    
    my $D = $DB->{"ABIDump"}{$V};
    
    if(not $D) {
        return 0;
    }
    
    my @Objects = ();
    
    foreach my $Md5 (sort keys(%{$D})) {
        push(@Objects, $D->{$Md5}{"Object"});
    }
    
    @Objects = sort {lc($a) cmp lc($b)} @Objects;
    
    foreach my $Object (@Objects)
    {
        if(skipLib($Object)) {
            next;
        }
        
        createABIView_Object($V, $Object);
    }
    
    my $Report = "";
    
    $Report .= getHead("objects_view");
    $Report .= "<h1>View objects ABI: <span class='version'>$V</span></h1>\n";
    $Report .= "<br/>\n";
    $Report .= "<br/>\n";
    
    $Report .= "<table class='summary'>\n";
    $Report .= "<tr>";
    $Report .= "<th>Object</th>\n";
    $Report .= "<th>ABI View</th>\n";
    $Report .= "</tr>\n";
    
    foreach my $Object (@Objects)
    {
        if(skipLib($Object)) {
            next;
        }
        
        my $Name = $Object;
        $Name=~s/\Alib(64|32|)\///;
        
        $Report .= "<tr>\n";
        $Report .= "<td class='object'>$Name</td>\n";
        
        my $Md5 = getMd5($Object);
        if(defined $DB->{"ABIView_D"}{$V}{$Md5})
        {
            my $ABIView_D = $DB->{"ABIView_D"}{$V}{$Md5};
            $Report .= "<td><a target='_blank' href='../../../".$ABIView_D->{"Path"}."'>view</a></td>\n";
        }
        else {
            $Report .= "<td>N/A</td>\n";
        }
        
        $Report .= "</tr>\n";
    }
    $Report .= "</table>\n";
    
    $Report .= getSign("Other");
    
    my $Title = showTitle().": View objects ABI of $V version";
    my $Keywords = showTitle().", ABI, view, report";
    my $Desc = "View objects ABI of the $TARGET_LIB $V";
    
    $Report = composeHTML_Head($Title, $Keywords, $Desc, getTop("objects_view"), "report.css", "")."\n<body>\n$Report\n</body>\n</html>\n";
    
    my $Dir = "objects_view/$TARGET_LIB/$V";
    my $Output = $Dir."/report.html";
    
    writeFile($Output, $Report);
    
    $DB->{"ABIView"}{$V}{"Path"} = $Output;
}

sub createABIReport($$)
{
    my ($V1, $V2) = @_;
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIReport"}{$V1}{$V2})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"ABIReport"}{$V1}{$V2}); # empty cache
    
    printMsg("INFO", "Creating objects ABI report between $V1 and $V2");
    
    my $Cols = 5;
    my $ABIDiff = $Profile->{"Versions"}{$V2}{"ABIDiff"};
    
    if($ABIDiff eq "On")
    {
        if(not getToolVer($ABI_VIEWER))
        {
            printMsg("ERROR", "ABI Viewer is not installed");
            return 0;
        }
        
        if(not $ABI_DUMPER_EE)
        {
            printMsg("ERROR", "ABI Dumper EE is not installed");
            return 0;
        }
    }
    
    if($ABIDiff ne "On") {
        $Cols-=1;
    }
    
    if($Profile->{"CompatRate"} eq "Off") {
        $Cols-=1;
    }
    
    if(not $Profile->{"ShowTotalProblems"}) {
        $Cols-=1;
    }
    
    if(not defined $DB->{"Soname"}{$V1}) {
        detectSoname($V1);
    }
    if(not defined $DB->{"Soname"}{$V2}) {
        detectSoname($V2);
    }
    
    if($V2 eq "current")
    { # NOTE: additional check of consistency
        if(defined $DB->{"ABIDump"}{$V2})
        {
            my $IPath = $Profile->{"Versions"}{$V2}{"Installed"};
            foreach my $Md (sort keys(%{$DB->{"ABIDump"}{$V2}}))
            {
                if(not -e $IPath."/".$DB->{"ABIDump"}{$V2}{$Md}{"Object"})
                {
                    print STDERR "WARNING: It's necessary to regenerate ABI dump for $V2\n";
                    delete($DB->{"ABIDump"}{$V2});
                    last;
                }
            }
            
            if(defined $DB->{"ABIDump"}{$V2})
            {
                foreach my $Obj (sort keys(%{$DB->{"Soname"}{$V2}}))
                {
                    if(not defined $DB->{"ABIDump"}{$V2}{getMd5($Obj)})
                    {
                        print STDERR "WARNING: It's necessary to regenerate ABI dump for $V2\n";
                        delete($DB->{"ABIDump"}{$V2});
                        last;
                    }
                }
            }
        }
    }
    
    if(not defined $DB->{"ABIDump"}{$V1}) {
        createABIDump($V1);
    }
    if(not defined $DB->{"ABIDump"}{$V2}) {
        createABIDump($V2);
    }
    
    my $D1 = $DB->{"ABIDump"}{$V1};
    my $D2 = $DB->{"ABIDump"}{$V2};
    
    if(not $D1 or not $D2) {
        return 0;
    }
    
    my (@Objects1, @Objects2) = ();
    
    foreach my $Md5 (sort keys(%{$D1}))
    {
        my $Obj = $D1->{$Md5}{"Object"};
        if(skipLib($Obj)) {
            next;
        }
        push(@Objects1, $Obj);
    }
    
    foreach my $Md5 (sort keys(%{$D2}))
    {
        my $Obj = $D2->{$Md5}{"Object"};
        if(skipLib($Obj)) {
            next;
        }
        push(@Objects2, $Obj);
    }
    
    if($Profile->{"Mode"} eq "Kernel")
    { # move vmlinux to the top of the report
        @Objects1 = sort {lc(getFilename($a)) cmp lc(getFilename($b))} @Objects1;
        @Objects2 = sort {lc(getFilename($a)) cmp lc(getFilename($b))} @Objects2;
        
        @Objects1 = sort {($b eq "vmlinux") cmp ($a eq "vmlinux")} @Objects1;
    }
    else
    {
        @Objects1 = sort {lc($a) cmp lc($b)} @Objects1;
        @Objects2 = sort {lc($a) cmp lc($b)} @Objects2;
    }
    
    my %SonameObject2 = ();
    my %ShortName2 = ();
    my %SShortName2 = ();
    
    if(defined $DB->{"Soname"}{$V2})
    {
        foreach my $Object2 (keys(%{$DB->{"Soname"}{$V2}}))
        {
            if($DB->{"Soname"}{$V2}{$Object2} ne "None") {
                $SonameObject2{$DB->{"Soname"}{$V2}{$Object2}}{$Object2} = 1;
            }
        }
    }
    
    foreach my $Object2 (@Objects2)
    {
        if(my $Short = getObjectName($Object2, "Short")) {
            $ShortName2{$Short}{$Object2} = 1;
        }
        
        if(my $SShort = getObjectName($Object2, "SuperShort")) {
            $SShortName2{$SShort}{$Object2} = 1;
        }
    }
    
    my (%Added, %Removed, %Mapped, %Mapped_R, %ChangedSoname, %RenamedObject) = ();
    
    # Match objects
    foreach my $Object1 (@Objects1)
    {
        my $Object2 = undef;
        
        # Try to match by SONAME
        my $Soname1 = undef;
        if(defined $DB->{"Soname"}{$V1}
        and defined $DB->{"Soname"}{$V1}{$Object1}
        and $DB->{"Soname"}{$V1}{$Object1} ne "None")
        {
            $Soname1 = $DB->{"Soname"}{$V1}{$Object1};
        }
        if($Soname1)
        {
            if(defined $SonameObject2{$Soname1})
            {
                my @Pair = keys(%{$SonameObject2{$Soname1}});
                
                if($#Pair==0) {
                    $Object2 = $Pair[0];
                }
                else {
                    printMsg("ERROR", "two or more objects with the same SONAME found");
                }
            }
        }
        
        # Try to match by name
        if(not $Object2)
        {
            if(grep {$_ eq $Object1} @Objects2) {
                $Object2 = $Object1;
            }
        }
        
        # Try to match by short name
        if(not $Object2)
        {
            my $Short = getObjectName($Object1, "Short");
            
            if(defined $ShortName2{$Short})
            {
                my @Pair = keys(%{$ShortName2{$Short}});
                
                if($#Pair==0) {
                    $Object2 = $Pair[0];
                }
            }
        }
        
        # Try to match by very short name
        if(not $Object2)
        {
            my $SShort = getObjectName($Object1, "SuperShort");
            
            if(defined $SShortName2{$SShort})
            {
                my @Pair = keys(%{$SShortName2{$SShort}});
                
                if($#Pair==0) {
                    $Object2 = $Pair[0];
                }
            }
        }
        
        if($Object2)
        {
            $Mapped{$Object1} = $Object2;
            $Mapped_R{$Object2} = $Object1;
        }
        else {
            $Removed{$Object1} = 1;
        }
    }
    
    foreach my $Object2 (@Objects2)
    {
        if(not defined $Mapped_R{$Object2}) {
            $Added{$Object2} = 1;
        }
    }
    
    if(not keys(%Mapped))
    {
        if($#Objects1==0 and $#Objects2==0)
        {
            $Mapped{$Objects1[0]} = $Objects2[0];
            $RenamedObject{$Objects1[0]} = $Objects2[0];
            
            delete($Removed{$Objects1[0]});
            delete($Added{$Objects2[0]});
        }
    }
    
    my @Objects = sort keys(%Mapped);
    
    # Detect changed SONAME
    foreach my $Object1 (@Objects)
    {
        my $Object2 = $Mapped{$Object1};
        
        my ($Soname1, $Soname2) = (getFilename($Object1), getFilename($Object2));
        
        if(defined $DB->{"Soname"}{$V1}
        and defined $DB->{"Soname"}{$V1}{$Object1}
        and $DB->{"Soname"}{$V1}{$Object1} ne "None")
        {
            $Soname1 = $DB->{"Soname"}{$V1}{$Object1};
        }
        
        if(defined $DB->{"Soname"}{$V2}
        and defined $DB->{"Soname"}{$V2}{$Object2}
        and $DB->{"Soname"}{$V2}{$Object2} ne "None")
        {
            $Soname2 = $DB->{"Soname"}{$V2}{$Object2};
        }
        
        if($Soname1 and $Soname2 and $Soname1 ne $Soname2)
        {
            $ChangedSoname{$Object1}{"From"} = $Soname1;
            $ChangedSoname{$Object1}{"To"} = $Soname2;
        }
    }
    
    if(not $ObjectsReport)
    {
        if($Rebuild)
        {
            # Remove old reports
            my $CDir = "compat_report/$TARGET_LIB/$V1/$V2";
            
            if(-d $CDir) {
                rmtree($CDir);
            }
        }
        
        foreach my $Object1 (@Objects)
        {
            if(skipLib($Object1)) {
                next;
            }
            compareABIs($V1, $V2, $Object1, $Mapped{$Object1});
            
            if($ABIDiff eq "On") {
                diffABIs($V1, $V2, $Object1, $Mapped{$Object1});
            }
        }
    }
    
    my $Report = "";
    
    $Report .= getHead("objects_report");
    $Report .= "<h1>Objects ABI report: <span class='version'>$V1</span> vs <span class='version'>$V2</span></h1>\n"; # API/ABI changes report
    $Report .= "<br/>\n";
    $Report .= "<br/>\n";
    
    $Report .= "<table class='summary'>\n";
    $Report .= "<tr>";
    $Report .= "<th>Object</th>\n";
    if($Profile->{"CompatRate"} ne "Off") {
        $Report .= "<th>Backward<br/>Compatibility</th>\n";
    }
    $Report .= "<th>Added<br/>Symbols</th>\n";
    $Report .= "<th>Removed<br/>Symbols</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Report .= "<th>Total<br/>Changes</th>\n";
    }
    if($ABIDiff eq "On") {
        $Report .= "<th title='Generated by the ABI Viewer tool from ".$HomePage."'>ABI<br/>Diff*</th>\n";
    }
    $Report .= "</tr>\n";
    
    foreach my $Object2 (@Objects2)
    {
        my $Name = $Object2;
        $Name=~s/\Alib(64|32|)\///;
        
        if(defined $Added{$Object2})
        {
            $Report .= "<tr>\n";
            $Report .= "<td class='object'>$Name</td>\n";
            $Report .= "<td colspan=\'$Cols\' class='added'>Added to package</td>\n";
            $Report .= "</tr>\n";
        }
    }
    foreach my $Object1 (@Objects1)
    {
        if(skipLib($Object1)) {
            next;
        }
        
        $Report .= "<tr>\n";
        
        my $Name = $Object1;
        
        if($Profile->{"Mode"} eq "Kernel") {
            $Name=~s/\A.*\///g;
        }
        else {
            $Name=~s/\Alib(64|32|)\///;
        }
        
        if($Mapped{$Object1})
        {
            if(defined $ChangedSoname{$Object1})
            {
                $Name .= "<br/>";
                $Name .= "<br/>";
                $Name .= "<span class='incompatible'>(changed SONAME from<br/>\"".$ChangedSoname{$Object1}{"From"}."\"<br/>to<br/>\"".$ChangedSoname{$Object1}{"To"}."\")</span>";
            }
            elsif(defined $RenamedObject{$Object1})
            {
                $Name .= "<br/>";
                $Name .= "<br/>";
                $Name .= "<span class='incompatible'>(changed file name from<br/>\"".getFilename($Object1)."\"<br/>to<br/>\"".$RenamedObject{$Object1}."\")</span>";
            }
        }
        
        $Report .= "<td class='object'>$Name</td>\n";
        
        if($Mapped{$Object1})
        {
            my $Md5 = getMd5($Object1, $Mapped{$Object1});
            if(defined $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5})
            {
                my $ABIReport_D = $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5};
                
                my $BC_D = 100 - $ABIReport_D->{"Affected"};
                my $AddedSymbols = $ABIReport_D->{"Added"};
                my $RemovedSymbols = $ABIReport_D->{"Removed"};
                my $TotalProblems = $ABIReport_D->{"TotalProblems"};
                
                my $Changed = ($AddedSymbols or $RemovedSymbols or $TotalProblems);
                
                if($Profile->{"CompatRate"} ne "Off")
                {
                    my $CClass = "ok";
                    if($BC_D eq "100")
                    {
                        if($TotalProblems) {
                            $CClass = "warning";
                        }
                    }
                    else
                    {
                        if(int($BC_D)>=90) {
                            $CClass = "warning";
                        }
                        else {
                            $CClass = "incompatible";
                        }
                    }
                    $Report .= "<td class=\'$CClass\'>";
                    if(not $Changed and $Profile->{"HideEmpty"}) {
                        $Report .= formatNum($BC_D)."%";
                    }
                    else {
                        $Report .= "<a href='../../../../".$ABIReport_D->{"Path"}."'>".formatNum($BC_D)."%</a>";
                    }
                    $Report .= "</td>\n";
                }
                
                if($AddedSymbols) {
                    $Report .= "<td class='added'><a$LinkClass href='../../../../".$ABIReport_D->{"Path"}."#Added'>".$AddedSymbols.$LinkNew."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($RemovedSymbols) {
                    $Report .= "<td class='removed'><a$LinkClass href='../../../../".$ABIReport_D->{"Path"}."#Removed'>".$RemovedSymbols.$LinkRemoved."</a></td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($Profile->{"ShowTotalProblems"})
                {
                    if($TotalProblems) {
                        $Report .= "<td class=\'warning\'><a$LinkClass href='../../../../".$ABIReport_D->{"Path"}."'>$TotalProblems</a></td>\n";
                    }
                    else {
                        $Report .= "<td class='ok'>0</td>\n";
                    }
                }
                
                if($ABIDiff eq "On")
                {
                    if(my $DiffPath = $DB->{"ABIDiff_D"}{$V1}{$V2}{$Md5}{"Path"}) {
                        $Report .= "<td><a href='../../../../".$DiffPath."'>diff</a></td>\n";
                    }
                    else {
                        $Report .= "<td>N/A</td>\n";
                    }
                }
            }
            else
            {
                foreach (1 .. $Cols) {
                    $Report .= "<td>N/A</td>\n";
                }
            }
        }
        elsif(defined $Removed{$Object1})
        {
            $Report .= "<td colspan=\'$Cols\' class='removed'>Removed from package</td>\n";
        }
        $Report .= "</tr>\n";
    }
    $Report .= "</table>\n";
    
    $Report .= getSign("Other");
    
    my $Title = showTitle().": Objects ABI report between $V1 and $V2 versions";
    my $Keywords = showTitle().", ABI, changes, compatibility, report";
    my $Desc = "ABI changes/compatibility report between $V1 and $V2 versions of the $TARGET_LIB";
    
    $Report = composeHTML_Head($Title, $Keywords, $Desc, getTop("objects_report"), "report.css", "")."\n<body>\n$Report\n</body>\n</html>\n";
    
    my $Dir = "objects_report/$TARGET_LIB/$V1/$V2";
    my $Output = $Dir."/report.html";
    
    writeFile($Output, $Report);
    
    my ($Affected_T, $AddedSymbols_T, $RemovedSymbols_T, $TotalProblems_T) = (0, 0, 0, 0);
    
    my $TotalFuncs = 0;
    
    foreach my $Object (@Objects)
    {
        my $Md5 = getMd5($Object, $Mapped{$Object});
        if(defined $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5})
        {
            my $ABIReport_D = $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5};
            my $Dump = $DB->{"ABIDump"}{$V1}{getMd5($Object)};
            my $Funcs = countSymbolsF($Dump, $V1);
            
            $Affected_T += $ABIReport_D->{"Affected"} * $Funcs;
            $AddedSymbols_T += $ABIReport_D->{"Added"};
            $RemovedSymbols_T += $ABIReport_D->{"Removed"};
            $TotalProblems_T += $ABIReport_D->{"TotalProblems"};
            
            $TotalFuncs += $Funcs;
        }
    }
    
    my ($AddedByObjects_T, $RemovedByObjects_T) = (0, 0);
    
    foreach my $Object (keys(%Added))
    {
        my $Dump = $DB->{"ABIDump"}{$V2}{getMd5($Object)};
        $AddedByObjects_T += countSymbolsF($Dump, $V2);
    }
    
    foreach my $Object (keys(%Removed))
    {
        my $Dump = $DB->{"ABIDump"}{$V1}{getMd5($Object)};
        $RemovedByObjects_T += countSymbolsF($Dump, $V1);
    }
    
    my $BC = 100;
    
    if($TotalFuncs) {
        $BC -= $Affected_T/$TotalFuncs;
    }
    
    if(my $Rm = keys(%Removed) and $#Objects1>=0) {
        $BC *= (1-$RemovedByObjects_T/($TotalFuncs+$RemovedByObjects_T));
    }
    
    $BC = formatNum($BC);
    
    $DB->{"ABIReport"}{$V1}{$V2}{"Path"} = $Output;
    $DB->{"ABIReport"}{$V1}{$V2}{"BC"} = $BC;
    $DB->{"ABIReport"}{$V1}{$V2}{"Added"} = $AddedSymbols_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"Removed"} = $RemovedSymbols_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"TotalProblems"} = $TotalProblems_T;
    
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsAdded"} = keys(%Added);
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsRemoved"} = keys(%Removed);
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsAddedSymbols"} = $AddedByObjects_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsRemovedSymbols"} = $RemovedByObjects_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"ChangedSoname"} = keys(%ChangedSoname);
    $DB->{"ABIReport"}{$V1}{$V2}{"TotalObjects"} = $#Objects1 + 1;
    
    my @Meta = ();
    
    push(@Meta, "\"BC\": \"".$BC."\"");
    push(@Meta, "\"Added\": ".$AddedSymbols_T);
    push(@Meta, "\"Removed\": ".$RemovedSymbols_T);
    push(@Meta, "\"TotalProblems\": ".$TotalProblems_T);
    
    push(@Meta, "\"ObjectsAdded\": ".keys(%Added));
    push(@Meta, "\"ObjectsRemoved\": ".keys(%Removed));
    push(@Meta, "\"ObjectsAddedSymbols\": ".$AddedByObjects_T);
    push(@Meta, "\"ObjectsRemovedSymbols\": ".$RemovedByObjects_T);
    push(@Meta, "\"ChangedSoname\": ".keys(%ChangedSoname));
    push(@Meta, "\"TotalObjects\": ".($#Objects1 + 1));
    
    writeFile($Dir."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
}

sub formatNum($)
{
    my $Num = $_[0];
    
    if($Num=~/\A(\d+\.\d\d)/) {
        return $1;
    }
    
    return $Num
}

sub getMd5(@)
{
    my $S = join("", @_);
    my $Md5 = `echo -n \"$S\" | md5sum`;
    $Md5=~s/\s.*//g;
    
    # use Digest::MD5 qw(md5_hex);
    # my $Md5 = md5_hex(@_);
    
    return substr($Md5, 0, $MD5_LEN);
}

sub createABIView_Object($$)
{
    my ($V, $Obj) = @_;
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIView_D"}{$V}
        and defined $DB->{"ABIView_D"}{$V}{getMd5($Obj)})
        {
            if(not updateRequired($V)) {
                return 0;
            }
        }
    }
    
    printMsg("INFO", "Creating ABI View for $Obj ($V)");
    
    my $Md5 = getMd5($Obj);
    my $Dump = $DB->{"ABIDump"}{$V}{$Md5}{"Path"};
    
    my $Dir = "abi_view/$TARGET_LIB/$V";
    $Dir .= "/".$Md5;
    my $Output = $Dir."/symbols.html";
    
    my $Cmd = $ABI_VIEWER." -skip-std -vnum \"$V\" -output \"$Dir\" \"".getDirname($Dump)."\"";
    
    qx/$Cmd/; # execute
    
    $DB->{"ABIView_D"}{$V}{$Md5}{"Path"} = $Output;
}

sub diffABIs($$$$)
{
    my ($V1, $V2, $Obj1, $Obj2) = @_;
    my $Md5 = getMd5($Obj1, $Obj2);
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIDiff_D"}{$V1}{$V2}
        and defined $DB->{"ABIDiff_D"}{$V1}{$V2}{$Md5})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"ABIDiff_D"}{$V1}{$V2}{$Md5}); # empty cache
    
    printMsg("INFO", "Creating ABI diff for $Obj1 ($V1) and $Obj2 ($V2)");
    
    my $Dump1 = $DB->{"ABIDump"}{$V1}{getMd5($Obj1)};
    my $Dump2 = $DB->{"ABIDump"}{$V2}{getMd5($Obj2)};
    
    my $Dir = "abi_diff/$TARGET_LIB/$V1/$V2/$Md5";
    my $Output = $Dir."/symbols.html";
    
    my $Cmd = $ABI_VIEWER." -diff -skip-std -vnum1 \"$V1\" -vnum2 \"$V2\" -output \"$Dir\" \"".getDirname($Dump1->{"Path"})."\" \"".getDirname($Dump2->{"Path"})."\"";
    
    qx/$Cmd/; # execute
    
    $DB->{"ABIDiff_D"}{$V1}{$V2}{$Md5}{"Path"} = $Output;
}

sub compareABIs($$$$)
{
    my ($V1, $V2, $Obj1, $Obj2) = @_;
    
    my $Md5 = getMd5($Obj1, $Obj2);
    
    if(not $Rebuild)
    {
        if(defined $DB->{"ABIReport_D"}{$V1}{$V2}
        and defined $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"ABIReport_D"}{$V1}{$V2}{$Md5}); # empty cache
    
    printMsg("INFO", "Creating ABICC report for $Obj1 ($V1) and $Obj2 ($V2)");
    
    my $TmpDir = $TMP_DIR."/abicc/";
    mkpath($TmpDir);
    
    my $Dump1 = $DB->{"ABIDump"}{$V1}{getMd5($Obj1)};
    my $Dump2 = $DB->{"ABIDump"}{$V2}{getMd5($Obj2)};
    
    my $Dump1_Meta = readProfile(readFile(getDirname($Dump1->{"Path"})."/meta.json"));
    my $Dump2_Meta = readProfile(readFile(getDirname($Dump2->{"Path"})."/meta.json"));
    
    if(not $Dump1_Meta->{"PublicABI"})
    { # support for old versions of ABI Tracker
        printMsg("INFO", "It's necessary to re-generate ABI dump for $V1");
        
        if(not -d $Profile->{"Versions"}{$V1}{"Installed"}) {
            exitStatus("Error", "the version \'$V1\' is not installed");
        }
        
        $DB->{"ABIDump"}{$V1} = undef;
        createABIDump($V1);
    }
    
    if(not $Dump2_Meta->{"PublicABI"})
    { # support for old versions of ABI Tracker
        printMsg("INFO", "It's necessary to re-generate ABI dump for $V2");
        
        if(not -d $Profile->{"Versions"}{$V2}{"Installed"}) {
            exitStatus("Error", "the version \'$V2\' is not installed");
        }
        
        $DB->{"ABIDump"}{$V2} = undef;
        createABIDump($V2);
    }
    
    my $Dir = "compat_report/$TARGET_LIB/$V1/$V2/$Md5";
    my $Output = $Dir."/abi_compat_report.html";
    
    my $Module = getObjectName(getFilename($Obj1), "Short");
    if(not $Module) {
        $Module = getFilename($Obj1);
    }
    
    my $Cmd = $ABI_CC." -l \"$Module\" -bin -old \"".$Dump1->{"Path"}."\" -new \"".$Dump2->{"Path"}."\" -report-path \"$Output\"";
    
    if(my $AccOpts = getABICC_Options()) {
        $Cmd .= $AccOpts;
    }
    
    if($Profile->{"Mode"} eq "Kernel") {
        $Cmd .= " -limit-affected 2";
    }
    
    if($Debug) {
        printMsg("DEBUG", "executing $Cmd");
    }
    
    qx/$Cmd/; # execute
    
    if(not -e $Output)
    {
        rmtree($TmpDir);
        return;
    }
    
    my ($Affected, $Added, $Removed) = ();
    my $Total = 0;
    
    my $Line = readLineNum($Output, 0);
    
    if($Line=~/affected:(.+?);/) {
        $Affected = $1;
    }
    if($Line=~/added:(.+?);/) {
        $Added = $1;
    }
    if($Line=~/removed:(.+?);/) {
        $Removed = $1;
    }
    while($Line=~s/(\w+_problems_\w+|changed_constants):(.+?);//) {
        $Total += $2;
    }
    
    my %Meta = ();
    
    $Meta{"Affected"} = $Affected;
    $Meta{"Added"} = $Added;
    $Meta{"Removed"} = $Removed;
    $Meta{"TotalProblems"} = $Total;
    
    $Meta{"Path"} = $Output;
    $Meta{"Object1"} = $Obj1;
    $Meta{"Object2"} = $Obj2;
    
    $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5} = \%Meta;
    
    my @Meta = ();
    
    push(@Meta, "\"Affected\": \"".$Affected."\"");
    push(@Meta, "\"Added\": ".$Added);
    push(@Meta, "\"Removed\": ".$Removed);
    push(@Meta, "\"TotalProblems\": ".$Total);
    push(@Meta, "\"Object1\": \"".$Obj1."\"");
    push(@Meta, "\"Object2\": \"".$Obj2."\"");
    
    writeFile($Dir."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
    
    my $Changed = ($Added or $Removed or $Total);
    
    if(not $Changed and $Profile->{"HideEmpty"}) {
        unlink($Output);
    }
    
    rmtree($TmpDir);
}

sub getABICC_Options()
{
    my $Opt = "";
    
    if(my $SkipSymbols = $Profile->{"SkipSymbols"}) {
        $Opt .= " -skip-symbols \"$SkipSymbols\"";
    }
    
    if(my $SkipTypes = $Profile->{"SkipTypes"}) {
        $Opt .= " -skip-types \"$SkipTypes\"";
    }
    
    if(my $SkipInternalSymbols = $Profile->{"SkipInternalSymbols"}) {
        $Opt .= " -skip-internal-symbols \"$SkipInternalSymbols\"";
    }
    
    if(my $SkipInternalTypes = $Profile->{"SkipInternalTypes"}) {
        $Opt .= " -skip-internal-types \"$SkipInternalTypes\"";
    }
    
    if(my $SkipHeaders = $Profile->{"SkipHeaders"})
    {
        my $TmpDir = $TMP_DIR."/abicc/";
        writeFile($TmpDir."/headers.list", join("\n", @{$SkipHeaders}));
        $Opt .= " -skip-headers \"$TmpDir/headers.list\"";
    }
    
    return $Opt;
}

sub createPkgdiff($$)
{
    my ($V1, $V2) = @_;
    
    if($Profile->{"Versions"}{$V2}{"PkgDiff"} ne "On"
    and not (defined $TargetVersion and defined $TargetElement)) {
        return 0;
    }
    
    if(not $Rebuild)
    {
        if(defined $DB->{"PackageDiff"}{$V1}{$V2}) {
            return 0;
        }
    }
    
    delete($DB->{"PackageDiff"}{$V1}{$V2}); # empty cache
    
    printMsg("INFO", "Creating package diff for $V1 and $V2");
    
    my $Source1 = $Profile->{"Versions"}{$V1}{"Source"};
    my $Source2 = $Profile->{"Versions"}{$V2}{"Source"};
    
    my $Dir = "package_diff/$TARGET_LIB/$V1/$V2";
    my $Output = $Dir."/report.html";
    rmtree($Dir);
    
    my $Cmd = $PKGDIFF." -report-path \"$Output\" \"$Source1\" \"$Source2\"";
    my $Log = `$Cmd`; # execute
    
    if(-f $Output)
    {
        $DB->{"PackageDiff"}{$V1}{$V2}{"Path"} = $Output;
        
        if($Log=~/CHANGED\s*\((.+?)\%\)/) {
            $DB->{"PackageDiff"}{$V1}{$V2}{"Changed"} = $1;
        }
    }
}

sub getMaxPrefix(@)
{
    my @Paths = @_;
    my %Prefix = ();
    
    foreach my $Path (@Paths)
    {
        my $P = getDirname($Path);
        do {
            $Prefix{$P}+=1;
        }
        while($P = getDirname($P));
    }
    
    my @ByCount = sort {$Prefix{$b}<=>$Prefix{$a}} keys(%Prefix);
    my $Max = $Prefix{$ByCount[0]};
    
    foreach my $P (sort {length($b)<=>length($a)} keys(%Prefix))
    {
        if($Prefix{$P}==$Max)
        {
            return $P;
        }
    }
    
    return undef;
}

sub diffHeaders($$)
{
    my ($V1, $V2) = @_;
    
    if($Profile->{"Versions"}{$V2}{"HeadersDiff"} ne "On"
    and not (defined $TargetVersion and defined $TargetElement)) {
        return 0;
    }
    
    if(not $Rebuild)
    {
        if(defined $DB->{"HeadersDiff"}{$V1}{$V2})
        {
            if(not updateRequired($V2)) {
                return 0;
            }
        }
    }
    
    delete($DB->{"HeadersDiff"}{$V1}{$V2}); # empty cache
    
    printMsg("INFO", "Diff headers $V1 and $V2");
    
    if(not check_Cmd($RFCDIFF))
    {
        printMsg("ERROR", "can't find \"$RFCDIFF\"");
        return 0;
    }
    
    my $I_Dir1 = $Profile->{"Versions"}{$V1}{"Installed"};
    my $I_Dir2 = $Profile->{"Versions"}{$V2}{"Installed"};
    
    if(not -d $I_Dir1) {
        return 0;
    }
    
    if(not -d $I_Dir2) {
        return 0;
    }
    
    my @AllFiles1 = findFiles($I_Dir1, "f");
    my @AllFiles2 = findFiles($I_Dir2, "f");
    
    my @Files1 = ();
    my @Files2 = ();
    
    foreach my $Path (@AllFiles1)
    {
        if(not isHeader($Path)) {
            next;
        }
        
        push(@Files1, $Path);
    }
    
    foreach my $Path (@AllFiles2)
    {
        if(not isHeader($Path)) {
            next;
        }
        
        push(@Files2, $Path);
    }
    
    my %Files1 = ();
    my %Files2 = ();
    
    my $Prefix1 = getMaxPrefix(@Files1);
    if(not $Prefix1) {
        $Prefix1 = $I_Dir1;
    }
    
    my $Prefix2 = getMaxPrefix(@Files2);
    if(not $Prefix2) {
        $Prefix2 = $I_Dir2;
    }
    
    my %Names1 = ();
    my %Names2 = ();
    
    foreach my $Path (@Files1)
    {
        if($Path=~/\A\Q$Prefix1\E\/*(.+?)\Z/) {
            $Files1{$1} = $Path;
        }
        
        $Names1{getFilename($Path)}{$Path} = 1;
    }
    
    foreach my $Path (@Files2)
    {
        if($Path=~/\A\Q$Prefix2\E\/*(.+?)\Z/) {
            $Files2{$1} = $Path;
        }
        
        $Names2{getFilename($Path)}{$Path} = 1;
    }
    
    my $TmpDir = $TMP_DIR."/diff/";
    mkpath($TmpDir);
    
    my @Reports = ();
    
    foreach my $Path (sort {lc($a) cmp lc($b)} keys(%Files1))
    {
        my $Path1 = $Files1{$Path};
        my $Path2 = undef;
        
        if(defined $Files2{$Path}) {
            $Path2 = $Files2{$Path};
        }
        
        if(not defined $Path2)
        {
            my $Name = getFilename($Path);
            if(defined $Names2{$Name})
            {
                my @Paths2 = keys(%{$Names2{$Name}});
                
                if($#Paths2==0) {
                    $Path2 = $Paths2[0];
                }
                else
                {
                    # TODO
                }
            }
        }
        
        if(not defined $Path2) {
            next;
        }
        
        if(-s $Path1 == -s $Path2)
        {
            if(readFile($Path1) eq readFile($Path2)) {
                next;
            }
        }
        
        mkpath(getDirname($TmpDir."/".$Path));
        
        my $Cmd_R = $RFCDIFF." --width 75 --stdout \"$Path1\" \"$Path2\" >$TmpDir/$Path 2>/dev/null";
        qx/$Cmd_R/; # execute
        
        if(-s "$TmpDir/$Path") {
            push(@Reports, "$TmpDir/$Path");
        }
    }
    
    my $Link = "This html diff was produced by rfcdiff 1.41.";
    $Link .= "The latest version is available from <a href='http://tools.ietf.org/tools/rfcdiff/'>http://tools.ietf.org/tools/rfcdiff/</a>";
    
    my $Diff = "";
    my $Total = 0;
    
    foreach my $Path (@Reports)
    {
        my $Content = readFile($Path);
        if((-s $Path)<3500 and $Content=~/The files are identical|No changes|Failed to create/i) {
            next;
        }
        
        my $RPath = $Path;
        $RPath=~s/\A$TmpDir\///;
        
        my $File = getFilename($Path);
        
        $Content=~s/<\!--(.|\n)+?-->\s*//g;
        $Content=~s/\A((.|\n)+<body\s*>)((.|\n)+)(<\/body>(.|\n)+)\Z/$3/;
        $Content=~s/(<td colspan=\"5\"[^>]*>)(.+)(<\/td>)/$1$3/;
        $Content=~s/(<table) /$1 class='diff_tbl' /g;
        
        $Content=~s/(\Q$File\E)(&nbsp;)/$1 ($V1)$2/;
        $Content=~s/(\Q$File\E)(&nbsp;)/$1 ($V2)$2/;
        
        if($Diff) {
            $Diff .= "<br/><br/>\n";
        }
        $Diff .= $Content;
        $Total += 1;
    }
    
    my $Title = showTitle().": headers diff between $V1 and $V2 versions";
    my $Keywords = showTitle().", header, diff";
    my $Desc = "Diff for header files between $V1 and $V2 versions of $TARGET_LIB";
    
    $Diff .= "<br/>";
    $Diff .= "<div style='width:100%;' align='left' class='small'>$Link</div>\n";
    
    $Diff = "<h1>Headers diff: <span class='version'>$V1</span> vs <span class='version'>$V2</span></h1><br/><br/>".$Diff;
    $Diff = getHead("headers_diff").$Diff;
    
    $Diff = "<table width='100%' cellpadding='0' cellspacing='0'><tr><td>$Diff</td></tr></table>";
    
    $Diff = composeHTML_Head($Title, $Keywords, $Desc, getTop("headers_diff"), "headers_diff.css", "")."\n<body>\n$Diff\n</body>\n</html>\n";
    
    my $Output = "headers_diff/$TARGET_LIB/$V1/$V2";
    writeFile($Output."/diff.html", $Diff);
    
    $DB->{"HeadersDiff"}{$V1}{$V2}{"Path"} = $Output."/diff.html";
    $DB->{"HeadersDiff"}{$V1}{$V2}{"Total"} = $Total;
    
    writeFile($Output."/meta.json", "{\n  \"Total\": $Total\n}");
    
    rmtree($TmpDir);
}

sub showTitle()
{
    if(defined $Profile->{"Title"}) {
        return $Profile->{"Title"};
    }
    
    return $TARGET_LIB;
}

sub getTop($)
{
    my $Page = $_[0];
    
    my $Rel = "";
    
    if($Page=~/\A(changelog|objects_view)\Z/) {
        $Rel = "../../..";
    }
    elsif($Page=~/\A(objects_report|headers_diff)\Z/) {
        $Rel = "../../../..";
    }
    elsif($Page=~/\A(timeline)\Z/) {
        $Rel = "../..";
    }
    elsif($Page=~/\A(global_index)\Z/) {
        $Rel = ".";
    }
    
    return $Rel;
}

sub getHead($)
{
    my $Sel = $_[0];
    
    my $UrlPr = getTop($Sel);
    
    my $ReportHeader = "ABI<br/>Tracker";
    if(defined $Profile->{"ReportHeader"}) {
        $ReportHeader = $Profile->{"ReportHeader"};
    }
    
    my $Head = "";
    
    $Head .= "<table cellpadding='0' cellspacing='0'>";
    $Head .= "<tr>";
    
    $Head .= "<td align='center'>";
    
    if($TARGET_LIB) {
        $Head .= "<h1 class='tool'><a title=\'ABI tracker for ".showTitle()."\' href='$UrlPr/timeline/$TARGET_LIB/index.html' class='tool'>".$ReportHeader."</a></h1>";
    }
    else {
        $Head .= "<h1 class='tool'><a title='ABI tracker' href='' class='tool'>".$ReportHeader."</a></h1>";
    }
    $Head .= "</td>";
    
    if(not defined $Profile->{"ReportHeader"})
    {
        $Head .= "<td width='30px;'>";
        $Head .= "</td>";
        
        if($Sel ne "global_index")
        {
            $Head .= "<td>";
            $Head .= "<h1>(".showTitle().")</h1>";
            $Head .= "</td>";
        }
    }
    
    $Head .= "</tr></table>";
    
    $Head .= "<hr/>\n";
    $Head .= "<br/>\n";
    $Head .= "<br/>\n";
    
    return $Head;
}

sub getSign($)
{
    my $T = $_[0];
    
    my $Sign = "";
    
    $Sign .= "<br/>\n";
    $Sign .= "<br/>\n";
    
    $Sign .= "<hr/>\n";
    
    if($T eq "Home") {
        $Sign .= "<div align='right'><a class='home' title=\"Andrey Ponomarenko's ABI laboratory\" href='".$HomePage."'>abi-laboratory.pro</a></div>\n";
    }
    else {
        $Sign .= "<div align='right'><a class='home' title=\"Andrey Ponomarenko's ABI laboratory\" href='https://github.com/lvc'>github.com/lvc</a></div>\n";
    }
    
    $Sign .= "<br/>\n";
    
    return $Sign;
}

sub getS($)
{
    if($_[0]>1) {
        return "s";
    }
    
    return "";
}

sub getVersionsList()
{
    my @Versions = keys(%{$Profile->{"Versions"}});
    @Versions = sort {int($Profile->{"Versions"}{$a}{"Pos"})<=>int($Profile->{"Versions"}{$b}{"Pos"})} @Versions;
    
    if(my $Minimal = $Profile->{"MinimalVersion"})
    {
        if(defined $Profile->{"Versions"}{$Minimal})
        {
            my $MinPos = $Profile->{"Versions"}{$Minimal}{"Pos"};
            my @Part = ();
            
            foreach (@Versions)
            {
                if($Profile->{"Versions"}{$_}{"Pos"}<=$MinPos) {
                    push(@Part, $_);
                }
            }
            
            @Versions = @Part;
        }
    }
    
    return @Versions;
}

sub writeCss()
{
    writeFile("css/common.css", readModule("Styles", "Common.css"));
    writeFile("css/report.css", readModule("Styles", "Report.css"));
    writeFile("css/headers_diff.css", readModule("Styles", "HeadersDiff.css"));
    writeFile("css/changelog.css", readModule("Styles", "Changelog.css"));
}

sub createTimeline()
{
    $DB->{"Updated"} = time;
    
    writeCss();
    
    my $Title = showTitle().": API/ABI changes timeline";
    my $Desc = "API/ABI compatibility analysis reports for ".showTitle();
    my $Content = composeHTML_Head($Title, $TARGET_LIB.", ABI, API, compatibility, report", $Desc, getTop("timeline"), "report.css", "");
    $Content .= "<body>\n";
    
    my @Versions = getVersionsList();
    
    my $CompatRate = "On";
    my $Soname = "On";
    my $Changelog = "Off";
    my $HeadersDiff = "Off";
    my $PkgDiff = "Off";
    
    if($Profile->{"CompatRate"} eq "Off") {
        $CompatRate = "Off";
    }
    if($Profile->{"Soname"} eq "Off") {
        $Soname = "Off";
    }
    
    # High-detailed analysis for Enterprise usage (non-free)
    my $ABIView = "Off";
    foreach my $V (@Versions)
    {
        if($Profile->{"Versions"}{$V}{"Changelog"} ne "Off")
        {
            $Changelog = "On";
        }
        
        if($Profile->{"Versions"}{$V}{"HeadersDiff"} eq "On")
        {
            $HeadersDiff = "On";
        }
        
        if($Profile->{"Versions"}{$V}{"PkgDiff"} eq "On")
        {
            $PkgDiff = "On";
        }
        
        if($Profile->{"Versions"}{$V}{"ABIView"} eq "On")
        {
            $ABIView = "On";
        }
    }
    
    my $Cols = 11;
    
    if($CompatRate eq "Off") {
        $Cols-=1;
    }
    
    if(not $Profile->{"ShowTotalProblems"}) {
        $Cols-=1;
    }
    
    if($Soname eq "Off") {
        $Cols-=1;
    }
    
    if($Changelog eq "Off") {
        $Cols-=1;
    }
    
    if($HeadersDiff eq "Off") {
        $Cols-=1;
    }
    
    if($PkgDiff eq "Off") {
        $Cols-=1;
    }
    
    if($ABIView eq "Off") {
        $Cols-=1;
    }
    
    $Content .= getHead("timeline");
    
    my $ContentHeader = "API/ABI changes timeline";
    if(defined $Profile->{"ContentHeader"}) {
        $ContentHeader = $Profile->{"ContentHeader"};
    }
    
    $Content .= "<h1>".$ContentHeader."</h1>\n";
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    my $GraphPath = "graph/$TARGET_LIB/graph.png";
    
    if(-f $GraphPath) {
        $Content .= "<table cellpadding='0' cellspacing='0'><tr><td valign='top'>\n";
    }
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
    $Content .= "<th>Version</th>\n";
    $Content .= "<th>Date</th>\n";
    
    if($Soname ne "Off") {
        $Content .= "<th>Soname</th>\n";
    }
    
    if($Changelog ne "Off") {
        $Content .= "<th>Change<br/>Log</th>\n";
    }
    
    if($CompatRate ne "Off") {
        $Content .= "<th>Backward<br/>Compatibility</th>\n";
    }
    
    $Content .= "<th>Added<br/>Symbols</th>\n";
    $Content .= "<th>Removed<br/>Symbols</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Content .= "<th>Total<br/>Changes</th>\n";
    }
    
    if($HeadersDiff ne "Off") {
        $Content .= "<th>Headers<br/>Diff</th>\n";
    }
    
    if($PkgDiff ne "Off") {
        $Content .= "<th>Package<br/>Diff</th>\n";
    }
    
    if($ABIView ne "Off") {
        $Content .= "<th title='Generated by the ABI Viewer tool from ".$HomePage."'>ABI<br/>View*</th>\n";
    }
    
    $Content .= "</tr>\n";
    
    foreach my $P (0 .. $#Versions)
    {
        my $V = $Versions[$P];
        my $O_V = undef;
        if($P<$#Versions) {
            $O_V = $Versions[$P+1];
        }
        
        my $ABIReport = undef;
        my $HDiff = undef;
        my $PackageDiff = undef;
        
        my $ABIViewReport = undef;
        
        if(defined $DB->{"ABIReport"} and defined $DB->{"ABIReport"}{$O_V}
        and defined $DB->{"ABIReport"}{$O_V}{$V}) {
            $ABIReport = $DB->{"ABIReport"}{$O_V}{$V};
        }
        if(defined $DB->{"HeadersDiff"} and defined $DB->{"HeadersDiff"}{$O_V}
        and defined $DB->{"HeadersDiff"}{$O_V}{$V}) {
            $HDiff = $DB->{"HeadersDiff"}{$O_V}{$V};
        }
        if(defined $DB->{"PackageDiff"} and defined $DB->{"PackageDiff"}{$O_V}
        and defined $DB->{"PackageDiff"}{$O_V}{$V}) {
            $PackageDiff = $DB->{"PackageDiff"}{$O_V}{$V};
        }
        if(defined $DB->{"ABIView"} and defined $DB->{"ABIView"}{$V}) {
            $ABIViewReport = $DB->{"ABIView"}{$V};
        }
        
        my $Date = "N/A";
        my $Sover = "N/A";
        
        if(defined $DB->{"Date"} and defined $DB->{"Date"}{$V}) {
            $Date = $DB->{"Date"}{$V};
        }
        
        if(defined $DB->{"Sover"} and defined $DB->{"Sover"}{$V}) {
            $Sover = $DB->{"Sover"}{$V};
        }
        
        my $Anchor = $V;
        if($V ne "current") {
            $Anchor = "v".$Anchor;
        }
        
        $Content .= "<tr id='".$Anchor."'>";
        
        $Content .= "<td title='".getFilename($Profile->{"Versions"}{$V}{"Source"})."'>".$V."</td>\n";
        $Content .= "<td>".showDate($V, $Date)."</td>\n";
        
        if($Soname ne "Off") {
            $Content .= "<td>".$Sover."</td>\n";
        }
        
        if($Changelog ne "Off")
        {
            my $Chglog = $DB->{"Changelog"}{$V};
            
            if($Chglog and $Chglog ne "Off"
            and $Profile->{"Versions"}{$V}{"Changelog"} ne "Off") {
                $Content .= "<td><a href=\'../../".$Chglog."\'>changelog</a></td>\n";
            }
            elsif(index($Profile->{"Versions"}{$V}{"Changelog"}, "://")!=-1) {
                $Content .= "<td><a href=\'".$Profile->{"Versions"}{$V}{"Changelog"}."\'>changelog</a></td>\n";
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($CompatRate ne "Off")
        {
            if(defined $ABIReport)
            {
                my $BC = $ABIReport->{"BC"};
                my $ObjectsAdded = $ABIReport->{"ObjectsAdded"};
                my $ObjectsRemoved = $ABIReport->{"ObjectsRemoved"};
                my $ChangedSoname = $ABIReport->{"ChangedSoname"};
                my $TotalProblems = $ABIReport->{"TotalProblems"};
                
                my @Note = ();
                
                if($ChangedSoname) {
                    push(@Note, "<span class='incompatible'>changed SONAME</span>");
                }
                
                if($ObjectsAdded) {
                    push(@Note, "<span class='added'>added $ObjectsAdded object".getS($ObjectsAdded)."</span>");
                }
                
                if($ObjectsRemoved) {
                    push(@Note, "<span class='incompatible'>removed $ObjectsRemoved object".getS($ObjectsRemoved)."</span>");
                }
                
                my $CClass = "ok";
                if($BC ne "100")
                {
                    if(int($BC)>=90) {
                        $CClass = "warning";
                    }
                    else {
                        $CClass = "incompatible";
                    }
                }
                elsif($TotalProblems) {
                    $CClass = "warning";
                }
                
                my $BC_Summary = "<a href='../../".$ABIReport->{"Path"}."'>$BC%</a>";
                
                if(@Note)
                {
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<br/>\n";
                    $BC_Summary .= "<span class='note'>".join("<br/>", @Note)."</span>\n";
                }
                
                $Content .= "<td class=\'$CClass\'>$BC_Summary</td>\n";
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if(defined $ABIReport)
        {
            if(my $Added = $ABIReport->{"Added"}) {
                $Content .= "<td class='added'><a$LinkClass href='../../".$ABIReport->{"Path"}."'>".$Added.$LinkNew."</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
        }
        
        if(defined $ABIReport)
        {
            if(my $Removed = $ABIReport->{"Removed"}) {
                $Content .= "<td class='removed'><a$LinkClass href='../../".$ABIReport->{"Path"}."'>".$Removed.$LinkRemoved."</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
        }
        
        if($Profile->{"ShowTotalProblems"})
        {
            if(defined $ABIReport)
            {
                if(my $TotalProblems = $ABIReport->{"TotalProblems"}) {
                    $Content .= "<td class=\'warning\'><a$LinkClass href='../../".$ABIReport->{"Path"}."'>$TotalProblems</a></td>\n";
                }
                else {
                    $Content .= "<td class='ok'>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($HeadersDiff ne "Off")
        {
            if(defined $HDiff and $Profile->{"Versions"}{$V}{"HeadersDiff"} eq "On")
            {
                if(my $ChangedHeaders = $HDiff->{"Total"})
                {
                    $Content .= "<td><a href='../../".$HDiff->{"Path"}."'>$ChangedHeaders</a></td>\n";
                }
                else
                {
                    $Content .= "<td>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($PkgDiff ne "Off")
        {
            if(defined $PackageDiff and $Profile->{"Versions"}{$V}{"PkgDiff"} eq "On")
            {
                if(my $Changed = $PackageDiff->{"Changed"}) {
                    $Content .= "<td><a href='../../".$PackageDiff->{"Path"}."'>$Changed%</a></td>\n";
                }
                else {
                    $Content .= "<td>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if($ABIView ne "Off")
        {
            if(defined $ABIViewReport and $Profile->{"Versions"}{$V}{"ABIView"} eq "On") {
                $Content .= "<td><a href='../../".$ABIViewReport->{"Path"}."'>view</a></td>\n";
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        $Content .= "</tr>\n";
        
        if(my $Comment = $Profile->{"Versions"}{$V}{"Comment"})
        {
            $Content .= "<tr><td class='comment' colspan=\'$Cols\'>NOTE: $Comment</td></tr>\n";
        }
    }
    
    $Content .= "</table>";
    
    $Content .= "<br/>";
    if(defined $Profile->{"Maintainer"})
    {
        my $M = $Profile->{"Maintainer"};
        
        if(defined $Profile->{"MaintainerUrl"}) {
            $M = "<a href='".$Profile->{"MaintainerUrl"}."'>$M</a>";
        }
        
        $Content .= "Maintained by $M. ";
    }
    
    my $Date = localtime($DB->{"Updated"});
    $Date=~s/(\d\d:\d\d):\d\d/$1/;
    
    $Content .= "Last updated on ".$Date.".";
    
    $Content .= "<br/>";
    $Content .= "<br/>";
    $Content .= "Generated by <a href='https://github.com/lvc/abi-tracker'>ABI Tracker</a>, <a href='https://github.com/lvc/abi-compliance-checker'>ABICC</a> and <a href='https://github.com/lvc/abi-dumper'>ABI Dumper</a> tools.";
    
    if(-f $GraphPath)
    {
        $Content .= "</td>";
        $Content .= "<td width='100%' valign='top' align='left' style='padding-left:4em;'>\n";
        $Content .= "<img src=\'../../$GraphPath\' alt='Timeline of ABI changes' />\n";
        $Content .= "</td>\n";
        $Content .=  "</tr>\n";
        $Content .= "</table>\n";
    }
    
    $Content .= getSign("Home");
    
    $Content .= "</body></html>";
    
    my $Output = "timeline/".$TARGET_LIB."/index.html";
    writeFile($Output, $Content);
    printMsg("INFO", "The index has been generated to: $Output");
}

sub createGlobalIndex()
{
    my @Libs = ();
    
    foreach my $File (listDir("timeline"))
    {
        if($File ne "index.html")
        {
            push(@Libs, $File);
        }
    }
    
    if($#Libs<=0)
    { # for two or more libraries
        #return 0;
    }
    
    writeCss();
    
    my $Title = "Maintained libraries";
    my $Desc = "List of maintained libraries";
    my $Content = composeHTML_Head($Title, "", $Desc, getTop("global_index"), "report.css", "");
    $Content .= "<body>\n";
    
    $Content .= getHead("global_index");
    
    $Content .= "<h1>Maintained libraries</h1>\n";
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
    $Content .= "<th>Name</th>\n";
    $Content .= "<th>ABI Timeline</th>\n";
    # $Content .= "<th>Maintainer</th>\n";
    $Content .= "</tr>\n";
    
    my %LibAttr = ();
    foreach my $L (sort @Libs)
    {
        my $Title = $L;
        # my ($M, $MUrl);
        
        my $DB = eval(readFile("db/$L/$DB_NAME"));
        
        if(defined $DB->{"Title"}) {
            $Title = $DB->{"Title"};
        }
        
        $LibAttr{$L}{"Title"} = $Title;
        
        # $LibAttr{$L}{"Maintainer"} = $M;
        # $LibAttr{$L}{"MaintainerUrl"} = $MUrl;
    }
    
    foreach my $L (sort {lc($LibAttr{$a}{"Title"}) cmp lc($LibAttr{$b}{"Title"})} @Libs)
    {
        $Content .= "<tr>\n";
        $Content .= "<td class='sl'>".$LibAttr{$L}{"Title"}."</td>\n";
        $Content .= "<td><a href='timeline/$L/index.html'>timeline</a></td>\n";
        
        # my $M = $LibAttr{$L}{"Maintainer"};
        # if(my $MUrl = $LibAttr{$L}{"MaintainerUrl"}) {
        #     $M = "<a href='".$MUrl."'>$M</a>";
        # }
        # $Content .= "<td>$M</td>\n";
        
        $Content .= "</tr>\n";
    }
    
    $Content .= "</table>";
    
    $Content .= getSign("Other");
    $Content .= "</body></html>";
    
    my $Output = "index.html";
    writeFile($Output, $Content);
    printMsg("INFO", "The global index has been generated to: $Output");
}

sub showDate($$)
{
    my ($V, $Date) = @_;
    
    my ($D, $T) = ($Date, "");
    
    if($Date=~/(.+) (.+)/) {
        ($D, $T) = ($1, $2);
    }
    
    if($V eq "current")
    {
        $T=~s/\:\d+\Z//;
        return $D."<br/>".$T;
    }
    
    return $D;
}

sub readDB($)
{
    my $Path = $_[0];
    
    if(-f $Path)
    {
        my $P = eval(readFile($Path));
        
        if(not $P) {
            exitStatus("Error", "please remove 'use strict' from code and retry");
        }
        
        return $P;
    }
    
    return {};
}

sub writeDB($)
{
    my $Path = $_[0];
    writeFile($Path, Dumper($DB));
}

sub checkFiles()
{
    my $HDiffs = "headers_diff/$TARGET_LIB";
    foreach my $V1 (listDir($HDiffs))
    {
        foreach my $V2 (listDir($HDiffs."/".$V1))
        {
            if(not defined $DB->{"HeadersDiff"}{$V1}{$V2})
            {
                $DB->{"HeadersDiff"}{$V1}{$V2}{"Path"} = $HDiffs."/".$V1."/".$V2."/diff.html";
                my $Meta = readProfile(readFile($HDiffs."/".$V1."/".$V2."/meta.json"));
                $DB->{"HeadersDiff"}{$V1}{$V2}{"Total"} = $Meta->{"Total"};
            }
        }
    }
    
    my $PkgDiffs = "package_diff/$TARGET_LIB";
    foreach my $V1 (listDir($PkgDiffs))
    {
        foreach my $V2 (listDir($PkgDiffs."/".$V1))
        {
            if(not defined $DB->{"PackageDiff"}{$V1}{$V2})
            {
                $DB->{"PackageDiff"}{$V1}{$V2}{"Path"} = $PkgDiffs."/".$V1."/".$V2."/report.html";
                
                my $Line = readLineNum($DB->{"PackageDiff"}{$V1}{$V2}{"Path"}, 0);
                
                if($Line=~/changed:(.+?);/) {
                    $DB->{"PackageDiff"}{$V1}{$V2}{"Changed"} = $1;
                }
            }
        }
    }
    
    my $Changelogs = "changelog/$TARGET_LIB";
    foreach my $V (listDir($Changelogs))
    {
        if(not defined $DB->{"Changelog"}{$V})
        {
            $DB->{"Changelog"}{$V} = $Changelogs."/".$V."/log.html";
        }
    }
    
    my $Dumps = "abi_dump/$TARGET_LIB";
    foreach my $V (listDir($Dumps))
    {
        foreach my $Md5 (listDir($Dumps."/".$V))
        {
            if(not defined $DB->{"ABIDump"}{$V}{$Md5})
            {
                my %Info = ();
                my $Dir = $Dumps."/".$V."/".$Md5;
                
                $Info{"Path"} = $Dir."/ABI.dump";
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
                $Info{"Object"} = $Meta->{"Object"};
                $Info{"Lang"} = $Meta->{"Lang"};
                $Info{"TotalSymbols"} = $Meta->{"TotalSymbols"};
                $Info{"Version"} = $Meta->{"Version"};
                
                $DB->{"ABIDump"}{$V}{$Md5} = \%Info;
            }
            
            # my $Dump = $DB->{"ABIDump"}{$V}{$Md5};
            # if(not defined $Dump->{"TotalSymbols"})
            # { # support for old data
            #     print STDERR "WARNING: TotalSymbols property is missed, reading ABI dump ...\n";
            #     $Dump->{"TotalSymbols"} = countSymbols($Dump);
            # }
        }
    }
    
    my $ABIReports_D = "compat_report/$TARGET_LIB";
    foreach my $V1 (listDir($ABIReports_D))
    {
        foreach my $V2 (listDir($ABIReports_D."/".$V1))
        {
            foreach my $Md5 (listDir($ABIReports_D."/".$V1."/".$V2))
            {
                if(not defined $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5})
                {
                    my %Info = ();
                    my $Dir = $ABIReports_D."/".$V1."/".$V2."/".$Md5;
                    
                    $Info{"Path"} = $Dir."/abi_compat_report.html";
                    
                    my $Meta = readProfile(readFile($Dir."/meta.json"));
                    $Info{"Affected"} = $Meta->{"Affected"};
                    $Info{"Added"} = $Meta->{"Added"};
                    $Info{"Removed"} = $Meta->{"Removed"};
                    $Info{"TotalProblems"} = $Meta->{"TotalProblems"};
                    
                    $Info{"Object1"} = $Meta->{"Object1"};
                    $Info{"Object2"} = $Meta->{"Object2"};
                    
                    $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5} = \%Info;
                }
            }
        }
    }
    
    my $ABIReports = "objects_report/$TARGET_LIB";
    foreach my $V1 (listDir($ABIReports))
    {
        foreach my $V2 (listDir($ABIReports."/".$V1))
        {
            if(not defined $DB->{"ABIReport"}{$V1}{$V2})
            {
                my %Info = ();
                my $Dir = $ABIReports."/".$V1."/".$V2;
                
                $Info{"Path"} = $Dir."/report.html";
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
                $Info{"BC"} = $Meta->{"BC"};
                $Info{"Added"} = $Meta->{"Added"};
                $Info{"Removed"} = $Meta->{"Removed"};
                $Info{"TotalProblems"} = $Meta->{"TotalProblems"};
                
                $Info{"ObjectsAdded"} = $Meta->{"ObjectsAdded"};
                $Info{"ObjectsRemoved"} = $Meta->{"ObjectsRemoved"};
                $Info{"ChangedSoname"} = $Meta->{"ChangedSoname"};
                
                $DB->{"ABIReport"}{$V1}{$V2} = \%Info;
            }
        }
    }
    
    my $ABIViews_D = "abi_view/$TARGET_LIB";
    foreach my $V (listDir($ABIViews_D))
    {
        foreach my $Md5 (listDir($ABIViews_D."/".$V))
        {
            if(not defined $DB->{"ABIView_D"}{$V}{$Md5})
            {
                $DB->{"ABIView_D"}{$V}{$Md5}{"Path"} = $ABIViews_D."/".$V."/".$Md5."/symbols.html";
            }
        }
    }
    
    my $ABIViews = "objects_view/$TARGET_LIB";
    foreach my $V (listDir($ABIViews))
    {
        if(not defined $DB->{"ABIView"}{$V})
        {
            $DB->{"ABIView"}{$V}{"Path"} = $ABIViews."/".$V."/report.html";
        }
    }
}

sub checkDB()
{
    foreach my $V1 (keys(%{$DB->{"HeadersDiff"}}))
    {
        foreach my $V2 (keys(%{$DB->{"HeadersDiff"}{$V1}}))
        {
            if(not -e $DB->{"HeadersDiff"}{$V1}{$V2}{"Path"})
            {
                delete($DB->{"HeadersDiff"}{$V1}{$V2});
                
                if(not keys(%{$DB->{"HeadersDiff"}{$V1}})) {
                    delete($DB->{"HeadersDiff"}{$V1});
                }
            }
        }
    }
    
    foreach my $V1 (keys(%{$DB->{"PackageDiff"}}))
    {
        foreach my $V2 (keys(%{$DB->{"PackageDiff"}{$V1}}))
        {
            if(not -e $DB->{"PackageDiff"}{$V1}{$V2}{"Path"})
            {
                delete($DB->{"PackageDiff"}{$V1}{$V2});
                
                if(not keys(%{$DB->{"PackageDiff"}{$V1}})) {
                    delete($DB->{"PackageDiff"}{$V1});
                }
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"Changelog"}}))
    {
        if($DB->{"Changelog"}{$V} ne "Off")
        {
            if(not -e $DB->{"Changelog"}{$V}) {
                delete($DB->{"Changelog"}{$V});
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"ABIDump"}}))
    {
        foreach my $Md5 (keys(%{$DB->{"ABIDump"}{$V}}))
        {
            if(not -e $DB->{"ABIDump"}{$V}{$Md5}{"Path"}) {
                delete($DB->{"ABIDump"}{$V}{$Md5});
            }
        }
        
        if(not keys(%{$DB->{"ABIDump"}{$V}})) {
            delete($DB->{"ABIDump"}{$V});
        }
    }
    
    foreach my $V1 (keys(%{$DB->{"ABIReport_D"}}))
    {
        foreach my $V2 (keys(%{$DB->{"ABIReport_D"}{$V1}}))
        {
            foreach my $Md5 (keys(%{$DB->{"ABIReport_D"}{$V1}{$V2}}))
            {
                if(not -e $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5}{"Path"})
                {
                    delete($DB->{"ABIReport_D"}{$V1}{$V2}{$Md5});
                    
                    if(not keys(%{$DB->{"ABIReport_D"}{$V1}{$V2}})) {
                        delete($DB->{"ABIReport_D"}{$V1}{$V2});
                    }
                    
                    if(not keys(%{$DB->{"ABIReport_D"}{$V1}})) {
                        delete($DB->{"ABIReport_D"}{$V1});
                    }
                }
            }
        }
    }
    
    foreach my $V1 (keys(%{$DB->{"ABIReport"}}))
    {
        foreach my $V2 (keys(%{$DB->{"ABIReport"}{$V1}}))
        {
            if(not -e $DB->{"ABIReport"}{$V1}{$V2}{"Path"})
            {
                delete($DB->{"ABIReport"}{$V1}{$V2});
                
                if(not keys(%{$DB->{"ABIReport"}{$V1}})) {
                    delete($DB->{"ABIReport"}{$V1});
                }
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"ABIView_D"}}))
    {
        foreach my $Md5 (keys(%{$DB->{"ABIView_D"}{$V}}))
        {
            if(not -e $DB->{"ABIView_D"}{$V}{$Md5}{"Path"})
            {
                delete($DB->{"ABIView_D"}{$V}{$Md5});
                
                if(not keys(%{$DB->{"ABIView_D"}{$V}})) {
                    delete($DB->{"ABIView_D"}{$V});
                }
            }
        }
    }
    
    foreach my $V (keys(%{$DB->{"ABIView"}}))
    {
        if(not -e $DB->{"ABIView"}{$V}{"Path"})
        {
            delete($DB->{"ABIView"}{$V});
        }
    }
    
    
    foreach my $V (keys(%{$DB->{"Soname"}}))
    {
        if($V eq "current")
        {
            if(defined $Profile->{"Versions"}{$V})
            {
                my $IPath = $Profile->{"Versions"}{$V}{"Installed"};
                
                foreach my $Obj (keys(%{$DB->{"Soname"}{$V}}))
                {
                    if(not -e $IPath."/".$Obj)
                    {
                        delete($DB->{"Soname"}{$V});
                        delete($DB->{"Sover"}{$V});
                        last;
                    }
                }
            }
            else
            {
                delete($DB->{"Soname"}{$V});
                delete($DB->{"Sover"}{$V});
            }
        }
    }
}

sub safeExit()
{
    chdir($ORIG_DIR);
    
    printMsg("INFO", "\nGot INT signal");
    printMsg("INFO", "Exiting");
    
    if($DB_PATH) {
        writeDB($DB_PATH);
    }
    exit(1);
}

sub getToolVer($)
{
    my $T = $_[0];
    return `$T -dumpversion`;
}

sub scenario()
{
    $Data::Dumper::Sortkeys = 1;
    
    $SIG{INT} = \&safeExit;
    
    if($Rebuild) {
        $Build = 1;
    }
    
    if($TargetElement)
    {
        if($TargetElement!~/\A(date|dates|soname|changelog|abidump|abireport|rfcdiff|headersdiff|pkgdiff|packagediff|abiview|graph|objectsreport)\Z/)
        {
            exitStatus("Error", "the value of -target option should be one of the following: date, soname, changelog, abidump, abireport, rfcdiff, pkgdiff.");
        }
    }
    
    if($TargetElement eq "objectsreport")
    {
        $TargetElement = "abireport";
        $ObjectsReport = 1;
    }
    
    if($DumpVersion)
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }
    
    if($Help)
    {
        printMsg("INFO", $HelpMessage);
        exit(0);
    }
    
    if(-d "archives_report") {
        exitStatus("Error", "Can't execute inside the Java API tracker home directory");
    }
    
    loadModule("Basic");

    # check ABI Dumper
    if(my $Version = getToolVer($ABI_DUMPER))
    {
        if(cmpVersions_S($Version, $ABI_DUMPER_VERSION)<0) {
            exitStatus("Module_Error", "the version of ABI Dumper should be $ABI_DUMPER_VERSION or newer");
        }
        
        if(cmpVersions_S($Version, "1.0")>=0) {
            $ABI_DUMPER_EE = 1;
        }
    }
    else {
        exitStatus("Module_Error", "cannot find \'$ABI_DUMPER\'");
    }
    
    # check ABI CC
    if(my $Version = getToolVer($ABI_CC))
    {
        if(cmpVersions_S($Version, $ABI_CC_VERSION)<0) {
            exitStatus("Module_Error", "the version of ABI Compliance Checker should be $ABI_CC_VERSION or newer");
        }
    }
    else {
        exitStatus("Module_Error", "cannot find \'$ABI_CC\'");
    }
    
    my @Reports = ("timeline", "package_diff", "headers_diff", "changelog", "abi_dump", "objects_report", "objects_view", "compat_report", "abi_view");
    
    if(my $Profile_Path = $ARGV[0])
    {
        if(not $Profile_Path) {
            exitStatus("Error", "profile path is not specified");
        }
        
        if(not -e $Profile_Path) {
            exitStatus("Access_Error", "can't access \'$Profile_Path\'");
        }
        
        $Profile = readProfile(readFile($Profile_Path));
        
        if(defined $Profile->{"ShowTotalChanges"}) {
            $Profile->{"ShowTotalProblems"} = $Profile->{"ShowTotalChanges"};
        }
        
        if($Profile->{"ReportStyle"} eq "SimpleLinks")
        {
            $LinkClass = "";
            $LinkNew = "";
            $LinkRemoved = "";
        }
        
        if(not $Profile->{"Name"}) {
            exitStatus("Error", "name of the library is not specified in profile");
        }
        
        foreach my $V (sort keys(%{$Profile->{"Versions"}}))
        {
            if($Profile->{"Versions"}{$V}{"Deleted"}
            and $Profile->{"Versions"}{$V}{"Deleted"} ne "Off")
            { # do not show this version in the report
                delete($Profile->{"Versions"}{$V});
                next;
            }
            
            if(skipVersion($V))
            {
                delete($Profile->{"Versions"}{$V});
                next;
            }
        }
        
        $TARGET_LIB = $Profile->{"Name"};
        $DB_PATH = "db/".$TARGET_LIB."/".$DB_NAME;
        
        if($Clear)
        {
            printMsg("INFO", "Remove $DB_PATH");
            unlink($DB_PATH);
            
            foreach my $Dir (@Reports)
            {
                printMsg("INFO", "Remove $Dir/$TARGET_LIB");
                rmtree($Dir."/".$TARGET_LIB);
            }
            exit(0);
        }
        
        $DB = readDB($DB_PATH);
        
        $DB->{"Maintainer"} = $Profile->{"Maintainer"};
        $DB->{"MaintainerUrl"} = $Profile->{"MaintainerUrl"};
        $DB->{"Title"} = $Profile->{"Title"};
        
        checkDB();
        checkFiles();
        
        if($Build)
        {
            writeDB($DB_PATH);
            buildData();
        }
        
        writeDB($DB_PATH);
        
        createTimeline();
    }
    
    if($GlobalIndex) {
        createGlobalIndex();
    }
    
    if($Deploy)
    {
        printMsg("INFO", "Deploy to $Deploy");
        $Deploy = abs_path($Deploy);
        
        if(not -d $Deploy) {
            mkpath($Deploy);
        }
        
        if($TARGET_LIB)
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($Deploy."/".$Dir."/".$TARGET_LIB);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir."/".$TARGET_LIB)
                {
                    printMsg("INFO", "Copy $Dir/$TARGET_LIB");
                    mkpath($Deploy."/".$Dir);
                    system("cp -fr \"$Dir/$TARGET_LIB\" \"$Deploy/$Dir/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$Deploy/\"");
        }
        else
        {
            # clear deploy directory
            foreach my $Dir (@Reports) {
                rmtree($Deploy."/".$Dir);
            }
            
            # copy reports
            foreach my $Dir (@Reports, "db")
            {
                if(-d $Dir)
                {
                    printMsg("INFO", "Copy $Dir");
                    system("cp -fr \"$Dir\" \"$Deploy/\"");
                }
            }
            printMsg("INFO", "Copy css");
            system("cp -fr css \"$Deploy/\"");
        }
    }
}

scenario();
