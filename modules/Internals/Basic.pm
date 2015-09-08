##################################################################
# Module for ABI Monitor with basic functions
#
# Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
##################################################################
use strict;
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

sub composeHTML_Head($$$$$)
{
    my ($Title, $Keywords, $Description, $TopDir, $Styles, $Scripts) = @_;
    
    my $CommonStyles = "common.css";
    
    if($Styles)
    {
        $CommonStyles = "<link rel=\"stylesheet\" type=\"text/css\" href=\"$TopDir/css/$CommonStyles\" />";
        $Styles = "<link rel=\"stylesheet\" type=\"text/css\" href=\"$TopDir/css/$Styles\" />";
    }
    
    if($Scripts) {
        $Scripts = "<script type=\"text/javascript\" src=\"$TopDir/js/$Scripts\"></script>";
    }
    
    return "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">
    <html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">
    <head>
    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />
    <meta name=\"keywords\" content=\"$Keywords\" />
    <meta name=\"description\" content=\"$Description\" />
    $CommonStyles
    $Styles
    $Scripts
    
    <title>
        $Title
    </title>
    
    </head>\n";
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

sub check_Cmd($)
{
    my $Cmd = $_[0];
    return "" if(not $Cmd);
    
    foreach my $Path (sort {length($a)<=>length($b)} split(/:/, $ENV{"PATH"}))
    {
        if(-x $Path."/".$Cmd) {
            return 1;
        }
    }
    
    return 0;
}

return 1;
