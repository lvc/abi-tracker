##################################################################
# A module with simple functions
#
# Copyright (C) 2015-2017 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
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
use strict;
use POSIX qw(strftime);
use Fcntl;

sub findFiles(@)
{
    my ($Path, $Type, $Regex, $Name) = @_;
    my $Cmd = "find \"$Path\"";
    
    if($Type) {
        $Cmd .= " -type ".$Type;
    }
    
    if($Regex) {
        $Cmd .= " -regex \"".$Regex."\"";
    }
    
    if($Name) {
        $Cmd .= " -name \"".$Name."\"";
    }
    
    my @Res = split(/\n/, `$Cmd`);
    return @Res;
}

sub readBytes($)
{ # ELF: 7f454c46
    sysopen(FILE, $_[0], O_RDONLY);
    sysread(FILE, my $Header, 4);
    close(FILE);
    
    my @Bytes = map { sprintf('%02x', ord($_)) } split (//, $Header);
    return join("", @Bytes);
}

sub listDir($)
{
    my $Path = $_[0];
    return () if(not $Path);
    opendir(my $DH, $Path);
    return () if(not $DH);
    my @Contents = grep { $_ ne "." && $_ ne ".." } readdir($DH);
    return @Contents;
}

sub getFilename($)
{ # much faster than basename() from File::Basename module
    if($_[0] and $_[0]=~/([^\/\\]+)[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub getDirname($)
{ # much faster than dirname() from File::Basename module
    if($_[0] and $_[0]=~/\A(.*?)[\/\\]+[^\/\\]*[\/\\]*\Z/) {
        return $1;
    }
    return "";
}

sub readFile($)
{
    my $Path = $_[0];
    return "" if(not $Path or not -f $Path);
    open(FILE, $Path);
    local $/ = undef;
    my $Content = <FILE>;
    close(FILE);
    return $Content;
}

sub appendFile($$)
{
    my ($Path, $Content) = @_;
    return if(not $Path);
    if(my $Dir = getDirname($Path)) {
        mkpath($Dir);
    }
    open(FILE, ">>", $Path) || die ("can't open file \'$Path\': $!\n");
    print FILE $Content;
    close(FILE);
}

sub writeFile($$)
{
    my ($Path, $Content) = @_;
    return if(not $Path);
    if(my $Dir = getDirname($Path)) {
        mkpath($Dir);
    }
    open(FILE, ">", $Path) || die ("can't open file \'$Path\': $!\n");
    print FILE $Content;
    close(FILE);
}

sub extractPackage($$)
{
    my ($Path, $OutDir) = @_;
    
    if($Path=~/\.(tar\.\w+|tgz|tbz2)\Z/i) {
        return "tar -xf $Path --directory=$OutDir";
    }
    elsif($Path=~/\.zip\Z/i) {
        return "unzip $Path -d $OutDir";
    }
    
    return undef;
}

sub readLineNum($$)
{
    my ($Path, $Num) = @_;
    
    open (FILE, $Path) or return undef;
    foreach (1 ... $Num) {
        <FILE>;
    }
    my $Line = <FILE>;
    close(FILE);
    return $Line;
}

sub isHeader($)
{
    my $Path = $_[0];
    return ($Path=~/\.(h|hh|hp|hxx|hpp|h\+\+|tcc)\Z/i);
}

sub cmpVersions_S($$)
{ # compare two versions in dotted-numeric format
    my ($V1, $V2) = @_;
    return 0 if($V1 eq $V2);
    
    my @V1Parts = split(/\./, $V1);
    my @V2Parts = split(/\./, $V2);
    for (my $i = 0; $i <= $#V1Parts && $i <= $#V2Parts; $i++)
    {
        return -1 if(int($V1Parts[$i]) < int($V2Parts[$i]));
        return 1 if(int($V1Parts[$i]) > int($V2Parts[$i]));
    }
    return -1 if($#V1Parts < $#V2Parts);
    return 1 if($#V1Parts > $#V2Parts);
    return 0;
}

sub checkCmd($)
{
    my $Cmd = $_[0];
    
    foreach my $Path (sort {length($a)<=>length($b)} split(/:/, $ENV{"PATH"}))
    {
        if(-x $Path."/".$Cmd) {
            return 1;
        }
    }
    
    return 0;
}

sub getMajor($$)
{
    my ($V, $L) = @_;
    
    $V=~s/[\-_]/./g;
    
    my @P = split(/\./, $V);
    
    if($#P>=$L) {
        return join(".", splice(@P, 0, $L));
    }
    return $V;
}

sub formatNum($)
{
    my $Num = $_[0];
    
    if($Num=~/\A(\d+\.\d\d)/) {
        return $1;
    }
    
    return $Num
}

sub fNum($)
{
    my $N = $_[0];
    if(length($N)==1) {
        return "0".$N;
    }
    return $N;
}

sub getDate()
{
    my ($D, $M, $Y) = (localtime)[3, 4, 5];
    return (1900+$Y)."-".fNum($M+1)."-".fNum($D);
}

sub getRssDate($)
{
    my $Date = $_[0];
    
    my ($Year, $Mon, $Mday, $Hour, $Min) = split(/[\s\-:]+/, $Date);
    return strftime('%a, %d %b %Y %T', 0, $Min, $Hour, $Mday, $Mon-1, $Year-1900)." ".strftime('%z', localtime);
}

sub getS($)
{
    if($_[0]>1) {
        return "s";
    }
    
    return "";
}

return 1;
