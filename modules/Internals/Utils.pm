##################################################################
# A module with basic functions
#
# Copyright (C) 2017-2018 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301 USA
##################################################################
use strict;

sub composeHTML_Head(@)
{
    my $Page = shift(@_);
    my $Title = shift(@_);
    my $Keywords = shift(@_);
    my $Description = shift(@_);
    my $Styles = shift(@_);
    
    my $Scripts = undef;
    if(@_) {
        $Scripts = shift(@_);
    }
    
    my $TopDir = getTop($Page);
    
    my $CommonStyles = "common.css";
    
    if($Styles)
    {
        $CommonStyles = "<link rel=\"stylesheet\" type=\"text/css\" href=\"$TopDir/css/$CommonStyles?v=1.3\" />";
        $Styles = "<link rel=\"stylesheet\" type=\"text/css\" href=\"$TopDir/css/$Styles?v=1.1.1\" />";
    }
    
    if($Scripts) {
        $Scripts = "<script type=\"text/javascript\" src=\"$TopDir/js/$Scripts\"></script>";
    }
    
    if($In::Opt{"GenRss"} and $Page eq "timeline") {
        $Styles .= "\n    <link rel='alternate' type='application/rss+xml' href='../../rss/".$In::Opt{"TargetLib"}."/feed.rss' />";
    }
    
    return "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">
    <html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">
    <head>
    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />
    <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\" />
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

return 1;
