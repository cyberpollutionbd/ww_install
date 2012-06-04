#!/usr/bin/env perl
##########################################################################################################
#WeBWorK Installation Script
#
#Goals:
#(1) interactively install webwork on any machine on which the prerequisites are installed
#(2) do as much as possible for the user, finding paths, writing config files, etc.
#(3) never use anything other than core perl modules, webwork modules, webwork prerequisite modules
#(4) eventually add options for --nointeractive, --with-svn, other?
#
#How it works
#(1) check if running as root
#(2) Have you downloaded webwork already?
#--if so, where is webwork2/, pg/, NationalProblemLibrary/?
#--if not, do you want me to get the software for you via svn?
#(3) check prerequisites, using this opportunity to populate %externalPrograms hash, and gather 
#environment information: $server_userID, $server_groupID, hostname?, timezone?
#(4) Initially ask user minimum set of config questions:
#-Directory root PREFIX
#--accept standard webwork layout below PREFIX? (later)
#-$server_root_url   = "";  # e.g.  http://webwork.yourschool.edu (default from hostname lookup in (2))
#-$server_userID     = "";  # e.g.  www-data    (default from httpd.conf lookup in (2))
#-$server_groupID    = "";  # e.g.  wwdata      (default from httpd.conf lookup in (2))
#-$mail{smtpServer}            = 'mail.yourschool.edu';
#-$mail{smtpSender}            = 'webwork@yourserver.yourschool.edu';
#-$mail{smtpTimeout}           = 30;
#-database root password
#-$database_dsn = "dbi:mysql:webwork";
#-$database_username = "webworkWrite";
#-$database_password = "";
#-$siteDefaults{timezone} = "America/New_York";
#(5) Put software in correct locations
#(6) use gathered information to write initial global.conf file, webwork.apache2-config,database.conf, 
#wwapache2ctl, 
#(7) check and fix filesystem permissions in webwork2/ tree
#(8) Create initial database user, initial mysql tables
#(9) Create admin course
#(10) append include statement to httpd.conf to pick up webwork.apache2-config
#(11) restart apache, check for errors 
#(12) Do some testing!


use strict;
use warnings;

use Config;

use File::Path qw(make_path);
use File::Spec;
use File::Copy;
use File::CheckTree;

use IPC::Cmd qw(can_run run run_forked);
use Term::UI;
use Term::ReadLine;
use Params::Check qw(check);

use Sys::Hostname;
use User::pwent;
use Data::Dumper;

use DBI;

use DB_File;
use Fcntl;

use POSIX;

#Non-core
use DateTime::TimeZone;

my @apacheBinaries = qw(
  apache2
  apachectl
);

my @applicationsList = qw(
	mv
  cp
  rm
  mkdir
	tar
	gzip
	latex
	pdflatex
	dvipng
	tth
	mysql
	giftopnm
	ppmtopgm
	pnmtops
  pnmtopng
  pngtopnm
  lwp-request
  mysql
  mysqldump
  svn
);

my @apache1ModulesList = qw(
	Apache
	Apache::Constants 
	Apache::Cookie
	Apache::Log
	Apache::Request
);

my @apache2ModulesList = qw(
	Apache2::Request
	Apache2::Cookie
	Apache2::ServerRec
	Apache2::ServerUtil
);

my @modulesList = qw(
	Benchmark
	Carp
	CGI
	Data::Dumper
	Data::UUID 
	Date::Format
	Date::Parse
	DateTime
	DBD::mysql
	DBI
	Digest::MD5
	Email::Address
	Errno
	Exception::Class
	File::Copy
	File::Find
	File::Path
	File::Spec
	File::stat
	File::Temp
	GD
	Getopt::Long
	Getopt::Std
	HTML::Entities
	HTML::Tagset
	IO::File
	Iterator
	Iterator::Util
	Mail::Sender
	MIME::Base64
	Net::IP
	Net::LDAPS
	Net::SMTP
	Opcode
	PadWalker
	PHP::Serialization
	Pod::Usage
	Pod::WSDL
	Safe
	Scalar::Util
	SOAP::Lite 
	Socket
	SQL::Abstract
	String::ShellQuote
	Text::Wrap
	Tie::IxHash
	Time::HiRes
	Time::Zone
	URI::Escape
  UUID::Tiny
	XML::Parser
	XML::Parser::EasyTree
	XML::Writer
	XMLRPC::Lite
);


####################################################################
#
# Check if the user is root 
#
####################################################################
# We probably need to be root. The effective user id of the user running the script
# is held in the perl special variable $>.  In particular,
# if $> = 0 user is root, works with sudo too.
# run it like this at the top of the script:
#check_root() or die "Please run this script as root or with sudo.\n";

sub check_root {
  if($> == 0) {
    print "Running as root....\n";
    return 1;
  } else {
    my $term = Term::ReadLine->new('');
my $print_me =<<EOF;
IMPORTANT: This script is not running as root. Typically root privliges are
needed to install WeBWorK. You should probably quit now and run the script
as root or with sudo.
EOF
    my $prefix = $term -> ask_yn(
                  print_me => $print_me,
                  prompt => 'Continue without root privliges?',
                  default => 0,
                );
  }
}


####################################################################
#
# Environment Data
#
####################################################################
# What use is this information? 
# - any reason to get the hostname?
# - maybe use OS to do OS specific processing?
# - maybe warn against perl versions that are too old; version specific perl bugs?
# - maybe process timezone separately?

sub get_environment {
 $_->{OS} = $^O;
 $_->{host} = hostname;
 $_->{perl} = $^V;

  my $timezone = DateTime::TimeZone -> new(name=>'local');
  $_ -> {timezone} = $timezone->name;
  my %siteDefaults;
  print "Looks like you're on ". ucfirst($_->{OS})."\n";
  print "And your hostname is ". $_->{host} ."\n";
  print "You're running Perl $_->{perl}\n";
  print "Your timezone is $_->{timezone}\n";
}

####################################################################
#
# Check for perl modules
#
# ##################################################################
# do we really want to eval "use $module;"?

sub check_modules {
	my @modulesList = @_;
	
	print "\nChecking your \@INC for modules required by WeBWorK...\n";
	my @inc = @INC;
	print "\@INC=";
	print join ("\n", map("     $_", @inc)), "\n\n";
	
	foreach my $module (@modulesList)  {
		eval "use $module";
		if ($@) {
			my $file = $module;
			$file =~ s|::|/|g;
			$file .= ".pm";
			if ($@ =~ /Can't locate $file in \@INC/) {
				print "** $module not found in \@INC\n";
			} else {
				print "** $module found, but failed to load: $@";
			}
		} else {
			print "   $module found and loaded\n";
		}
	}
}

#####################################################################
#
#Check for prerequisites and get paths for binaries
#
#####################################################################

sub configure_externalPrograms {
  #Expects a list of applications 	
  my @applicationsList = @_;
	print "\nChecking your system for executables required by WeBWorK...\n";
	
  my $apps;
	foreach my $app (@applicationsList)  {
		$apps->{$app} = File::Spec->canonpath(can_run($app));
		if ($apps->{$app}) {
			print "   $app found at ${$apps}{$app}\n";
      if($app eq 'lwp-request') {
        delete $apps -> {$app};
        $apps -> {check_url} = "$app".' -d -mHEAD';
      }
		} else {
			warn "** $app not found in \$PATH\n";
		}
	}
  my (undef,$netpbm_prefix,undef) = File::Spec->splitpath(${$apps}{giftopnm});
  $$apps{gif2eps} = "$$apps{giftopnm}"." | ".$$apps{ppmtopgm}." | " .$$apps{pnmtops} ." -noturn 2>/dev/null";
  $$apps{png2eps} = "$$apps{pngtopnm}"." | ".$$apps{ppmtopgm}." | " .$$apps{pnmtops} ." -noturn 2>/dev/null";
  $$apps{gif2png} = "$$apps{giftopnm}"." | "."$$apps{pnmtopng}";

  return Data::Dumper->Dump([$netpbm_prefix,$apps],[qw(*netpbm_prefix *externalPrograms)]);
}

############################################################################
#
#Configure the %webworkDirs hash
#
############################################################################

sub configure_webworkDirs {
  my $prefix = shift;
  my %webworkDirs;
  my $webwork_dir;
  my $webwork_courses_dir;
  my $webwork_htdocs_dir;
  $webworkDirs{root}          = "$webwork_dir";
  $webworkDirs{bin}           = "$webworkDirs{root}/bin";
  $webworkDirs{conf}          = "$webworkDirs{root}/conf";
  $webworkDirs{logs}          = "$webworkDirs{root}/logs";
  $webworkDirs{tmp}           = "$webworkDirs{root}/tmp";
  $webworkDirs{templates}     = "$webworkDirs{conf}/templates";
  $webworkDirs{DATA}          = "$webworkDirs{root}/DATA";
  $webworkDirs{uploadCache}   = "$webworkDirs{DATA}/uploads";
  $webworkDirs{courses}       = "$webwork_courses_dir" || "$webworkDirs{root}/courses";
  $webworkDirs{valid_symlinks}   = [];
  $webworkDirs{htdocs}        = "$webwork_htdocs_dir" || "$webworkDirs{root}/htdocs";
  $webworkDirs{local_help}    = "$webworkDirs{htdocs}/helpFiles";
  $webworkDirs{htdocs_temp}   = "$webworkDirs{htdocs}/tmp";
  $webworkDirs{equationCache} = "$webworkDirs{htdocs_temp}/equations";
}

############################################################################
#
#Configure the %webworkFiles hash
#
############################################################################

sub configure_webworkFiles {
}

############################################################################
#
#Configure the %webworkURLs hash
#
############################################################################

sub configure_webworkURLs {
}

############################################################################
#
#Configure the %courseDirs hash
#
############################################################################

sub configure_courseDirs {
}

############################################################################
#
#Configure the %courseFiles hash
#
############################################################################

sub configure_courseFiles {
}

############################################################################
#
#Configure the %courseURLS hash
#
############################################################################

sub configure_courseURLs {
}

############################################################################
#
#Configure the %mail hash
#
############################################################################

sub configure_mail {
  #$mail{smtpServer}            = 'mail.yourschool.edu';
  #$mail{smtpSender}            = 'webwork@yourserver.yourschool.edu';
  #$mail{smtpTimeout}           = 30;
  #$mail{allowedRecipients}     = [
    ##'prof1@yourserver.yourdomain.edu',
    ##'prof2@yourserver.yourdomain.edu',
  #];
  #$mail{feedbackRecipients}    = [
    ##'prof1@yourserver.yourdomain.edu',
    ##'prof2@yourserver.yourdomain.edu',
  #];

}

############################################################################
#
#Configure the database 
#
############################################################################

sub configure_database {
  #$database_dsn = "dbi:mysql:webwork";
  #$database_username = "webworkWrite";
  #$database_password = "";
  #$database_debug = 0;
  #$moodle_dsn = "dbi:mysql:moodle";
  #$moodle_username = $database_username;
  #$moodle_password = $database_password;
  #$moodle_table_prefix = "mdl_";
  #$moodle17 = 0;
  #$dbLayoutName = "sql_single";
  #*dbLayout     = $dbLayouts{$dbLayoutName};

}


############################################################################
#
# Get the software, put it in the correct location 
#
############################################################################

sub get_webwork {

}

sub create_prefix_path {
  my $dir = shift;
  #Check that path given is an absolute path
  #Confirm that user wants this
  #Create path - can we create a new wwadmin group?
  make_path($dir,{owner=>'root',group=>'root'});
}


###############################################################
#
# Ask user some configuation questions
# This seeems to be the minimal set of questions the user needs
# to answer to set up a standard, no frills, webwork installation.
#
#(1) Check if script is being run as root user
#(2) Directory root PREFIX
#(3) $server_root_url   = "";  # e.g.  http://webwork.yourschool.edu
#(4) $mail{smtpServer}            = 'mail.yourschool.edu';
#(5) $mail{smtpSender}            = 'webwork@yourserver.yourschool.edu';
#(6) database root password
#(7) $database_dsn = "dbi:mysql:webwork";
#(8) $database_username = "webworkWrite";
#(9) $database_password = "";
#(10) $siteDefaults{timezone} = "America/New_York";
###############################################################

#Don't worry people with spurious warnings.
$Term::UI::VERBOSE = 0;


print<<END;
Welcome to the WeBWorK.  This installation script will ask you a few questions and then attempt to install WeBWorK on your system.
END

print<<EOF;
###################################################################
#
# Checking for required perl modules and external programs...
#
# #################################################################
EOF

check_modules(@modulesList);
check_modules(@apache2ModulesList);
print configure_externalPrograms(@applicationsList);



print<<EOF;
###################################################################
#
# Looking for Apache
#
# #################################################################
EOF

my %apache;
$apache{binary} = File::Spec->canonpath(can_run('apache2ctl') || can_run('apachectl')) or die "Can't find Apache!\n";

open(HTTPD,"$apache{binary} -V |") or die "Can't do this: $!";
print "Your apache start up script is at $apache{binary}\n";

while(<HTTPD>) {
  if ($_ =~ /apache.(\d\.\d\.\d+)/i){
    $apache{version} = $1;
    print "Your apache version is $apache{version}\n";
  } elsif ($_ =~ /HTTPD_ROOT\=\"((\/\w+)+)"$/) {
    $apache{root} = File::Spec->canonpath($1);
    print "Your apache server root is $apache{root}\n";
  } elsif ($_=~ /SERVER_CONFIG_FILE\=\"((\w+\/)+(\w+\.?)+)\"$/) {
    $apache{conf} = File::Spec->catfile($apache{root},$1);
    print "Your apache config file is $apache{conf}\n";
  }
}
close(HTTPD);

open(HTTPDCONF,$apache{conf}) or die "Can't do this: $!";
while(<HTTPDCONF>){
  if (/^User/) {
    (undef,$apache{user}) = split;
    print "Apache runs as user $apache{user}\n";
  } elsif (/^Group/){
    (undef,$apache{group}) = split;
    print "Apache runs in group $apache{group}\n";
  }
}
close(HTTPDCONF);
#configure_server();
#check_perl(@apache2ModulesList);
#configure_webworkURLS();
#configure_courseURLs();

#test_server();

  my $term = Term::ReadLine->new('');
sub get_WW_PREFIX {
  my $default = shift;
  my $print_me =<<END; 
#################################################################
# Installation Prefix: Please enter the absolute path of the directory
# under which we should install the webwork software. A typical choice
# is /opt/webwork/. We will create # four subdirectories under your PREFIX:
#
# PREFIX/webwork2 - for the core code for the web-applcation
# PREFIX/pg - for the webwork problem generating language PG
# PREFIX/libraries - for the National Problem Library and other problem libraries
# PREFIX/courses - for the individual webwork courses on your server
#
# Note that we will also set a new system wide environment variable WEBWORK_ROOT 
# to PREFIX/webwork2/
#################################################################
END
  my $dir= $term -> get_reply(
              print_me => $print_me,
              prompt => 'Where should I install webwork?',
              default => $default,
            );
  #has this been confirmed?
  my $confirmed = 0;

  #remove trailing "/"'s
  $dir = File::Spec->canonpath($dir);


  # Now we'll check for errors, if we don't need any fixes, we'll move on
  my $fix = 0;

  #check if reply is an absolute path
  my $is_absolute = File::Spec->file_name_is_absolute($dir);
  if($is_absolute) { #everything is find by us, let's confirm with user
   $confirmed = confirm_answer($dir);
  } else {
    $dir = File::Spec->rel2abs($dir);
    $fix = $term -> get_reply(
      print_me => "I need an absolute path, but you gave me a relative path.",
      prompt => "How do you want to fix this? ",
      choices =>["Go back","I really meant $dir","Quit"]
    );
  }

  if($fix eq "Go back") {
    $fix = 0;
    get_WW_PREFIX('/opt/webwork');
  } elsif($fix eq "I really meant $dir") {
    $fix = 0;
    $confirmed = confirm_answer($dir);
  } elsif($fix eq "Quit") {
    die "Exiting...";
  }
  if($confirmed && !$fix) {
    print "Got it, I'll create $dir and install webwork there.\n";
    print "\$confirmed = $confirmed and \$fix = $fix\n";
    return $dir;
  } else {
    print "Here!\n";
    get_WW_PREFIX('/opt/webwork');
  }
}




sub confirm_answer {
  my $answer = shift;   
  my $confirm = $term -> get_reply(
    print_me => "Ok, you entered $answer. Please confirm.",
    prompt => "Well? ",
    choices => ["Looks good.","Change my answer.","Quit."],
    defalut => "Looks good."
    );
  if($confirm eq "Quit."){
    die "Exiting...";
  } elsif($confirm eq "Change my answer.") {
    return 0;
  } else {
    return 1;
  }
}



my $WW_PREFIX = get_WW_PREFIX('/opt/webwork');

#Make the path!
#configure_webworkDirs();

#Ask about - no defaults from system info
my $server_root_url   = "http://localhost";  # e.g.  http://webwork.yourschool.edu
#my %mail;
#$mail{smtpServer}            = 'mail.yourschool.edu';
#$mail{smtpSender}            = 'webwork@yourserver.yourschool.edu';
#$mail{smtpTimeout}           = 30;

#my $database_rootpw;
#my $database_dsn = "dbi:mysql:webwork";
#my $database_username = "webworkWrite";
#my $database_password = "";

#Ask about - defaults from system info
#my $server_root_url   = "";  # e.g.  http://webwork.yourschool.edu
#my $server_userID     = "";  # e.g.  www-data    
#my $server_groupID    = "";  # e.g.  wwdata


#Initially derived from user input
#my $webwork_url = "/webwork2";
#my $webwork_htdocs_dir "$webwork_dir/htdocs";
#my $webwork_htdocs_url  = "/webwork2_files";

#== Top level determined from PREFIX ==
#$webwork_dir         = "$WW_PREFIX/webwork2";
#$pg_dir              = "$WW_PREFIX/pg";
#$webwork_courses_dir = "$WW_PREFIX/courses"; 
#$problemLibrary{root}        = "$WW_PREFIX/libraries/NationalProblemLibrary";
#$webwork_htdocs_dir  = "$webwork_dir/htdocs";
#my %mail;
sub create_install_dir {
  my $dir = shift;
  #check that user entered absolute path

  #create directory with mkdir -p
}

my $print_me=<<END;
# URL of WeBWorK handler. If WeBWorK is to be on the web server root, use "". Note 
# that using "" may not work so we suggest sticking with "/webwork2".
END
#my $webwork_url = $term-> get_reply(
                        #print_me => $print_me,
                        #prompt => "Relative URL of WeBWorK handler:",
                        #default => "/webwork2"
                      #);

$print_me=<<END;
# Root url of the webwork server.
END
#my $server_root_url-> get_reply(
                        #print_me => $print_me,
                        #prompt => "Root url of the webwork server:",
                        #default => "/webwork2"
                      #);;


$print_me=<<END;
END

$print_me=<<END;
# In the apache configuration file (often called httpd.conf) you will find
# User wwadmin   --- this is the \$server_userID -- of course it may be wwhttpd or some other name
# Group wwdata   --- this is the \$server_groupID -- this will have different names also
END

$print_me=<<END;
# In the apache configuration file (often called httpd.conf) you will find
# User wwadmin   --- this is the \$server_userID -- of course it may be wwhttpd or some other name
# Group wwdata   --- this is the \$server_groupID -- this will have different names also
END


#############################################################
#
# Put software in correct location, write configuration files
#
#############################################################

##############################################################
#
# Adjust file owernship and permissions
#
#############################################################


#############################################################
#
# Create admin course
#
# ###########################################################


#############################################################
#
# Launch web-browser
#
#############################################################

__DATA__
#!perl
################################################################################
# WeBWorK Online Homework Delivery System
# Copyright � 2000-2007 The WeBWorK Project, http://openwebwork.sf.net/
# $CVSHeader: webwork2/conf/global.conf.dist,v 1.225 2010/05/18 18:03:31 apizer Exp $
# 
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

# This file is used to set up the default WeBWorK course environment for all
# requests. Values may be overwritten by the course.conf for a specific course.
# All package variables set in this file are added to the course environment.
# If you wish to set a variable here but omit it from the course environment,
# use the "my" keyword. The $webwork_dir variable is set in the WeBWorK Apache
# configuration file (webwork.apache-config) and is available for use here. In
# addition, the $courseName variable holds the name of the current course.

################################################################################
# Seed variables
################################################################################

# Set these variables to correspond to your configuration and preferences. You
# will need to restart the webserver to reset the variables in this section.

# URL of WeBWorK handler. If WeBWorK is to be on the web server root, use "". Note 
# that using "" may not work so we suggest sticking with "/webwork2".
$webwork_url         = "/webwork2";


$server_root_url   = "";  # e.g.  http://webwork.yourschool.edu
$server_userID     = "";  # e.g.  www-data    
$server_groupID    = "";  # e.g.  wwdata


# In the apache configuration file (often called httpd.conf) you will find
# User wwadmin   --- this is the $server_userID -- of course it may be wwhttpd or some other name
# Group wwdata   --- this is the $server_groupID -- this will have different names also

# Root directory of PG.
$pg_dir              = "/opt/webwork/pg";

# URL and path to htdocs directory.
# Uncomment the second line below when using litetpd
$webwork_htdocs_url  = "/webwork2_files";
$webwork_htdocs_dir  = "$webwork_dir/htdocs";

# URL and path to courses directory.
$webwork_courses_url = "/webwork2_course_files";
$webwork_courses_dir = "/opt/webwork/courses"; #(a typical place to put the course directory

################################################################################
# Paths to external programs 
################################################################################

# system utilities
$externalPrograms{mv}    = "/bin/mv";
$externalPrograms{cp}    = "/bin/cp";
$externalPrograms{rm}    = "/bin/rm";
$externalPrograms{mkdir} = "/bin/mkdir";
$externalPrograms{tar}   = "/bin/tar";
$externalPrograms{gzip}  = "/bin/gzip";

# equation rendering/hardcopy utiltiies
$externalPrograms{latex}    = "/usr/bin/latex";
$externalPrograms{pdflatex} = "/usr/bin/pdflatex --shell-escape";
$externalPrograms{dvipng}   = "/usr/bin/dvipng";
$externalPrograms{tth}      = "/usr/bin/tth";

####################################################
# NetPBM - basic image manipulation utilities
# Most sites only need to configure $netpbm_prefix.
####################################################
my $netpbm_prefix = "/usr/bin";
$externalPrograms{giftopnm} = "$netpbm_prefix/giftopnm";
$externalPrograms{ppmtopgm} = "$netpbm_prefix/ppmtopgm";
$externalPrograms{pnmtops}  = "$netpbm_prefix/pnmtops";
$externalPrograms{pnmtopng} = "$netpbm_prefix/pnmtopng";
$externalPrograms{pngtopnm} = "$netpbm_prefix/pngtopnm";

# url checker
$externalPrograms{checkurl} = "/usr/bin/lwp-request -d -mHEAD "; # or "/usr/local/bin/w3c -head "

# image conversions utiltiies
# the source file is given on stdin, and the output expected on stdout.
$externalPrograms{gif2eps} = "$externalPrograms{giftopnm} | $externalPrograms{ppmtopgm} | $externalPrograms{pnmtops} -noturn 2>/dev/null";
$externalPrograms{png2eps} = "$externalPrograms{pngtopnm} | $externalPrograms{ppmtopgm} | $externalPrograms{pnmtops} -noturn 2>/dev/null";
$externalPrograms{gif2png} = "$externalPrograms{giftopnm} | $externalPrograms{pnmtopng}";

# mysql clients
$externalPrograms{mysql}     = "/usr/bin/mysql";
$externalPrograms{mysqldump} = "/usr/bin/mysqldump";

################################################################################
# Mail settings
################################################################################

# Mail sent by the PG system and the mail merge and feedback modules will be
# sent via this SMTP server.
$mail{smtpServer}            = 'mail.yourschool.edu';

# When connecting to the above server, WeBWorK will send this address in the
# MAIL FROM command. This has nothing to do with the "From" address on the mail
# message. It can really be anything, but some mail servers require it contain
# a valid mail domain, or at least be well-formed.
$mail{smtpSender}            = 'webwork@yourserver.yourschool.edu';

# Seconds to wait before timing out when connecting to the SMTP server.
$mail{smtpTimeout}           = 30;

# AllowedRecipients defines addresses that the PG system is allowed to send mail
# to. this prevents subtle PG exploits. This should be set in course.conf to the
# addresses of professors of each course. Sending mail from the PG system (i.e.
# questionaires, essay questions) will fail if this is not set somewhere (either
# here or in course.conf).
$mail{allowedRecipients}     = [
	#'prof1@yourserver.yourdomain.edu',
	#'prof2@yourserver.yourdomain.edu',
];

# By default, feeback is sent to all users who have permission to
# receive_feedback. If this list is non-empty, feedback is also sent to the
# addresses specified here.
# 
# * If you want to disable feedback altogether, leave this empty and set
#   submit_feeback => $nobody in %permissionLevels below. This will cause the
#   feedback button to go away as well.
# 
# * If you want to send email ONLY to addresses in this list, set
#   receive_feedback => $nobody in %permissionLevels below.
# 
# It's often useful to set this in the course.conf to change the behavior of
# feedback for a specific course.
# 
# Items in this list may be bare addresses, or RFC822 mailboxes, like:
#   'Joe User <joe.user@example.com>'
# The advantage of this form is that the resulting email will include the name
# of the recipient in the "To" field of the email.
# 
$mail{feedbackRecipients}    = [
	#'prof1@yourserver.yourdomain.edu',
	#'prof2@yourserver.yourdomain.edu',
];

# Feedback subject line -- the following escape sequences are recognized:
# 
#   %c = course ID
#   %u = user ID
#   %s = set ID
#   %p = problem ID
#   %x = section
#   %r = recitation
#   %% = literal percent sign
# 

$mail{feedbackSubjectFormat} = "[WWfeedback] course:%c user:%u set:%s prob:%p sec:%x rec:%r";

# feedbackVerbosity:
#  0: send only the feedback comment and context link
#  1: as in 0, plus user, set, problem, and PG data
#  2: as in 1, plus the problem environment (debugging data)
$mail{feedbackVerbosity}     = 1;

# Defines the size of the Mail Merge editor window
# FIXME: should this be here? it's UI, not mail
# FIXME: replace this with the auto-size method that TWiki uses
$mail{editor_window_rows}    = 15;
$mail{editor_window_columns} = 100;

###################################################
# Customizing the action of the "Email your instructor" button
###################################################

# Use this to customize the text of the feedback button.
$feedback_button_name = "Email instructor";

# If this value is true, feedback will only be sent to users with the same
# section as the user initiating the feedback.
$feedback_by_section = 0;

# If the variable below is set to a non-empty value (i.e. in course.conf), WeBWorK's usual
# email feedback mechanism  will be replaced with a link to the given URL.
# See also $feedback_button_name, above.

$courseURLs{feedbackURL} = "";

# If the variable below is set to a non-empty value (i.e. in course.conf), 
# WeBWorK's usual email feedback mechanism  will be replaced with a link to the given URL and
# a POST request with information about the problem including the HTML rendering
# of the problem will be sent to that URL.
# See also $feedback_button_name, above.

#$courseURLs{feedbackFormURL} = "http://www.mathnerds.com/MathNerds/mmn/SDS/askQuestion.aspx";  #"http://www.tipjar.com/cgi-bin/test";
$courseURLs{feedbackFormURL} = "";

################################################################################
# Theme
################################################################################

$defaultTheme = "math2";
$defaultThemeTemplate = "system";

################################################################################
# Language
################################################################################

$language = "en";   # tr = turkish,  en=english

################################################################################
# System-wide locations (directories and URLs)
################################################################################

# The root directory, set by webwork_root variable in Apache configuration.
$webworkDirs{root}          = "$webwork_dir";

# Location of system-wide data files.
$webworkDirs{DATA}          = "$webworkDirs{root}/DATA";

# Used for temporary storage of uploaded files.
$webworkDirs{uploadCache}   = "$webworkDirs{DATA}/uploads";

# Location of utility programs.
$webworkDirs{bin}           = "$webworkDirs{root}/bin";

# Location of configuration files, templates, snippets, etc.
$webworkDirs{conf}          = "$webworkDirs{root}/conf";

# Location of theme templates.
$webworkDirs{templates}     = "$webworkDirs{conf}/templates";

# Location of course directories.
$webworkDirs{courses}       = "$webwork_courses_dir" || "$webworkDirs{root}/courses";

# Contains log files.
$webworkDirs{logs}          = "$webworkDirs{root}/logs";

# Contains non-web-accessible temporary files, such as TeX working directories.
$webworkDirs{tmp}           = "$webworkDirs{root}/tmp";

# The (absolute) destinations of symbolic links that are OK for the FileManager to follow.
#   (any subdirectory of these is a valid target for a symbolic link.)
# For example:
#    $webworkDirs{valid_symlinks} = ["$webworkDirs{courses}/modelCourse/templates","/ww2/common/sets"];
$webworkDirs{valid_symlinks}   = [];

################################################################################
##### The following locations are web-accessible.
################################################################################

# The root URL (usually /webwork2), set by <Location> in Apache configuration.
$webworkURLs{root}          = "$webwork_url";

# Location of system-wide web-accessible files, such as equation images, and
# help files.
$webworkDirs{htdocs}        = "$webwork_htdocs_dir" || "$webworkDirs{root}/htdocs";
$webworkURLs{htdocs}        = "$webwork_htdocs_url";

# Location of web-accessible temporary files, such as equation images.
$webworkDirs{htdocs_temp}   = "$webworkDirs{htdocs}/tmp";
$webworkURLs{htdocs_temp}   = "$webworkURLs{htdocs}/tmp";

# Location of cached equation images.
$webworkDirs{equationCache} = "$webworkDirs{htdocs_temp}/equations";
$webworkURLs{equationCache} = "$webworkURLs{htdocs_temp}/equations";

# Contains context-sensitive help files.
$webworkDirs{local_help}    = "$webworkDirs{htdocs}/helpFiles";
$webworkURLs{local_help}    = "$webworkURLs{htdocs}/helpFiles";

# URL of general WeBWorK documentation.
$webworkURLs{docs}          = "http://webwork.maa.org";

# URL of WeBWorK Bugzilla database.
$webworkURLs{bugReporter}   = "http://bugs.webwork.maa.org/enter_bug.cgi";

# Location of CSS
# $webworkURLs{stylesheet}    = "$webworkURLs{htdocs}/css/${defaultTheme}.css";
# this is never used -- changing the theme from the config panel
# doesn't appear to reset the theme in time?
# It's better to refer directly to the .css file in the system.template
# <link rel="stylesheet" type="text/css" href="<!--#url type="webwork" name="htdocs"-->/css/math.css"/>

# Location of jsMath script, used for the jsMath display mode.
$webworkURLs{jsMath}        = "$webworkURLs{htdocs}/jsMath/jsMath-ww.js";

# Location of MathJax script, used for the MathJax display mode.
$webworkURLs{MathJax}       = "$webworkURLs{htdocs}/mathjax/MathJax.js?config=TeX-AMS_HTML-full";

# Location of Tabber script, used to generate tabbed widgets.
$webworkURLs{tabber}		= "$webworkURLs{htdocs}/js/tabber.js";

# Location of ASCIIMathML script, used for the asciimath display mode.
$webworkURLs{asciimath}     = "$webworkURLs{htdocs}/ASCIIMathML/ASCIIMathML.js";

# Location of LaTeXMathML script, used for the LaTeXMathML display mode.
$webworkURLs{LaTeXMathML}   = "$webworkURLs{htdocs}/LaTeXMathML/LaTeXMathML.js";

################################################################################
# Defaults for course-specific locations (directories and URLs)
################################################################################

# The root directory of the current course. (The ID of the current course is
# available in $courseName.)
$courseDirs{root}        = "$webworkDirs{courses}/$courseName";

# Location of course-specific data files.
$courseDirs{DATA}        = "$courseDirs{root}/DATA";

# Location of course HTML files, passed to PG.
$courseDirs{html}        = "$courseDirs{root}/html";
$courseURLs{html}        = "$webwork_courses_url/$courseName";

# Location of course image files, passed to PG.
$courseDirs{html_images} = "$courseDirs{html}/images";

# Location of web-accessible, course-specific temporary files, like static and
# dynamically-generated PG graphics.
$courseDirs{html_temp}   = "$courseDirs{html}/tmp";
$courseURLs{html_temp}   = "$courseURLs{html}/tmp";

# Location of course-specific logs, like the transaction log.
$courseDirs{logs}        = "$courseDirs{root}/logs";

# Location of scoring files.
$courseDirs{scoring}     = "$courseDirs{root}/scoring";

# Location of PG templates and set definition files.
$courseDirs{templates}   = "$courseDirs{root}/templates";

# Location of course-specific macro files.
$courseDirs{macros}      = "$courseDirs{templates}/macros";

# Location of mail-merge templates.
$courseDirs{email}       = "$courseDirs{templates}/email";

# Location of temporary editing files.
$courseDirs{tmpEditFileDir}  = "$courseDirs{templates}/tmpEdit";


# mail merge status directory
$courseDirs{mailmerge}   = "$courseDirs{DATA}/mailmerge";

################################################################################
# System-wide files
################################################################################

# Location of this file.
$webworkFiles{environment}                      = "$webworkDirs{conf}/global.conf";

# Flat-file database used to protect against MD5 hash collisions. TeX equations
# are hashed to determine the name of the image file. There is a tiny chance of
# a collision between two TeX strings. This file allows for that. However, this
# is slow, so most people chose not to worry about it. Set this to "" if you
# don't want to use the equation cache file.
$webworkFiles{equationCacheDB}                  = ""; # "$webworkDirs{DATA}/equationcache";

################################################################################
# Hardcopy snippets are used in constructing a TeX file for hardcopy output.
# They should contain TeX code unless otherwise noted.
################################################################################
# The preamble is the first thing in the TeX file.
$webworkFiles{hardcopySnippets}{preamble}       = "$webworkDirs{conf}/snippets/hardcopyPreamble.tex";

# The setHeader preceeds each set in hardcopy output. It is a PG file.
# This is the default file which is used if a specific files is not selected
$webworkFiles{hardcopySnippets}{setHeader}      = "$webworkDirs{conf}/snippets/setHeader.pg";  # hardcopySetHeader.pg",
#$webworkFiles{hardcopySnippets}{setHeader}     = "$courseDirs{templates}/ASimpleHardCopyHeaderFile.pg"; # An alternate default header file

# The problem divider goes between problems.
$webworkFiles{hardcopySnippets}{problemDivider} = "$webworkDirs{conf}/snippets/hardcopyProblemDivider.tex";

# The set footer goes after each set. Is is a PG file.
$webworkFiles{hardcopySnippets}{setFooter}      = "$webworkDirs{conf}/snippets/hardcopySetFooter.pg";

# The set divider goes between sets (in multiset output).
$webworkFiles{hardcopySnippets}{setDivider}     = "$webworkDirs{conf}/snippets/hardcopySetDivider.tex";

# The user divider does between users (in multiuser output).
$webworkFiles{hardcopySnippets}{userDivider}    = "$webworkDirs{conf}/snippets/hardcopyUserDivider.tex";

# The postabmle is the last thing in the TeX file.
$webworkFiles{hardcopySnippets}{postamble}      = "$webworkDirs{conf}/snippets/hardcopyPostamble.tex";

##### Screen snippets are used when displaying problem sets on the screen.

# The set header is displayed on the problem set page. It is a PG file.
# This is the default file which is used if a specific files is not selected
#$webworkFiles{screenSnippets}{setHeader}        = "$webworkDirs{conf}/snippets/setHeader.pg"; # screenSetHeader.pg"
$webworkFiles{screenSnippets}{setHeader}       = "$courseDirs{templates}/ASimpleScreenHeaderFile.pg"; # An alternate default header file

# A PG template for creation of new problems.
$webworkFiles{screenSnippets}{blankProblem}    = "$webworkDirs{conf}/snippets/blankProblem2.pg"; # screenSetHeader.pg"

# A site info  "message of the day" file
$webworkFiles{site_info}                       = "$webworkDirs{htdocs}/site_info.txt";

################################################################################
# Course-specific files
################################################################################

# The course configuration file.
$courseFiles{environment} = "$courseDirs{root}/course.conf";

# The course simple configuration file (holds web-based configuratoin).
$courseFiles{simpleConfig} = "$courseDirs{root}/simple.conf";

# File contents are displayed after login, on the problem sets page. Path given
# here is relative to the templates directory.
$courseFiles{course_info} = "course_info.txt";

# File contents are displayed on the login page. Path given here is relative to
# the templates directory.
$courseFiles{login_info}  = "login_info.txt";

# Additional library buttons can be added to the Library Browser (SetMaker.pm)
# by adding the libraries you want to the following line.  For each key=>value
# in the list, if a directory (or link to a directory) with name 'key' appears
# in the templates directory, then a button with name 'value' will be placed at
# the top of the problem browser.  (No button will appear if there is no
# directory or link with the given name in the templates directory.)  For
# example,
# 
#     $courseFiles{problibs} = {rochester => "Rochester", asu => "ASU"};
# 
# would add two buttons, one for the Rochester library and one for the ASU
# library, provided templates/rochester and templates/asu exists either as 
# subdirectories or links to other directories. The "NPL Directory" button
# activated below gives access to all the directories in the National 
# Problem Library.
# 
$courseFiles{problibs}    = {
	Library          => "NPL Directory",
# 	rochesterLibrary => "Rochester",
# 	unionLibrary     =>"Union",
# 	asuLibrary       => "Arizona State",
# 	dcdsLibrary      => "Detroit CDS",
# 	dartmouthLibrary => "Dartmouth",
# 	indianaLibrary   => "Indiana",
# 	osuLibrary       => "Ohio State",	
#   capaLibrary      => "CAPA",
};

################################################################################
# Status system
################################################################################

# This is the default status given to new students and students with invalid
# or missing statuses.
$default_status = "Enrolled";

# The first abbreviation in the abbreviations list is the canonical
# abbreviation, and will be used when setting the status value in a user record
# or an exported classlist file.
# 
# Results are undefined if more than one status has the same abbreviation.
# 
# The four behaviors that are controlled by status are:
#   allow_course_access   => is this user allowed to log in?
#   include_in_assignment => is this user included when assigning as set to "all" users?
#   include_in_stats      => is this user included in statistical reports?
#   include_in_email      => is this user included in emails sent to the class?
#   include_in_scoring    => is this user included in score reports?

%statuses = (
	Enrolled => {
		abbrevs => [qw/ C c current enrolled /],
		behaviors => [qw/ allow_course_access include_in_assignment include_in_stats include_in_email include_in_scoring /],
	},
	Audit => {
		abbrevs => [qw/ A a audit /],
		behaviors => [qw/ allow_course_access include_in_assignment include_in_stats include_in_email /],
	},
	Drop => {
		abbrevs => [qw/ D d drop withdraw /],
		behaviors => [qw/  /],
	},
	Proctor => { 
		abbrevs => [qw/ P p proctor /],
		behaviors => [qw/  /],
	},
);

################################################################################
# Database options
################################################################################

# these variables are used by database.conf. we define them here so that editing
# database.conf isn't necessary.

# required permissions
# GRANT SELECT ON webwork.* TO webworkRead@localhost IDENTIFIED BY 'passwordRO';
# GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, LOCK TABLES ON webwork.* TO webworkWrite@localhost IDENTIFIED BY 'passwordRW';

$database_dsn = "dbi:mysql:webwork";
$database_username = "webworkWrite";
$database_password = "";
$database_debug = 0;

# Variables for sql_moodle database layout.
$moodle_dsn = "dbi:mysql:moodle";
$moodle_username = $database_username;
$moodle_password = $database_password;
$moodle_table_prefix = "mdl_";
$moodle17 = 0;

# Several database are defined in the file conf/database.conf and stored in the
# hash %dbLayouts.
#include "conf/database.conf";

# Select the default database layout. This can be overridden in the course.conf
# file of a particular course. The only database layout supported in WW 2.1.4
# and up is "sql_single".
$dbLayoutName = "sql_single";

# This sets the symbol "dbLayout" as an alias for the selected database layout.
*dbLayout     = $dbLayouts{$dbLayoutName};

################################################################################
# Problem library options
################################################################################

# For configuration instructions, see:
# http://webwork.maa.org/wiki/National_Problem_Library
# The directory containing the natinal problem library files. Set to "" if no problem
# library is installed.
$problemLibrary{root}        = "";

# Problem Library version
# Version 1 is in use.  Version 2 will be released soon.
$problemLibrary{version} = "2";

# Problem Library SQL database connection information
$problemLibrary_db = {
        dbsource => $database_dsn,
        user     => $database_username,
        passwd   => $database_password,
};

################################################################################
# Logs
################################################################################

# FIXME: take logs out of %webworkFiles/%courseFiles and give them their own
# top-level hash.

# Logs data about how long it takes to process problems. (Do not confuse this
# with the /other/ timing log which can be set by WeBWorK::Timing and is used
# for benchmarking system performance in general. At some point, this timing
# mechanism will be deprecated in favor of the WeBWorK::Timing mechanism.)
$webworkFiles{logs}{timing}         = "$webworkDirs{logs}/timing.log";

# Logs courses created via the web-based Course Administration module.
$webworkFiles{logs}{hosted_courses} = "$webworkDirs{logs}/hosted_courses.log";

# The transaction log contains data from each recorded answer submission. This
# is useful if the database becomes corrupted.
$webworkFiles{logs}{transaction}    = "$webworkDirs{logs}/${courseName}_transaction.log";

# The answer log stores a history of all users' submitted answers.
$courseFiles{logs}{answer_log}      = "$courseDirs{logs}/answer_log";

# Log logins.
$courseFiles{logs}{login_log}       = "$courseDirs{logs}/login.log";

# Log for almost every click.  By default it is the empty string, which
# turns this log off.  If you want it turned on, we suggest
#                "$courseDirs{logs}/activity.log"
# When turned on, this log can get quite large.
$courseFiles{logs}{activity_log} = '';

################################################################################
# Site defaults (FIXME: what other things could be "site defaults"?)
################################################################################

# Set the default timezone of courses on this server. To get a list of valid
# timezones, run:
# 
#     perl -MDateTime::TimeZone -e 'print join "\n", DateTime::TimeZone::all_names'
# 
# To get a list of valid timezone "links" (deprecated names), run:
# 
#     perl -MDateTime::TimeZone -e 'print join "\n", DateTime::TimeZone::links'
# 
# If left blank, the system timezone will be used. This is usually what you
# want. You might want to set this if your server is NOT in the same timezone as
# your school. If just a few courses are in a different timezone, set this in
# course.conf for the affected courses instead.
# 
$siteDefaults{timezone} = "America/New_York";

# The default_templates_course is used by default to create a new course.
# The contents of the templates directory are copied from this course
# to the new course being created.
$siteDefaults{default_templates_course} ="modelCourse";

################################################################################
# Authentication system
################################################################################

# FIXME This mechanism is a little awkward and probably should be merged with
# the dblayout selection system somehow.

# Select the authentication module to use for normal logins.
# 
# If this value is a string, the given authentication module will be used
# regardless of the database layout. If it is a hash, the database layout name
# will be looked up in the hash and the resulting value will be used as the
# authentication module. The special hash key "*" is used if no entry for the
# current database layout is found.
# 
$authen{user_module} = {
	sql_moodle => "WeBWorK::Authen::Moodle",
	# sql_ldap   => "WeBWorK::Authen::LDAP",
	"*" => "WeBWorK::Authen",
};

# Select the authentication module to use for proctor logins.
# 
# A string or a hash is accepted, as above.
# 
$authen{proctor_module} = "WeBWorK::Authen::Proctor";

# Options for particular authentication modules

# $authen{moodle_options} = {
# 	dsn => $moodle_dsn,
# 	username => $moodle_username,
# 	password => $moodle_password,
# 	table_prefix => $moodle_table_prefix,
# 	moodle17 => $moodle17,
# };

$authen{ldap_options} = {
	# hosts to attempt to connect to, in order. For example:
	#   auth.myschool.edu             -- uses LDAP scheme and port 389
	#   ldap://auth.myschool.edu:666  -- non-standard port
	#   ldaps://auth.myschool.edu     -- uses LDAPS scheme and port 636
	#   ldaps://auth.myschool.edu:389 -- SSL on non-SSL port
	#   Edit the host(s) below:
	net_ldap_hosts => [
		"ldaps://auth1.myschool.edu",
		"ldaps://auth2.myschool.edu",
	],
	# connection options
	net_ldap_options => {
		timeout => 30,
		version => 3,
	},
	# base to use when searching for user's DN
	# Edit the data below:
	net_ldap_base => "ou=people,dc=myschool,dc=edu",
	
        # Use a Bind account if set to 1
        bindAccount => 0,

        searchDN => "cn=search,DC=youredu,DC=edu",
        bindPassword =>  "password",

	# The LDAP module searches for a DN whose RDN matches the username
	# entered by the user. The net_ldap_rdn setting tells the LDAP
	# backend what part of your LDAP schema you want to use as the RDN.
	# The correct value for net_ldap_rdn will depend on your LDAP setup.
	# 
	# Uncomment this line if you use Active Directory.
	#net_ldap_rdn => "sAMAccountName",
	#
	# Uncomment this line if your schema uses uid as an RDN.
	#net_ldap_rdn => "uid",
	#
	# By default, net_ldap_rdn is set to "sAMAccountName".

	# If failover = "all", then all LDAP failures will be checked
	# against the WeBWorK database. If failover = "local", then only
	# users who don't exist in LDAP will be checked against the WeBWorK
	# database. If failover = 0, then no attempts will be checked
	# against the WeBWorK database. failover = 1 is equivalent to
	# failover = "all".
	failover => "all",
};

################################################################################
# Authorization system
################################################################################

# this section lets you define which groups of users can perform which actions.

# this hash maps a numeric permission level to the name of a role. the number
# assigned to a role is significant -- roles with higher numbers are considered
# "more privileged", and are included when that role is listed for a privilege
# below.
# 
%userRoles = (
	guest => -5,
	student => 0,
	login_proctor => 2,
	grade_proctor => 3,
	ta => 5,
	professor => 10,
);

# this hash maps operations to the roles that are allowed to perform those
# operations. the role listed and any role with a higher permission level (in
# the %userRoles hash) will be allowed to perform the operation. If the role
# is undefined, no users will be allowed to perform the operation.
# 
%permissionLevels = (
	login                          => "guest",
	report_bugs                    => "ta",
	submit_feedback                => "student",
	change_password                => "student",
	change_email_address           => "student",
	
	proctor_quiz_login             => "login_proctor",
	proctor_quiz_grade             => "grade_proctor",
	view_proctored_tests           => "student",
	view_hidden_work               => "ta",
	
	view_multiple_sets             => "ta",
	view_unopened_sets             => "ta",
	view_hidden_sets               => "ta",
	view_answers                   => "ta",
	view_ip_restricted_sets        => "ta",
	
	become_student                 => "professor",
	access_instructor_tools        => "ta",
	score_sets                     => "professor",
	send_mail                      => "professor",
	receive_feedback               => "ta",
	
	create_and_delete_problem_sets => "professor",
	assign_problem_sets            => "professor",
	modify_problem_sets            => "professor",
	modify_student_data            => "professor",
	modify_classlist_files         => "professor",
	modify_set_def_files           => "professor",
	modify_scoring_files           => "professor",
	modify_problem_template_files  => "professor",
	manage_course_files            => "professor",
	
	create_and_delete_courses      => "professor",
	fix_course_databases           => "professor",
	
	##### Behavior of the interactive problem processor #####
	
	show_correct_answers_before_answer_date         => "ta",
	show_solutions_before_answer_date               => "ta",
	avoid_recording_answers                         => "ta",
	# Below this level, old answers are never initially shown
	can_show_old_answers_by_default                 => "student",
	# at this level, we look at showOldAnswers for default value
	# even after the due date
	can_always_use_show_old_answers_default         => "professor",
	check_answers_before_open_date                  => "ta",
	check_answers_after_open_date_with_attempts     => "ta",
	check_answers_after_open_date_without_attempts  => "guest",
	check_answers_after_due_date                    => "guest",
	check_answers_after_answer_date                 => "guest",
	create_new_set_version_when_acting_as_student   => undef,
	print_path_to_problem                           => "professor", # see "Special" PG environment variables
	record_set_version_answers_when_acting_as_student => undef,
	record_answers_when_acting_as_student           => undef,
	# "record_answers_when_acting_as_student" takes precedence
	# over the following for professors acting as students:
	record_answers_before_open_date                 => undef,
	record_answers_after_open_date_with_attempts    => "student",
	record_answers_after_open_date_without_attempts => undef,
	record_answers_after_due_date                   => undef,
	record_answers_after_answer_date                => undef,
	dont_log_past_answers                           => "professor",
	# does the user get to see a dump of the problem?
	view_problem_debugging_info                     => "ta",
	
	##### Behavior of the Hardcopy Processor #####
	
	download_hardcopy_multiuser  => "ta",
	download_hardcopy_multiset   => "ta",
	download_hardcopy_view_errors =>"professor",
	download_hardcopy_format_pdf => "guest",
	download_hardcopy_format_tex => "ta",
);

# This is the default permission level given to new students and students with
# invalid or missing permission levels.
$default_permission_level = $userRoles{student};

################################################################################
# Session options
################################################################################

# $sessionKeyTimeout defines seconds of inactivity before a key expires
$sessionKeyTimeout = 60*30;

# $sessionKeyLength defines the length (in characters) of the session key
$sessionKeyLength = 32;

# @sessionKeyChars lists the legal session key characters
@sessionKeyChars = ('A'..'Z', 'a'..'z', '0'..'9');

# Practice users are users who's names start with $practiceUser
# (you can comment this out to remove practice user support)
$practiceUserPrefix = "practice";

# There is a practice user who can be logged in multiple times.  He's
# commented out by default, though, so you don't hurt yourself.  It is
# kindof a backdoor to the practice user system, since he doesn't have a
# password.  Come to think of it, why do we even have this?!
#$debugPracticeUser = "practice666";

# Option for gateway tests; $gatewayGracePeriod is the time in seconds
# after the official due date during which we'll still grade the test
$gatewayGracePeriod = 120;

################################################################################
# PG subsystem options
################################################################################

# List of enabled display modes. Comment out any modes you don't wish to make
# available for use.
$pg{displayModes} = [
#	"plainText",     # display raw TeX for math expressions
#	"formattedText", # format math expressions using TtH
	"images",        # display math expressions as images generated by dvipng
	"jsMath",        # render TeX math expressions on the client side using jsMath
#	"MathJax",       # render TeX math expressions on the client side using MathJax --- we strongly recommend people install and use MathJax
#	"asciimath",     # render TeX math expressions on the client side using ASCIIMathML
#	"LaTeXMathML",   # render TeX math expressions on the client side using LaTeXMathML
];

#### Default settings for the PG translator

# Default display mode. Should be listed above (uncomment only one).
$pg{options}{displayMode}        = "images";
#$pg{options}{displayMode}        = "jsMath";
#$pg{options}{displayMode}        = "MathJax";

# The default grader to use, if a problem doesn't specify.
$pg{options}{grader}             = "avg_problem_grader";

# Fill in answer blanks with the student's last answer by default?
$pg{options}{showOldAnswers}     = 1;

# Show correct answers (when allowed) by default?
$pg{options}{showCorrectAnswers} = 0;

# Show hints (when allowed) by default?
$pg{options}{showHints}          = 0;

# Show solutions (when allowed) by default?
$pg{options}{showSolutions}      = 0;

# Display the "Entered" column which automatically shows the evaluated student answer, e.g. 1 if student input is sin(pi/2).
# If this is set to 0, e.g. to save space in the response area, the student can still see their evaluated answer by hovering
# the mouse pointer over the typeset version of their answer
$pg{options}{showEvaluatedAnswers}      = 1;

# Catch translation warnings internally by default? (We no longer need to do
# this, since there is a global warnings handler. So this should be off.)
$pg{options}{catchWarnings}      = 0;

# decorations for correct input blanks -- apparently you can't define and name attribute collections in a .css file
$pg{options}{correct_answer} = "{border-width:2;border-style:solid;border-color:#8F8}"; #matches resultsWithOutError class in math2.css

# decorations for incorrect input blanks
$pg{options}{incorrect_answer} = "{border-width:2;border-style:solid;border-color:#F55}"; #matches resultsWithError class in math2.css

##### Currently-selected renderer

# Only the local renderer is supported in this version.
$pg{renderer} = "WeBWorK::PG::Local";

# The remote renderer connects to an XML-RPC PG rendering server.
#$pg{renderer} = "WeBWorK::PG::Remote";

##### Renderer-dependent options

# The remote renderer has one option:
$pg{renderers}{"WeBWorK::PG::Remote"} = {
	# The "proxy" server to connect to for remote rendering.
	proxy => "http://localhost:21000/RenderD",
};

##### Settings for various display modes

# "images" mode has several settings:
$pg{displayModeOptions}{images} = {
	# Determines the method used to align images in output. Can be
	# "baseline", "absmiddle", or "mysql".
	dvipng_align => 'mysql', 

	# If mysql is chosen, this information indicates which database contains the
	# 'depths' table. Since 2.3.0, the depths table is kept in the main webwork
	# database. (If you are upgrading from an earlier version of webwork, and
	# used the mysql method in the past, you should move your existing 'depths'
	# table to the main database.)
	dvipng_depth_db => {
		dbsource => $database_dsn,
		user     => $database_username,
		passwd   => $database_password,
	},
};

$pg{displayModeOptions}{jsMath} = {
	reportMissingFonts => 0,       # set to 1 to allow the missing font message
	missingFontMessage => undef,   # set to an HTML string to replace the missing font message
	noImageFonts => 0,             # set to 1 if you didn't install the jsMath image fonts
	processDoubleClicks => 1,      # set to 0 to disable double-click on math to get TeX source
};

##### Directories used by PG

# The root of the PG directory tree (from pg_root in Apache config).
$pg{directories}{root}   = "$pg_dir";
$pg{directories}{lib}    = "$pg{directories}{root}/lib";
$pg{directories}{macros} = "$pg{directories}{root}/macros";

#
#  The macro file search path.  Each directory in this list is seached
#  (in this order) by loadMacros() when it looks for a .pl file.
#
$pg{directories}{macrosPath} = [
   ".",                     # search the problem file's directory
   $courseDirs{macros},
   $pg{directories}{macros},
   "$courseDirs{templates}/Library/macros/Union",
   "$courseDirs{templates}/Library/macros/Michigan",
   "$courseDirs{templates}/Library/macros/CollegeOfIdaho",
   "$courseDirs{templates}/Library/macros/FortLewis",
   "$courseDirs{templates}/Library/macros/TCNJ",
   "$courseDirs{templates}/Library/macros/NAU",
   "$courseDirs{templates}/Library/macros/Dartmouth",
];

# The applet search path. If a full URL is given, it is used unmodified. If an
# absolute path is given, the URL of the local server is prepended to it.
# 
# For example, if an item is "/math/applets",
# and the local server is  "https://math.yourschool.edu",
# then the URL "https://math.yourschool.edu/math/applets" will be used.
# 

$pg{directories}{appletPath} = [    # paths to search for applets (requires full url)
	"$webworkURLs{htdocs}/applets",
	"$webworkURLs{htdocs}/applets/geogebra_stable",
	"$courseURLs{html}/applets",  
	"$webworkURLs{htdocs}/applets/Xgraph",
	"$webworkURLs{htdocs}/applets/PointGraph",
	"$webworkURLs{htdocs}/applets/Xgraph",
	"$webworkURLs{htdocs}/applets/liveJar",
	"$webworkURLs{htdocs}/applets/Image_and_Cursor_All",
	
];

##### "Special" PG environment variables. (Stuff that doesn't fit in anywhere else.)

# Users for whom to print the file name of the PG file being processed.
$pg{specialPGEnvironmentVars}{PRINT_FILE_NAMES_FOR} = [ "professor", ];  
   # ie file paths are printed for 'gage'
$pg{specialPGEnvironmentVars}{PRINT_FILE_NAMES_PERMISSION_LEVEL} = $userRoles{ $permissionLevels{print_path_to_problem} }; 
   # (file paths are also printed for anyone with this permission or higher)

# Locations of CAPA resources. (Only necessary if you need to use converted CAPA
# problems.)
$pg{specialPGEnvironmentVars}{CAPA_Tools}             = "/opt/webwork/libraries/CAPA/CAPA_Tools/",
$pg{specialPGEnvironmentVars}{CAPA_MCTools}           = "/opt/webwork/libraries/CAPA/CAPA_MCTools/",
$pg{specialPGEnvironmentVars}{CAPA_GraphicsDirectory} = "$webworkDirs{htdocs}/CAPA_Graphics/",
$pg{specialPGEnvironmentVars}{CAPA_Graphics_URL}      = "$webworkURLs{htdocs}/CAPA_Graphics/",

# Size in pixels of dynamically-generated images, i.e. graphs.
$pg{specialPGEnvironmentVars}{onTheFlyImageSize}      = 400,
 
# To disable the Parser-based versions of num_cmp and fun_cmp, and use the
# original versions instead, set this value to 1.
$pg{specialPGEnvironmentVars}{useOldAnswerMacros} = 0;

# Strings to insert at the start and end of the body of a problem
#  (at beginproblem() and ENDDOCUMENT) in various modes.  More display modes
#  can be added if different behaviours are desired (e.g., HTML_dpng,
#  HTML_asciimath, etc.).  These parts are not used in the Library browser.

$pg{specialPGEnvironmentVars}{problemPreamble} = { TeX => '', HTML=> '' };
$pg{specialPGEnvironmentVars}{problemPostamble} = { TeX => '', HTML=>'' };

# To have the problem body indented and boxed, uncomment:

 $pg{specialPGEnvironmentVars}{problemPreamble}{HTML} = '<BLOCKQUOTE>
     <TABLE BORDER=1 CELLSPACING=1 CELLPADDING=15 BGCOLOR=#E8E8E8><TR><TD>'; 
 $pg{specialPGEnvironmentVars}{problemPostamble}{HTML} = '</TD></TR></TABLE>
     </BLOCKQUOTE>';

##### PG modules to load

# The first item of each list is the module to load. The remaining items are
# additional packages to import.

${pg}{modules} = [
	[qw(DynaLoader)],
	[qw(Exporter)],
	[qw(GD)],
	
	[qw(AlgParser AlgParserWithImplicitExpand Expr ExprWithImplicitExpand utf8)],
	[qw(AnswerHash AnswerEvaluator)],
	[qw(WWPlot)], # required by Circle (and others)
	[qw(Circle)],
	[qw(Complex)],
	[qw(Complex1)],
	[qw(Distributions)],
	[qw(Fraction)],
	[qw(Fun)],
	[qw(Hermite)],
	[qw(Inequalities::common)],
	[qw(Label)],
	[qw(LimitedPolynomial)],
	[qw(ChoiceList)],
	[qw(Match)],
	[qw(MatrixReal1)], # required by Matrix
	[qw(Matrix)],
	[qw(Multiple)],
	[qw(PGrandom)],
	[qw(Regression)],
	[qw(Select)],
	[qw(Units)],
	[qw(VectorField)],
	[qw(Parser Value)],
	[qw(Parser::Legacy)],
#	[qw(SaveFile)],
#   [qw(Chromatic)], # for Northern Arizona graph problems 
#                    #  -- follow instructions at libraries/nau_problib/lib/README to install
    [qw(Applet FlashApplet JavaApplet CanvasApplet)],
	[qw(PGcore PGalias PGresource PGloadfiles PGanswergroup PGresponsegroup  Tie::IxHash)],
];

##### Problem creation defaults

# The default weight (also called value) of a problem to use when using the 
# Library Browser, Problem Editor or Hmwk Sets Editor to add problems to a set
# or when this value is left blank in an imported set definition file.
$problemDefaults{value} = 1;  

# The default max_attempts for a problem to use when using the 
# Library Browser, Problem Editor or Hmwk Sets Editor to add problems to a set
# or when this value is left blank in an imported set definition file.  Note that 
# setting this to -1 gives students unlimited attempts.
$problemDefaults{max_attempts} = -1;   

##### Answer evaluatior defaults

$pg{ansEvalDefaults} = {
	functAbsTolDefault            => .001,
	functLLimitDefault            => .0000001,
	functMaxConstantOfIntegration => 1E8,
	functNumOfPoints              => 3,
	functRelPercentTolDefault     => .1,
	functULimitDefault            => .9999999,
	functVarDefault               => "x",
	functZeroLevelDefault         => 1E-14,
	functZeroLevelTolDefault      => 1E-12,
	numAbsTolDefault              => .001,
	numFormatDefault              => "",
	numRelPercentTolDefault       => .1,
	numZeroLevelDefault           => 1E-14,
	numZeroLevelTolDefault        => 1E-12,
	useBaseTenLog                 => 0,
	defaultDisplayMatrixStyle     => "[s]",  # left delimiter, middle line delimiters, right delimiter
	reducedScoringPeriod          => 0,	# Length of Reduced Credit Period (formally Reduced Scoring Period) in minutes
	reducedScoringValue			  => 1,	# A number in [0,1]. Students will be informed of the value as a percentage
};

################################################################################
# Compatibility
################################################################################

# Define the old names for the various "root" variables.
$webworkRoot    = $webworkDirs{root};
$webworkURLRoot = $webworkURLs{root};
$pgRoot         = $pg{directories}{root};
