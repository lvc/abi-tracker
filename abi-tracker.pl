#!/usr/bin/perl
##################################################################
# ABI Tracker 1.4
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
#  ABI Dumper (0.99.11 or newer)
#  Vtable-Dumper (1.1 or newer)
#  ABI Compliance Checker (1.99.13 or newer)
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

my $TOOL_VERSION = "1.4";
my $DB_NAME = "Tracker.data";
my $TMP_DIR = tempdir(CLEANUP=>1);

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $ABI_DUMPER = "abi-dumper";
my $ABI_DUMPER_VERSION = "0.99.11";
my $ABI_DUMPER_EE = 0;

my $ABI_CC = "abi-compliance-checker";
my $ABI_CC_VERSION = "1.99.13";

my $RFCDIFF = "rfcdiff";
my $PKGDIFF = "pkgdiff";
my $PKGDIFF_VERSION = "1.6.4";

my $ABI_VIEWER = "abi-viewer";

my ($Help, $DumpVersion, $Build, $Rebuild,
$TargetVersion, $TargetElement, $Clear, $GlobalIndex, $Deploy);

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
License: GPL or LGPL

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
  "deploy=s" => \$Deploy
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
  modify it under the terms of the GNU LGPL or GNU GPL.

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
  
  -deploy DIR
      Copy all reports and css to DIR.
";

my $Profile;
my $DB;
my $TARGET_LIB;
my $DB_PATH = undef;

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
            if($E=~s/\*/\.*/g)
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
            
            createChangelog($V);
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
            
            if(checkTarget("abidiff"))
            {
                createABIDiff($O_V, $V);
            }
        }
    }
    
    if(defined $Profile->{"Versions"}{"current"})
    { # save pull/update time of the code repository
        if(my $UTime = getScmUpdateTime()) {
            $DB->{"ScmUpdateTime"} = $UTime;
        }
    }
}

sub findObjects($)
{
    my $Dir = $_[0];
    
    my @Files = findFiles($Dir, "f", ".*\\.so[0-9.]*");
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

sub skipLib($)
{
    my $Path = $_[0];
    
    if(defined $Profile->{"SkipObjects"})
    {
        my $Name = getFilename($Path);
        my @Skip = @{$Profile->{"SkipObjects"}};
        
        foreach my $L (@Skip)
        {
            if($L=~/\/\Z/)
            { # directory
                if($Path=~/\Q$L\E/) {
                    return 1;
                }
            }
            else
            { # file
                if($L=~s/\*/\.*/g)
                { # pattern
                    if($Name=~/\A$L\Z/) {
                        return 1;
                    }
                }
                else
                { # short name
                    $Name=~s/\..+\Z//g;
                    $L=~s/\..+\Z//g;
                    
                    if($L eq $Name) {
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

sub createChangelog($)
{
    my $V = $_[0];
    
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
        my $Html = toHtml($V, $ChangelogPath);
        
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

sub toHtml($$)
{
    my ($V, $Path) = @_;
    my $Content = readFile($Path);
    
    my $LIM = 500000;
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
    
    my $Note = "";
    
    if($V eq "current")
    {
        if(defined $Profile->{"Git"})
        {
            $Note = " (Git)";
        }
        elsif(defined $Profile->{"Svn"})
        {
            $Note = " (Svn)";
        }
    }
    
    $Content = "<h1>Changelog for <span class='version'>$V</span> version$Note</h1><br/><br/>".$Content;
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
    
    foreach my $Name ("NEWS", "CHANGES", "RELEASE_NOTES", "ChangeLog", "Changelog",
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
            $Head = "$Source/.git/FETCH_HEAD";
            
            if(not -f $Head)
            { # is not updated yet
                $Head = "$Source/.git/HEAD";
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
        
        foreach my $Line (@Files)
        {
            if($Line!~/\Ad/ # skip directories
            and $Line=~/ (\d+\-\d+\-\d+ \d+:\d+) /)
            {
                $Dates{$1} = 1;
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
        
        if(not $Profile->{"PrivateABI"})
        { # set "PrivateABI":1 in the profile to check all symbols
            $Cmd .= " -public-headers \"$Installed\"";
            $Cmd .= " -ignore-tags \"$MODULES_DIR/ignore.tags\"";
        }
        
        if($ABI_DUMPER_EE)
        {
            $Cmd .= " -extra-dump";
            $Cmd .= " -extra-info \"".$Dir."/".$Md5."/debug/\"";
        }
        
        my $Log = `$Cmd`; # execute
        
        if(-f $ABIDump)
        {
            $DB->{"ABIDump"}{$V}{$Md5}{"Path"} = $ABIDump;
            $DB->{"ABIDump"}{$V}{$Md5}{"Object"} = $RPath;
            
            my $Dump = eval(readFile($ABIDump));
            $DB->{"ABIDump"}{$V}{$Md5}{"Lang"} = $Dump->{"Language"};
            
            my @Meta = ();
            
            push(@Meta, "\"Object\": \"".$RPath."\"");
            push(@Meta, "\"Lang\": \"".$Dump->{"Language"}."\"");
            push(@Meta, "\"PublicABI\": \"1\"");
            
            writeFile($Dir."/".$Md5."/meta.json", "{\n  ".join(",\n  ", @Meta)."\n}");
        }
        else
        {
            printMsg("ERROR", "can't create ABI dump");
            rmtree($ABIDir);
        }
    }
}

sub getObjectName($$)
{
    my ($Object, $T) = @_;
    
    my $Name = getFilename($Object);
    
    if($T eq "Short")
    {
        if($Name=~/\A(.+)\.so[\d\.]*\Z/) {
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

sub createABIDiff($$)
{
    my ($V1, $V2) = @_;
    
    # TODO
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
    
    if(not defined $DB->{"ABIDump"}{$V1}) {
        createABIDump($V1);
    }
    if(not defined $DB->{"ABIDump"}{$V2}) {
        createABIDump($V2);
    }
    
    if(not defined $DB->{"Soname"}{$V1}) {
        detectSoname($V1);
    }
    if(not defined $DB->{"Soname"}{$V2}) {
        detectSoname($V2);
    }
    
    my $D1 = $DB->{"ABIDump"}{$V1};
    my $D2 = $DB->{"ABIDump"}{$V2};
    
    if(not $D1 or not $D2) {
        return 0;
    }
    
    # Remove old reports
    my $CDir = "compat_report/$TARGET_LIB/$V1/$V2";
    
    if(-d $CDir) {
        rmtree($CDir);
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
    
    @Objects1 = sort {lc($a) cmp lc($b)} @Objects1;
    @Objects2 = sort {lc($a) cmp lc($b)} @Objects2;
    
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
    
    foreach my $Object1 (@Objects)
    {
        if(skipLib($Object1)) {
            next;
        }
        compareABIs($V1, $V2, $Object1, $Mapped{$Object1});
    }
    
    my $Report = "";
    
    $Report .= getHead("objects_report");
    $Report .= "<h1>Objects ABI report: <span class='version'>$V1</span> vs <span class='version'>$V2</span></h1>\n"; # API/ABI changes report
    $Report .= "<br/>\n";
    $Report .= "<br/>\n";
    
    $Report .= "<table class='summary'>\n";
    $Report .= "<tr>";
    $Report .= "<th>Object</th>\n";
    $Report .= "<th>Backward<br/>Compatibility</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Report .= "<th>Total<br/>Problems</th>\n";
    }
    $Report .= "<th>Added<br/>Symbols</th>\n";
    $Report .= "<th>Removed<br/>Symbols</th>\n";
    $Report .= "</tr>\n";
    
    foreach my $Object2 (@Objects2)
    {
        my $Name = $Object2;
        $Name=~s/\Alib(64|32|)\///;
        
        if(defined $Added{$Object2})
        {
            $Report .= "<tr>\n";
            $Report .= "<td class='object'>$Name</td>\n";
            $Report .= "<td colspan='3' class='added'>Added to package</td>\n";
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
        $Name=~s/\Alib(64|32|)\///;
        
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
                $Name .= "<span class='incompatible'>(changed file name from<br/>\"$Object1\"<br/>to<br/>\"".$RenamedObject{$Object1}."\")</span>";
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
                
                $Report .= "<td class=\'$CClass\'><a href='../../../../".$ABIReport_D->{"Path"}."'>".formatNum($BC_D)."%</a></td>\n";
                
                if($Profile->{"ShowTotalProblems"})
                {
                    if($TotalProblems) {
                        $Report .= "<td class=\'$CClass\'><a class='num' href='../../../../".$ABIReport_D->{"Path"}."'>$TotalProblems</td>\n";
                    }
                    else {
                        $Report .= "<td class='ok'>0</td>\n";
                    }
                }
                
                if($AddedSymbols) {
                    $Report .= "<td class='added'><a class='num' href='../../../../".$ABIReport_D->{"Path"}."#Added'>$AddedSymbols new</td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
                
                if($RemovedSymbols) {
                    $Report .= "<td class='removed'><a class='num' href='../../../../".$ABIReport_D->{"Path"}."#Removed'>$RemovedSymbols removed</td>\n";
                }
                else {
                    $Report .= "<td class='ok'>0</td>\n";
                }
            }
            else
            {
                foreach (1 .. 3) {
                    $Report .= "<td>N/A</td>\n";
                }
            }
        }
        elsif(defined $Removed{$Object1})
        {
            $Report .= "<td colspan='3' class='removed'>Removed from package</td>\n";
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
    
    my ($Affected_T, $AddedSymbols_T, $RemovedSymbols_T, $TotalProblems_T) = ();
    
    my $TotalFuncs = 0;
    
    foreach my $Object (@Objects)
    {
        my $Md5 = getMd5($Object, $Mapped{$Object});
        if(defined $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5})
        {
            my $ABIReport_D = $DB->{"ABIReport_D"}{$V1}{$V2}{$Md5};
            
            my $Dump = $DB->{"ABIDump"}{$V1}{getMd5($Object)}{"Path"};
            my $DumpContent = eval(readFile($Dump));
            
            my $Funcs = keys(%{$DumpContent->{"SymbolInfo"}});
            
            $Affected_T += $ABIReport_D->{"Affected"} * $Funcs;
            $AddedSymbols_T += $ABIReport_D->{"Added"};
            $RemovedSymbols_T += $ABIReport_D->{"Removed"};
            $TotalProblems_T += $ABIReport_D->{"TotalProblems"};
            
            $TotalFuncs += $Funcs;
        }
    }
    
    my $BC = 100;
    
    if($TotalFuncs) {
        $BC -= $Affected_T/$TotalFuncs;
    }
    
    if(my $Rm = keys(%Removed) and $#Objects1>=0) {
        $BC *= (1-$Rm/($#Objects1+1));
    }
    
    $BC = formatNum($BC);
    
    $DB->{"ABIReport"}{$V1}{$V2}{"Path"} = $Output;
    $DB->{"ABIReport"}{$V1}{$V2}{"BC"} = $BC;
    $DB->{"ABIReport"}{$V1}{$V2}{"Added"} = $AddedSymbols_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"Removed"} = $RemovedSymbols_T;
    $DB->{"ABIReport"}{$V1}{$V2}{"TotalProblems"} = $TotalProblems_T;
    
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsAdded"} = keys(%Added);
    $DB->{"ABIReport"}{$V1}{$V2}{"ObjectsRemoved"} = keys(%Removed);
    $DB->{"ABIReport"}{$V1}{$V2}{"ChangedSoname"} = keys(%ChangedSoname);
    $DB->{"ABIReport"}{$V1}{$V2}{"TotalObjects"} = $#Objects1 + 1;
    
    my @Meta = ();
    
    push(@Meta, "\"BC\": \"".$BC."\"");
    push(@Meta, "\"Added\": ".$AddedSymbols_T);
    push(@Meta, "\"Removed\": ".$RemovedSymbols_T);
    push(@Meta, "\"ObjectsAdded\": ".keys(%Added));
    push(@Meta, "\"ObjectsRemoved\": ".keys(%Removed));
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
    
    my $Log = `$Cmd`; # execute
    
    $DB->{"ABIView_D"}{$V}{$Md5}{"Path"} = $Output;
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
    
    my $Dir = "compat_report/$TARGET_LIB/$V1/$V2";
    $Dir .= "/".$Md5;
    my $Output = $Dir."/abi_compat_report.html";
    my $Module = getObjectName(getFilename($Obj1), "Short");
    
    my $Cmd = $ABI_CC." -l \"$Module\" -bin -old \"".$Dump1->{"Path"}."\" -new \"".$Dump2->{"Path"}."\" -report-path \"$Output\"";
    
    if(my $SkipSymbols = $Profile->{"SkipSymbols"}) {
        $Cmd .= " -skip-symbols \"$SkipSymbols\"";
    }
    
    if(my $SkipTypes = $Profile->{"SkipTypes"}) {
        $Cmd .= " -skip-types \"$SkipTypes\"";
    }
    
    if(my $SkipInternalSymbols = $Profile->{"SkipInternalSymbols"}) {
        $Cmd .= " -skip-internal-symbols \"$SkipInternalSymbols\"";
    }
    
    if(my $SkipInternalTypes = $Profile->{"SkipInternalTypes"}) {
        $Cmd .= " -skip-internal-types \"$SkipInternalTypes\"";
    }
    
    my $Log = `$Cmd`; # execute
    
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
    
    my @Files1 = findFiles($I_Dir1, "f");
    my @Files2 = findFiles($I_Dir2, "f");
    
    my %Files1 = ();
    my %Files2 = ();
    
    foreach my $Path (@Files1)
    {
        if($Path=~/\A\Q$I_Dir1\E\/*(.+?)\Z/) {
            $Files1{$1} = $Path;
        }
    }
    
    foreach my $Path (@Files2)
    {
        if($Path=~/\A\Q$I_Dir2\E\/*(.+?)\Z/) {
            $Files2{$1} = $Path;
        }
    }
    
    my $Dir = $TMP_DIR."/diff/";
    
    my @Reports = ();
    
    foreach my $Path (sort {lc($a) cmp lc($b)} keys(%Files1))
    {
        if(not isHeader($Path)) {
            next;
        }
        
        my $Path1 = $Files1{$Path};
        my $Path2 = undef;
        
        if(defined $Files2{$Path}) {
            $Path2 = $Files2{$Path};
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
        
        mkpath(getDirname($TMP_DIR."/".$Path));
        
        my $Cmd_R = $RFCDIFF." --width 75 --stdout \"$Path1\" \"$Path2\" >$TMP_DIR/$Path 2>/dev/null";
        qx/$Cmd_R/; # execute
        
        if(-s "$TMP_DIR/$Path") {
            push(@Reports, "$TMP_DIR/$Path");
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
        $RPath=~s/\A$TMP_DIR\///;
        
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
    
    rmtree($Dir);
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
    
    my $Head = "";
    
    $Head .= "<table cellpadding='0' cellspacing='0'>";
    $Head .= "<tr>";
    
    $Head .= "<td align='center'>";
    $Head .= "<h1 class='tool'><a title=\'Home: ABI tracker for ".showTitle()."\' href='$UrlPr/timeline/$TARGET_LIB/index.html' class='tool'>ABI<br/>Tracker</a></h1>";
    $Head .= "</td>";
    
    $Head .= "<td width='30px;'>";
    $Head .= "</td>";
    
    if($Sel ne "global_index")
    {
        $Head .= "<td>";
        $Head .= "<h1>(".showTitle().")</h1>";
        $Head .= "</td>";
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
    my $Desc = "API/ABI compatibility analysis reports for ".$TARGET_LIB;
    my $Content = composeHTML_Head($Title, $TARGET_LIB.", ABI, API, compatibility, report", $Desc, getTop("timeline"), "report.css", "");
    $Content .= "<body>\n";
    
    my @Versions = getVersionsList();
    
    my $Changelog = "Off";
    my $HeadersDiff = "Off";
    my $PkgDiff = "Off";
    
    # High-detailed analysis for Enterprise usage (non-free)
    my $ABIView = "Off";
    my $ABIDiff = "Off";
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
        
        if($Profile->{"Versions"}{$V}{"ABIDiff"} eq "On")
        {
            $ABIDiff = "On";
        }
    }
    
    $Content .= getHead("timeline");
    
    $Content .= "<h1>API/ABI changes timeline</h1>\n";
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    $Content .= "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>\n";
    $Content .= "<th>Version</th>\n";
    $Content .= "<th>Date</th>\n";
    $Content .= "<th>Soname</th>\n";
    
    if($Changelog ne "Off") {
        $Content .= "<th>Change<br/>Log</th>\n";
    }
    
    $Content .= "<th>Backward<br/>Compatibility</th>\n";
    if($Profile->{"ShowTotalProblems"}) {
        $Content .= "<th>Total<br/>Problems</th>\n";
    }
    $Content .= "<th>Added<br/>Symbols</th>\n";
    $Content .= "<th>Removed<br/>Symbols</th>\n";
    
    if($HeadersDiff ne "Off") {
        $Content .= "<th>Headers<br/>Diff</th>\n";
    }
    
    if($PkgDiff ne "Off") {
        $Content .= "<th>Package<br/>Diff</th>\n";
    }
    
    if($ABIView ne "Off") {
        $Content .= "<th title='Generated by the ABI Viewer tool from ".$HomePage."'>ABI<br/>View*</th>\n";
    }
    if($ABIDiff ne "Off") {
        $Content .= "<th title='Generated by the ABI Viewer tool from ".$HomePage."'>ABI<br/>Diff*</th>\n";
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
        my $ABIDiffReport = undef;
        
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
        if(defined $DB->{"ABIDiff"} and defined $DB->{"ABIDiff"}{$V}
        and defined $DB->{"ABIDiff"}{$O_V}{$V}) {
            $ABIDiffReport = $DB->{"ABIDiff"}{$O_V}{$V};
        }
        
        my $Date = "N/A";
        my $Sover = "N/A";
        
        if(defined $DB->{"Date"} and defined $DB->{"Date"}{$V}) {
            $Date = $DB->{"Date"}{$V};
        }
        
        if(defined $DB->{"Sover"} and defined $DB->{"Sover"}{$V}) {
            $Sover = $DB->{"Sover"}{$V};
        }
        
        $Content .= "<tr>";
        
        $Content .= "<td>$V</td>\n";
        $Content .= "<td>".showDate($V, $Date)."</td>\n";
        $Content .= "<td>".$Sover."</td>\n";
        
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
        
        if($Profile->{"ShowTotalProblems"})
        {
            if(defined $ABIReport)
            {
                if(my $TotalProblems = $ABIReport->{"TotalProblems"})
                {
                    my $TClass = "incompatible";
                    if(int($ABIReport->{"BC"})>=90) {
                        $TClass = "warning";
                    }
                    
                    $Content .= "<td class=\'$TClass\'><a class='num' href='../../".$ABIReport->{"Path"}."'>$TotalProblems</a></td>\n";
                }
                else {
                    $Content .= "<td class='ok'>0</td>\n";
                }
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        if(defined $ABIReport)
        {
            if(my $Added = $ABIReport->{"Added"}) {
                $Content .= "<td class='added'><a class='num' href='../../".$ABIReport->{"Path"}."'>$Added new</a></td>\n";
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
                $Content .= "<td class='removed'><a class='num' href='../../".$ABIReport->{"Path"}."'>$Removed removed</a></td>\n";
            }
            else {
                $Content .= "<td class='ok'>0</td>\n";
            }
        }
        else {
            $Content .= "<td>N/A</td>\n";
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
        
        if($ABIDiff ne "Off")
        {
            if(defined $ABIDiffReport and $Profile->{"Versions"}{$V}{"ABIDiff"} eq "On") {
                $Content .= "<td><a href='../../".$ABIDiffReport->{"Path"}."'>diff</a></td>\n";
            }
            else {
                $Content .= "<td>N/A</td>\n";
            }
        }
        
        $Content .= "</tr>\n";
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
    $Content .= "Last updated on ".localtime($DB->{"Updated"}).".";
    
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
    #$Content .= "<th>Maintainer</th>\n";
    $Content .= "</tr>\n";
    
    foreach my $L (sort @Libs)
    {
        my $DB = eval(readFile("db/$L/$DB_NAME"));
        my $Title = $L;
        if(defined $DB->{"Title"}) {
            $Title = $DB->{"Title"};
        }
        
        $Content .= "<tr>\n";
        $Content .= "<td class='sl'>$Title</td>\n";
        $Content .= "<td><a href='timeline/$L/index.html'>timeline</a></td>\n";
        
        #my $M = $DB->{"Maintainer"};
        
        #if(defined $DB->{"MaintainerUrl"}) {
        #    $M = "<a href='".$DB->{"MaintainerUrl"}."'>$M</a>";
        #}
        
        #$Content .= "<td>$M</td>\n";
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
                
                $Info{"Path"} = $Dumps."/".$V."/".$Md5."/ABI.dump";
                
                my $Meta = readProfile(readFile($Dir."/meta.json"));
                $Info{"Object"} = $Meta->{"Object"};
                $Info{"Lang"} = $Meta->{"Lang"};
                
                $DB->{"ABIDump"}{$V}{$Md5} = \%Info;
            }
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
        if($TargetElement!~/\A(date|dates|soname|changelog|abidump|abireport|rfcdiff|headersdiff|pkgdiff||packagediff|abiview|abidiff)\Z/)
        {
            exitStatus("Error", "the value of -target option should be one of the following: date, soname, changelog, abidump, abireport, rfcdiff, pkgdiff.");
        }
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
