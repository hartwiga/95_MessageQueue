########################################################################################
#
# F7Messages.pm
#
# FHEM module to handle a message queue for Framework7 web applications
#
# Andreas Hartwig
#
# $Id$
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################

package main;

use strict;
use warnings;

use vars qw(%defs);           	# FHEM device/button definitions
use vars qw($FW_RET);           # Returned data (html)
use vars qw($FW_RETTYPE);       # image/png or the like
use vars qw($FW_wname);         # Web instance

use Data::UUID;
use Time::Local;
use Data::Dumper;

#########################
# Global variables
my $f7messageversion  = "0.13";
my $FW_encoding    = "UTF-8";

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
          'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
          unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

# Message hast template structure
my $MSGHASH_TEMPLATE = {
  recipient => '',
  id => '',
  uuid => '',
  timestamp => '',
  title => '',
  priority => undef,
  text => '',
  parameter => undef,
  read => undef,
};

#########################################################################################
#
# F7Messages_Initialize 
# 
# Parameter hash = hash of device addressed 
#
#########################################################################################

sub F7Messages_Initialize ($) {
  my ($hash) = @_;
  
  my $devname = $hash->{NAME}; 
    
  $hash->{DefFn}       = "F7Messages_Define";
  $hash->{SetFn}       = "F7Messages_Set";  
  $hash->{GetFn}       = "F7Messages_Get";
  $hash->{UndefFn}     = "F7Messages_Undef";  
  $hash->{InitFn}      = "F7Messages_Init";  
  $hash->{AttrFn}      = "F7Messages_Attr";
  $hash->{AttrList}    = "disable:0,1 f7mRecipients ".$readingFnAttributes;   

  $hash->{'.msgParams'} = { parseParams => 1, };
  
  return undef;
}

#########################################################################################
#
# F7Messages_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
#########################################################################################

sub F7Messages_Define ($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my $now = time();
  my $devname = $hash->{NAME}; 
 
  $modules{F7Messages}{defptr}{$a[0]} = $hash;

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash,"state","Initialized");
  readingsEndUpdate($hash,1); 
  InternalTimer(gettimeofday()+2, "F7Messages_Init", $hash,0);

  return undef;
}

#########################################################################################
#
# F7Messages_Undef - Implements Undef function
# 
# Parameter hash = hash of device addressed, def = definition string
#
#########################################################################################

sub F7Messages_Undef ($$) {
  my ($hash,$arg) = @_;
  
  RemoveInternalTimer($hash);
  
  return undef;
}

#########################################################################################
#
# F7Messages_Attr - Implements Attr function
# 
# Parameter hash = hash of device addressed, ???
#
#########################################################################################

sub F7Messages_Attr($$$) {
  my ($cmd, $listname, $attrName, $attrVal) = @_;
  return;  
}

#########################################################################################
#
# F7Messages_Init - Check, if default F7Messages have been defined
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub F7Messages_Init($) {
   my ($hash) = @_;
   my $devname = $hash->{NAME};
   my $now = time();
   my $err = 0; 
   
   #-- current number of messages
   my $cnop = ReadingsVal($devname,"messagesCnt",0);
   
   #-- no write operation if everything is ok
   return undef
     if( $err==0 );

   readingsSingleUpdate($hash,"state","OK",1);
}


#########################################################################################
#
# Parse - message string to hash
#         
#         1591292789@all,FHEM,1,Test mit Titel und Prorität normal
#         TIMESTAMP@RECIPIENT,[TITLE],[PRIORITY],TEXT,[PARAMETER]
#
# Parameter hash = ash of device addressed
#           listname = name of PostMe
#
#########################################################################################

sub messageParse($$) {
  my ($hash, $messagestring) = @_;
  my $name = $hash->{NAME}; 
  
  my ( $a, $h ) = parseParams($messagestring);

  Log3 $name, 3, "F7Message $name: called function messageParse(): $messagestring";

  Log3 $name, 3, "Value a: ".join(" ", @$a);
  Log3 $name, 3, "Value h: ".Dumper $h;

  $messagestring = join(" ", @$a);

  my %msghash_copy = %{$MSGHASH_TEMPLATE};
  my $msghash = \%msghash_copy;

  if($messagestring ne "" && $messagestring =~ m/^\d{10}@/) {
    my @items = split(",", $messagestring);
    my $length = scalar @items;

    my ($t,$r) = $items[0] =~ /^(\d{10})@(\w+)/;

    # TIMESTAMP
    $msghash->{timestamp} = $t;
    # RECIPIENT
    $msghash->{recipient} = $r;

    # ...,TEXT
    if($length == 2) {
      $msghash->{text} = $items[1];
    } 
    elsif($length == 3) {
      # ...,PRIORITY,TEXT
      if(@items[1] =~ m/[0-2]/) {
        $msghash->{priority} = $items[1];
        $msghash->{text} = $items[2];
      }
      # ..,TITLE,TEXT
      else {
        $msghash->{title} = $items[1];
        $msghash->{text} = $items[2];
      }
    }
    elsif($length == 4) {
      # ...,PRIORITY,TEXT,PARAMETER
      if(@items[1] =~ m/[0-2]/) {
        $msghash->{priority} = $items[1];
        $msghash->{text} = $items[2];
        $msghash->{parameter} = $items[3];
      }
      # ...,TITLE,PRIORITY,TEXT
      elsif(@items[2] =~ m/[0-2]/) {
        $msghash->{title} = $items[1];
        $msghash->{priority} = $items[2];
        $msghash->{text} = $items[3];
      }
      # ...,TITLE,TEXT,PARAMETER
      else {
        $msghash->{title} = $items[1];
        $msghash->{text} = $items[2];
        $msghash->{parameter} = $items[3];
      }
    }
    # ...,TITLE,PRIORITY,TEXT,PARAMETER
    # elsif($length == 5) {
    #     $msghash->{title} = $items[1];
    #     $msghash->{priority} = $items[2];
    #     $msghash->{text} = $items[3];
    #     $msghash->{parameter} = $items[4];
    # }


    if(defined($h) && keys %{$h} > 0 ) {
      $msghash->{parameter} = $h;
    }

    my $s = Dumper $msghash;
    Log3 $name,5,"[F7Messages] Message hash dump: $s";

    return $msghash;
  }


  return undef;
}

#########################################################################################
#
# F7Messages_Add - Transform messages to json
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub getMessageAsJson($$$@) {
  my ($hash, $name, $cmd, @args) = @_;
  my ( $a, $h ) = parseParams( join " ", @args );

  my $msgcnt = ReadingsVal($name,"messagesCnt", 0);

  my $msghash_json = undef;

  if( $cmd eq "json" && ($args[0] eq "" || $args[0] eq "all")) {
      my $msgHashArray = {messages => []};

      for( my $loop=$msgcnt; $loop>=1; $loop--){
          my $msgTerm = ReadingsVal($name, sprintf("message%03d", $loop), "");
          my @items = split(",", $msgTerm);

          if($msgTerm ne "" && $items[0] =~ m/\d{10}/) {

            my $msgHash = messageParse($hash, $msgTerm);
            my $msgNo = sprintf("%03d", $loop);
            $msgHash->{id} = $msgNo;

            push(@{$msgHashArray->{messages}}, $msgHash);
          }
      }

      my $JSON = JSON->new->allow_nonref;
      $msghash_json = $JSON->pretty->encode($msgHashArray );
    }
    
    # Get latest messages as json
    elsif( $cmd eq "json" && scalar @args == 2 && $args[0] eq "since" && $args[1] =~ m/\d{10}/) {
      my $since = int($args[1]); 

      my $msgHashArray = {messages => []};

      for( my $loop=$msgcnt; $loop>=1; $loop--){
          my $msgTerm = ReadingsVal($name, sprintf("message%03d", $loop), "");
          my @items = split(",", $msgTerm);

          if($msgTerm ne "" && $items[0] =~ m/\d{10}/ && int($items[0]) > $since) {

            my $msgHash = messageParse($hash, $msgTerm);
            my $msgNo = sprintf("%03d", $loop);
            $msgHash->{id} = $msgNo;

            push(@{$msgHashArray->{messages}}, $msgHash);
          }
      }

      my $JSON = JSON->new->allow_nonref;
      $msghash_json = $JSON->pretty->encode($msgHashArray );

    }
    
    # Get a specific message as json
    elsif( $cmd eq "json" && @args[0] ne "") {
      my $msgHashArray = {messages => []};

      my $msgNo = int(@args[0]); 
      my $msgTerm = ReadingsVal($name, sprintf("message%03d", $msgNo), "");
 
      my $msgHash = messageParse($hash, $msgTerm);

      $msgHash->{id} = sprintf("message%03d", $msgNo);

      push(@{$msgHashArray->{messages}}, $msgHash);

      my $JSON = JSON->new->allow_nonref;
      $msghash_json = $JSON->pretty->encode($msgHashArray );

    }

    return $msghash_json;
}

#########################################################################################
#
# F7Messages_Add - Add a new message
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub F7Messages_Add($$$$) {
    my ( $hash, $cmd, $a, $h ) = @_;
    my $name   = $hash->{NAME};

   Log3 $name, 3, "F7Message $name: called function F7Message_Add()";

   my $timestamp = sprintf("%d", time());

   my $messagestring = join(' ', @$a);
   
   if($messagestring =~ m/^@/) {
      if($messagestring =~ m/^@,/) {
        $messagestring =~ s/^@,/\@all/;
      }

      $messagestring = $timestamp.$messagestring;
   }
   else {
      $messagestring =  $timestamp."\@all".",".$messagestring;
   } 

   Log3 $name, 5, "Value h: ".Dumper $h;

   if(defined($h)) {
    my @h = %{$h};

    while( my( $key, $value ) = each( %{$h} ) ) {
         $messagestring .= " ".$key."='".$value."'" if($key ne "");
    }

   }

   #-- current number of messages
   my $messeagecnt = ReadingsVal($name,"messagesCnt",0);
   $messeagecnt++; 

   readingsBeginUpdate($hash);
   readingsBulkUpdate($hash, sprintf("message%03d",$messeagecnt), $messagestring);
   readingsBulkUpdate($hash, "messagesCnt",$messeagecnt);
   readingsEndUpdate($hash,1); 
 
   Log3 $name,3,"[F7Messages] Added a new message: $messagestring";
   
   return undef;
}

#########################################################################################
#
# F7Messages_Delete - Delete an existing message
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub F7Messages_Delete($$) {
   my ($hash,$messagestring) = @_;
   my $devname = $hash->{NAME}; 

   return undef;
 }

#########################################################################################
#
# F7Messages_Delete - Delete an existing message
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub F7Messages_Clear($) {
  my ($hash) = @_;
  my $name = $hash->{NAME}; 

  #Delete all message readings like 'message\d\d\d'
  readingsBeginUpdate($hash);
  for my $reading (grep { /^message\d\d\d/ } keys %{$hash->{READINGS}}) {
   readingsBulkUpdate($hash, $reading, undef);
   readingsDelete($hash, $reading);
   Log3 $name, 5, "[F7Messages] Deleted reading $reading";
  }

  #Reset message counter to 0
  readingsBulkUpdate($hash, "messagesCnt", 0, 1);

  readingsEndUpdate($hash, 1);
}


#########################################################################################
#
# PostMe_Set - Implements the Set function
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub F7Messages_Set($$$@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  my ( $a, $h ) = parseParams( join " ", @args);

  Log3 $name, 3, "F7Message $name: called function F7Message_Set()";

  Log3 $name, 5, "Value args: ".join("|",@args);
  Log3 $name, 5, "Value a: ".join(" ",@$a);
  Log3 $name, 5, "Value h: ".Dumper $h;

  unless ( $cmd =~ /^(add|delete|clear)$/i ) {
    my $usage = "Unknown command $cmd, choose one of add delete clear:noArg";

    return $usage;
  }
  
  return "Unable to add message: Device is disabled"
      if ( IsDisabled($name) );

  return F7Messages_Add($hash, $cmd, $a, $h)
      if ( $cmd eq 'add' );

  return F7Messages_Clear( $hash )
      if ( $cmd eq 'clear' );

}

#########################################################################################
#
# PostMe_Get - Implements the Get function
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub F7Messages_Get($$$@) {
  my ($hash, $name, $cmd, @args) = @_;
  my ( $a, $h ) = parseParams( join " ", @args );

  Log3 $name, 3, "F7Message $name: called function F7Message_Get()";

  Log3 $name, 5, "Value a: ".join(" ",@$a);
  Log3 $name, 5, "Value h: ".Dumper $h;

  my $pmn;
  my $res = "";
  

  unless ( $cmd =~ /^(json|all|jsontest|dump|upgrade|version)$/i ) {
    my $usage = "Unknown command $cmd, choose one of version:noArg json all:noArg jsontest dump upgrade";

    return $usage;
  }

  my $msgcnt = ReadingsVal($name,"messagesCnt", 0);
  
  # Module version
  return "F7Messages.version => $f7messageversion" 
    if ($cmd eq "version");
  
  # json transform
  return getMessageAsJson($hash, $name, $cmd, @args)
    if ( $cmd eq 'json' );

 

    # Get a list of all messages
    if ($cmd eq "all") {
    	for( my $loop=1; $loop<=$msgcnt; $loop++){
    		$res .= sprintf("%03d", $loop).": ";
    	  	$res .= ReadingsVal($name, sprintf("message%03d", $loop), "");
   		   	$res .= "\n";
  		 }
    	return $res;
  	} 
   
    # Hash dump of a specific message
    elsif ($cmd eq "dump" && $args[0] ne "") {
      my $uuid = Data::UUID->new();

      my $msgno = int(@args[0]); 
      my $term = ReadingsVal($name, sprintf("message%03d", $msgno), "");

      my $msghash = messageParse($hash, $term);

      $msghash->{id} = sprintf("%03d", $msgno);
      $msghash->{uuid} = $uuid->create_str();

      return Dumper $msghash;
    }
    
    # Optional upgrade function
    elsif ($cmd eq "upgrade") {
      # readingsBeginUpdate($hash);

      # for my $reading (grep { m/^message\d\d\d/ } keys %{$hash->{READINGS}}) {
      #   Log3 $name, 3, "[F7Messages] Upgrade reading: $reading";
      #   my $val = ReadingsVal($name, $reading, undef);
      #   if($val ne "" && $val =~ m/^\d{10}/ && $val !~ m/^\d{10}@/) {

      #     Log3 $name, 3, "[F7Messages] Upgrade value before: $val";   
      #     my $t = substr($val,0,10);

      #     Log3 $name, 3, "[F7Messages] Upgrade term step 1: $t"; 
      #     $t .= "\@all";

      #     Log3 $name, 3, "[F7Messages] Upgrade term step 2: $t"; 

      #     $val =~ s/^\d{10}/$t/;

      #     readingsBulkUpdate($hash, $reading, $val);

      #     Log3 $name, 3, "[F7Messages] Upgrade $reading content to: $val";
      #   }
      # }

      # readingsEndUpdate($hash, 1);

      return "done";
    }
    
    # For testing only
    elsif ($cmd eq "jsontest" && $args[0] ne "") {
      my $uuid = Data::UUID->new();

      my $msgno = int($args[0]); 
      my $term = ReadingsVal($name, sprintf("message%03d", $msgno), "");

      my $m = {messages => []};
      my $msghash = messageParse($hash, $term);

      $msghash->{id} = sprintf("%03d", $msgno);
      $msghash->{uuid} = $uuid->create_str();

      push(@{$m->{messages}}, $msghash);

      ##my $student_json = encode_json \%student;
      my $JSON = JSON->new->utf8;
      $JSON->pretty(1);
      $JSON->convert_blessed(1);

      my $msghash_json = $JSON->encode($m);
      ##my $msghash_json = eval { encode_json($msghash) };
      return $msghash_json;
  }
}
1;

=pod
=item helper
=item summary to set up a system of sticky notes, similar to Post-Its&trade;
=item summary_DE zur Definition eines Systems von Klebezetteln ähnlich des Post-Its&trade;
=begin html

<a name="F7Messages"></a>
<h3>F7Messages</h3>
=end html
=begin html_DE

<a name="F7Messages"></a>
<h3>F7Messages</h3>
=end html_DE
=cut
