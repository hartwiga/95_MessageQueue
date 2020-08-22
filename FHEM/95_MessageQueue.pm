########################################################################################
#
# MessageQueue.pm
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

use vars qw(%defs);             # FHEM device/button definitions
use vars qw($FW_RET);           # Returned data (html)
use vars qw($FW_RETTYPE);       # image/png or the like
use vars qw($FW_wname);         # Web instance

use Data::UUID;
use Time::Local;
use Data::Dumper;

#########################
# Global variables
my $mqVersion  = "1.0";
my $MQ_SizeLimit = 10000;
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
# MessageQueue_Initialize
# 
# Parameter hash = hash of device addressed 
#
#########################################################################################

sub MessageQueue_Initialize ($) {
  my ($hash) = @_;
  my $name = $hash->{NAME}; 
  
  Log3 undef, 3, "MessageQueue: called function MessageQueue_Initialize()";

  $hash->{DefFn}       = "MessageQueue_Define";
  $hash->{SetFn}       = "MessageQueue_Set";  
  $hash->{GetFn}       = "MessageQueue_Get";
  $hash->{UndefFn}     = "MessageQueue_Undef";  
  $hash->{InitFn}      = "MessageQueue_Init";  
  $hash->{AttrFn}      = "MessageQueue_Attr";
  $hash->{AttrList}    = "MQ_recipients MQ_Mode:single,multi MQ_broadcastMessages:no,yes MQ_MaxSize MQ_MaxLifetime ".$readingFnAttributes;   

  $hash->{FW_detailFn}  = "MessageQueue_detailFn";

  $hash->{'.msgParams'} = { parseParams => 1, };
  
  #InternalTimer(gettimeofday()+2, "MessageQueue_Init", $hash, 0);

  return undef;
}


#########################################################################################
#
# MessageQueue_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
#########################################################################################

sub MessageQueue_Define ($$) {
  my ($hash, $def) = @_;
  my $name = $hash->{NAME}; 
  my @a = split("[ \t][ \t]*", $def);
  my $now = time();

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Define()";
 
  $modules{MessageQueue}{defptr}{$a[0]} = $hash;

  $hash->{fhem} = {messages => []} if( !defined($hash->{fhem}{messages}) );

  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "state", "INIT");
  readingsEndUpdate($hash, 1);

  InternalTimer(gettimeofday()+2, "MessageQueue_Init", $hash, 0);

  return undef;
}

#########################################################################################
#
# MessageQueue_Undef - Implements Undef function
# 
# Parameter hash = hash of device addressed, def = definition string
#
#########################################################################################

sub MessageQueue_Undef ($$) {
  my ($hash,$arg) = @_;
  my $name = $hash->{NAME}; 

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Undef()";

  delete $hash->{fhem}{messages};

  RemoveInternalTimer($hash);
  
  return undef;
}

#########################################################################################
#
# MessageQueue_Init - 
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub MessageQueue_Init($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $now = time();
  my $err = 0; 
  
  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Init()";   

  my $statefile = getStatefileName($hash);
  Log3 $name, 3, "MessageQueue $name: Load module state file '".$statefile."'";
  loadMessageHashFromStateFile($hash);
  
  #-- moduleversion
  $hash->{VERSION} = $mqVersion;

  #-- Last error string
  $hash->{LASTERRMSG} = "nothing";

  #-- Queue size limit
  $hash->{QUEUESIZELIMIT} = $MQ_SizeLimit;

  #-- current number of messages
  #my $msgcnt= keys @{$hash->{fhem}{messages}};
  my $msgcnt = grep { $_->{uuid}} @{$hash->{fhem}{messages}};
  $hash->{MSGCNT} = $msgcnt;
  
  readingsBeginUpdate($hash);
  #-- Update message counter of all recipients   
  my @recipientList = split(" ", AttrVal($name, "MQ_recipients", ""));
  foreach (@recipientList) {
    my $cnt = grep { $_->{recipient} =~ m/^$_/ } @{$hash->{fhem}{messages}};
    readingsBulkUpdate($hash, "recipientMessageCnt_".$_, $cnt);
  }
  readingsEndUpdate($hash, 0);

  #-- set state
  readingsSingleUpdate($hash, "state", "OK", 1);
}

#########################################################################################
#
# MessageQueue_Attr - Implements Attr function
# 
# Parameter hash = hash of device addressed, ???
#
#########################################################################################

sub MessageQueue_Attr($$$) {
  my ($cmd, $listname, $attrName, $attrVal) = @_;

  return;  
}

#########################################################################################
#
# errorHandler - Error errorHandler
#
# Parameter hash = hash of device addressed 
#            str = Error text
#
#########################################################################################
sub errorHandler($$) {
  my ($hash, $str) = @_;
  my $name = $hash->{NAME}; 

  readingsSingleUpdate($hash, "state", "ERR", 1);
  $hash->{LASTERRMSG} = $str;
  Log3 $name,1,"MessageQueue $name: ".$str;
}

#########################################################################################
#
# getStatefileName - Get state file name 
# 
# Parameter hash = hash of device addressed 
#
#########################################################################################
sub getStatefileName($) { 
  my ($hash) = @_;
  my $name = $hash->{NAME};  

  my $statefile = $attr{global}{statefile};
  $statefile = substr($statefile, 0, rindex($statefile,'/') + 1);
  
  return $statefile ."MessageQueue.".$name.".save";
}

#########################################################################################
#
# saveMessageHashtoStateFile - Save message hash to state file
# 
# Parameter hash = hash of device addressed 
#
#########################################################################################
sub saveMessageHashToStateFile($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};  

  Log3 $name, 4, "MessageQueue $name: called function saveMessageHashToStateFile()";

  if(!$attr{global}{statefile}) {
    my $msg = "No statefile not specified on global device";
    Log3 $name, 1, "MessageQueue $name: ".$msg;
    return  $msg;
  }
  my $statefile = getStatefileName($hash);

  if(open(FH, ">$statefile")) {
    print FH Dumper $hash->{fhem}{messages};
    close(FH);
  } 
  else {
    my $msg = "Cannot open $statefile '".$statefile."'";
    Log3 $name, 1, "MessageQueue $name: ".$msg;
  }

  return undef;
}

#########################################################################################
#
# loadMessageHashFromStateFile - Load message hash from state file
# 
# Parameter hash = hash of device addressed 
#
#########################################################################################
sub loadMessageHashFromStateFile($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "MessageQueue $name: called function loadMessageHashFromStateFile()";

  if(!$attr{global}{statefile}) {
    my $msg = "No statefile not specified on global device";
    Log3 $name, 1, "MessageQueue $name: ".$msg;
    return  $msg;
  }
  my $statefile = getStatefileName($hash);

  if(open(FH, "<$statefile")) {
    my $encoded;
    while (my $line = <FH>) {
      chomp $line;
      next if($line =~ m/^#.*$/);
      $encoded .= $line;
    }
    close(FH);

    return if( !defined($encoded) );

    my $decoded = eval $encoded;
    $hash->{fhem}{messages} = $decoded if(defined($decoded));

  } 
  else {
    my $msg = "readingsHistory_Load: Cannot open $statefile: $!";
    Log3 undef, 1, $msg;
  }
  return undef;
}

#########################################################################################
#
# checkMessageQueue - Check and limit the message queue by lifetime and number of messages
# 
# Parameter hash = hash of device addressed 
#           recipient = recipient name
#
#########################################################################################
sub handleMessageQueueSize($$) {
  my ($hash, $recipient) = @_;
  my $name = $hash->{NAME};

  my @a;

  Log3 $name, 4, "MessageQueue $name: called function checkMessageQueueSize()";

  my $lifetime = AttrVal($name, "MQ_MaxLifetime", undef);
  my $maxsize = AttrVal($name, "MQ_MaxSize", undef);
  
  #-- Current numbers of recipient messages in queue
  my $cntBefore = grep { $_->{recipient} =~ m/^$recipient/ } @{$hash->{fhem}{messages}};
  Log3 $name, 3, "MessageQueue $name: Message number of recipient '".$recipient."' before: ".$cntBefore;

  #-- 1. Check liftetime and remove too old ones
  if($lifetime) {

    my $limit = time() - ($lifetime * 84600);
    @a = grep { $_->{recipient} !~  m/^$recipient/ || $_->{timestamp} >= $limit } @{$hash->{fhem}{messages}};

    $hash->{fhem} = {messages => [@a]};
  } 

  #-- 2. Check queue size and remove overlapping ones
  if($maxsize) {    
    my $diff = $cntBefore - $maxsize;

    my $index = 1;
    my @a = grep { $_->{recipient} !~  m/^$recipient/ || ($_->{recipient} =~  m/^$recipient/ && $index++ > $diff) } @{$hash->{fhem}{messages}};

    $hash->{fhem} = {messages => [@a]};
  }

  #-- Calculate removed message items
  my $cntAfter = grep { $_->{recipient} =~ m/^$recipient/ } @{$hash->{fhem}{messages}};
  my $deleted = $cntBefore - $cntAfter;

  Log3 $name, 3, "MessageQueue $name: Message number of recipient '".$recipient."' after: ".$cntAfter." [deleted=".$deleted."]" if($deleted);
  
  if($deleted) {
    #-- Save hash to state file
    saveMessageHashToStateFile($hash);

    #-- Adjust related reading
    readingsSingleUpdate($hash, "recipientMessageCnt_".$recipient, $cntAfter, 1);

    #-- Adjust message counter
    $hash->{MSGCNT} = scalar @{$hash->{fhem}{messages}};
  }

  return $deleted;
}

#########################################################################################
#
# messageParse - message string to hash
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

  Log3 $name, 4, "MessageQueue $name: called function messageParse(): ".$messagestring;

  Log3 $name, 5, "Value a: ".join(" ", @$a);
  Log3 $name, 5, "Value h: ".Dumper $h;

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
      if($items[1] =~ m/[0-2]/) {
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
      if($items[1] =~ m/[0-2]/) {
        $msghash->{priority} = $items[1];
        $msghash->{text} = $items[2];
        $msghash->{parameter} = $items[3];
      }
      # ...,TITLE,PRIORITY,TEXT
      elsif($items[2] =~ m/[0-2]/) {
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
    Log3 $name,5,"MessageQueue Message hash dump: $s";

    return $msghash;
  }


  return undef;
}

#########################################################################################
#
# createMsgHashFromTerm - message string to hash
#         
#         1591292789@all,FHEM,1,Test mit Titel und Prorität normal
#         TIMESTAMP@RECIPIENT,[TITLE],[PRIORITY],TEXT,[PARAMETER]
#
# Parameter term = message string
#
#########################################################################################

sub createMsgHashFromTerm($$) {
  my ($hash, $messagestring) = @_;

  my $msghash = messageParse($hash, $messagestring);

  if(defined($msghash)) {
    my $uuid = Data::UUID->new();
    $msghash->{uuid} = $uuid->create_str();
  }

  return $msghash;
}

#########################################################################################
#
# MessageQueue_Add - Transform messages to json
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub getMessageAsJson($$$@) {
  my ($hash, $name, $cmd, @args) = @_;
  my ( $a, $h ) = parseParams( join " ", @args );

  Log3 $name, 3, "MessageQueue $name: called function getMessageAsJson()";

  my $msghash_json = undef;

  if( $cmd eq "json" && 
        (scalar @args == 0 ||
        (scalar @args == 1 && $args[0] eq "all") ||
        (scalar @args == 2 && $args[1] eq "all"))) {

      my $user = scalar @args == 2 ? $args[0] : "";

      Log3 $name, 4, "Get messages all" if($user eq "");
      Log3 $name, 4, "Get messages all for user: ".$user if($user ne "");

      my $msgHashArray = {messages => []};

      foreach my $msgarray (@{$hash->{fhem}{messages}}) {
        my $recipient = $msgarray->{recipient};
        if($user eq "" || $recipient eq "all" || $user eq $recipient) {          
          push(@{$msgHashArray->{messages}}, $msgarray);
        }
      }

      #my $s = Dumper $msgHashArray;
      #Log3 $name,5,"[MessageQueue] Message hash dump: $s";

      my $JSON = JSON->new->allow_nonref;
      $JSON->canonical(1);
      $msghash_json = $JSON->pretty->encode($msgHashArray);
    }
    
    # Get latest messages as json
    elsif( $cmd eq "json" && 
            ((scalar @args == 2 && $args[0] eq "since" && $args[1] =~ m/\d{10}/) || 
            (scalar @args == 3 && $args[1] eq "since" && $args[2] =~ m/\d{10}/))) {

      my $since = scalar @args == 2 ? int($args[1]) : int($args[2]); 
      my $user = scalar @args == 2 ? "" : $args[0];

      Log3 $name, 4, "Get messages since: ".$since;
      Log3 $name, 4, "Get messages since: ".$since."for user: ".$user if($user ne "");

      my $msgHashArray = {messages => []};

      foreach my $msgarray (@{$hash->{fhem}{messages}}) {
        my $recipient = $msgarray->{recipient};
        my $timestamp = int($msgarray->{timestamp});

        if($timestamp > $since && ($user eq "" || $recipient eq "all" || $user eq $recipient)) {          
          push(@{$msgHashArray->{messages}}, $msgarray);
        }
      }

      my $JSON = JSON->new->allow_nonref;
      $msghash_json = $JSON->pretty->encode($msgHashArray );

    }
    
    # Get a specific message as json
    elsif( $cmd eq "json" && 
        (scalar @args == 2 && $args[0] eq "uuid" && $args[1] =~ m/\S{8}-\S{4}-\S{4}-\S{4}-\S{12}/) ||
        (scalar @args == 3 && $args[1] eq "uuid" && $args[2] =~ m/\S{8}-\S{4}-\S{4}-\S{4}-\S{12}/)) {

      my $msgNo = scalar @args == 2 ? $args[1] : $args[2]; 
      my $user = scalar @args == 3 ? $args[0] : "";

      Log3 $name, 4, "Get messages by message uuid: ".$msgNo if($user eq "");
      Log3 $name, 4, "Get messages by message uuid ".$msgNo." for user: ".$user if($user ne "");

      my $msgHashArray = {messages => []};

      foreach my $msgarray (@{$hash->{fhem}{messages}}) {
        if(exists $msgarray->{uuid}) {
          my $recipient = $msgarray->{recipient};
          my $uuid = $msgarray->{uuid};

          if($uuid eq $msgNo && ($user eq "" || $recipient eq "all" || $user eq $recipient)) {          
            push(@{$msgHashArray->{messages}}, $msgarray);
            last;
          }
        }
      }

      my $JSON = JSON->new->allow_nonref;
      $msghash_json = $JSON->pretty->encode($msgHashArray );
    }

    return $msghash_json;
}


#########################################################################################
#
# MessageQueue_Add - Add a new message
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub MessageQueue_Add($$$@) {
  my ( $hash, $cmd, $a, $h ) = @_;
  my $name   = $hash->{NAME};

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Add()";

  #-- Message string received
  my $rawmessage = join(' ', @$a);

  return "Bitte geben sie eine Nachricht ein" if(!length($rawmessage));

  Log3 $name,3,"MessageQueue $name: Raw message string to handle: ".$rawmessage;

  my $attrBroadcastMessage = AttrVal($name, "MQ_broadcastMessages", "no");
  Log3 $name,3,"MessageQueue $name: Broadcast message allowed: ".$attrBroadcastMessage;  

  my $attrMode = AttrVal($name, "MQ_Mode", "single");
  Log3 $name,3,"MessageQueue $name: Message mode: ".$attrMode; 

  #-- Get list of all allowed recipients    
  my @recipientList = split(" ", AttrVal($name, "MQ_recipients", ""));

  my $timestamp = sprintf("%d", time());
  my $broadcastMessage = "no";
  my @recipients;
  my $messagestring;

  #-- Check on broadcast message 
  #-- TODO_ besser machen

  if($rawmessage  =~ m/^\@all,/) {
    $broadcastMessage = "yes";
    ($messagestring) = $rawmessage =~ /^\@\w+,(.*)$/;
  }
  elsif($rawmessage  =~ m/^\@,/) {
    if($attrMode ne "single") {
      $broadcastMessage = "yes";
    }
    else {
      my $name;
      if(scalar @recipientList) {
        $name = $recipientList[0];
      }
      else {
        $name = "unknown";
      }

      push(@recipients, $name);
      Log3 $name,3,"MessageQueue $name: Message recipient: ".$name;

      $broadcastMessage = "no"
    }
    ($messagestring) = $rawmessage =~ /^\@,(.*)$/;
  }
  elsif($rawmessage =~ m/^@[a-z,A-Z]+,/) {
    my ($name) = $rawmessage =~ /^\@(\w+),.*$/;

    push(@recipients, ($name));
    Log3 $name,3,"MessageQueue $name: Message recipient: ".$name;

    $broadcastMessage = "no";  
    ($messagestring) = $rawmessage =~ /^\@\w+,(.*)$/;
  }
  else {

    if($attrMode ne "single") {
      $broadcastMessage = "yes";
    }
    else {
      my $name;
      if(scalar @recipientList) {
        $name = $recipientList[0];
      }
      else {
        $name = "unknown";
      }

      push(@recipients, $name);
      Log3 $name,3,"MessageQueue $name: Message recipient: ".$name;

      $broadcastMessage = "no"
    }
    $messagestring = $rawmessage;
  } 

  Log3 $name,3,"MessageQueue $name: Message string without recipient: ".$messagestring;


  Log3 $name, 5, "Value h: ".Dumper $h;
  if(defined($h)) {
    my @h = %{$h};

    while( my( $key, $value ) = each( %{$h} ) ) {
      $messagestring .= " ".$key."='".$value."'" if($key ne "");
    }
  }

  Log3 $name,3,"MessageQueue $name: Broadcast message recieved: ".$messagestring if($broadcastMessage eq "yes");

  #-- Messages to all reciepients are allowed only if the related option is enabled
  if($broadcastMessage ne "yes" || ($broadcastMessage eq "yes" && $attrBroadcastMessage eq "yes")) {

    #-- If this is a broadcast message, create the recipient list based on the list of allowed recipients
    if($broadcastMessage eq "yes") {
      foreach (@recipientList) {
        Log3 $name,5,"MessageQueue $name: Recipient allowed: ".$_;
        push(@recipients, $_);
      }
    }

    #-- Handle message string for all recipients
    foreach (@recipients) {
      
      Log3 $name,5,"MessageQueue $name: Recipient: ".$_;
      my $recipient = $_;
      
      #-- Accept message on if message queue max size limit is not reached already
      if($hash->{MSGCNT} <= $MQ_SizeLimit) {
        #-- Check if message recipient is valid
        if($recipient ~~ @recipientList || $recipient eq "unknown") {
          #-- Add timestamp and recipientto messagestring
          my $msg = $timestamp."@".$recipient.",".$messagestring;
           Log3 $name,5,"MessageQueue $name: Message string to handle: ".$msg;

          #-- Handle message for a certain recipient
          my $msgHash = createMsgHashFromTerm($hash, $msg);
          if(defined($msgHash)) {
            push(@{$hash->{fhem}{messages}}, $msgHash);
            saveMessageHashToStateFile($hash);

            #-- current number of messages
            my $msgcnt= keys @{$hash->{fhem}{messages}};
            $hash->{MSGCNT} = $msgcnt;

            readingsBeginUpdate($hash);
            
            readingsBulkUpdate($hash, "lastMessageReceived", $msg);

            if($recipient ne "unknown") {
              my $cnt = int(ReadingsVal($name, "recipientMessageCnt_".$recipient, 0)) + 1;
              readingsBulkUpdate($hash, "recipientMessageCnt_".$recipient, $cnt);
            }
            else {
              my $cnt = int(ReadingsVal($name, "recipientMessageCnt", 0)) + 1;
              readingsBulkUpdate($hash, "recipientMessageCnt", $cnt);
            }
            
            readingsBulkUpdate($hash, "state", "OK");
            $hash->{LASTERRMSG} = "nothing";

            readingsEndUpdate($hash,1); 

            Log3 $name,3,"MessageQueue $name: Added a new message: $msg";

            #-- Check and handle message queue size recipient related
            handleMessageQueueSize($hash, $recipient);
          }
          else {
            my $msg = "Message queue maximum size [$MQ_SizeLimit] reached. Message for recipient $recipient not accepted.";
            errorHandler($hash, $msg);
            return "Error: ".$msg;
          }
        }
        else {
          my $msg = "Message term could not be parsed properly: ".$rawmessage;
          errorHandler($hash, $msg);
          return "Error: ".$msg;
        }
      }
      else {
        my $msg = "Recipient not allowed: $recipient";
        errorHandler($hash, $msg);    
        return "Error: ".$msg;
      }
    }
  }
  else {
    my $msg = "Broascast messages are not allowed. You could set the attribute MQ_broadcastMessages to enable this option";
    errorHandler($hash, $msg);
    return "Error: ".$msg; 
  } 

  return undef;
}

#########################################################################################
#
# deleteMessage - Delete an existing message
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub MessageQueue_Delete($$$@) {
  my ($hash, $name, $cmd, @args) = @_;
  my ( $a, $h ) = parseParams( join " ", @args );

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Delete()";

  my $msghash_json = undef;

  #-- Delete message by uuid of a specific recipient
  if(scalar @args == 3 && $args[1] eq "uuid" && $args[2] =~ m/\S{8}-\S{4}-\S{4}-\S{4}-\S{12}/) {

    my $recipient = $args[0];
    my $uuid = $args[2]; 
    

    Log3 $name, 4, "Delete message with uuid: ".$uuid." for ".$recipient;
  
    my @a = grep { $_->{recipient} !~  m/^$recipient/ || $_->{uuid} !~  m/^$uuid/ } @{$hash->{fhem}{messages}};

    $hash->{fhem} = {messages => [@a]};
    saveMessageHashToStateFile($hash);

    #-- Adjust related reading
    my @cnt = grep { $_->{recipient} =~ m/^$recipient/ } @{$hash->{fhem}{messages}};
    readingsSingleUpdate($hash, "recipientMessageCnt_".$recipient, scalar @cnt, 1);

    #-- Adjust message counter
    $hash->{MSGCNT} = scalar @{$hash->{fhem}{messages}};
  }
  #-- Delete all messages of a specific recipient
  elsif(scalar @args == 2 && $args[1] eq "all") {

    my $recipient = $args[0];  

    Log3 $name, 4, "Delete messages of recipient".$recipient;
  
    my @a = grep { $_->{recipient} !~  m/^$recipient/ } @{$hash->{fhem}{messages}};

    $hash->{fhem} = {messages => [@a]};
    saveMessageHashToStateFile($hash);

    #-- Set concerning readint to 0
    readingsSingleUpdate($hash, "recipientMessageCnt_".$recipient, 0, 1);

    #-- Adjust message counter
    $hash->{MSGCNT} = scalar @{$hash->{fhem}{messages}};
  }
  #-- Delete all messages of the module
  elsif(scalar @args == 1 && $args[0] eq "all") {
    Log3 $name, 4, "Delete all messages";

    $hash->{fhem} = {messages => []};
    saveMessageHashToStateFile($hash);

    #Set all message readings counter to 0
    readingsBeginUpdate($hash);
    for my $reading (grep { /^recipientMessageCnt.*/ } keys %{$hash->{READINGS}}) {
     readingsBulkUpdate($hash, $reading, 0);
    }
    readingsEndUpdate($hash, 1);

    #-- Reset message counter
    $hash->{MSGCNT} = 0;
  }

  return undef;
 }

#########################################################################################
#
# MessageQueue_Delete - Delete all messages
# 
# Parameter hash = hash of device addressed
#           messagestring = full message string
#
#########################################################################################

sub MessageQueue_Clear($) {
  my ($hash) = @_;
  my $name = $hash->{NAME}; 

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Clear()";

  Log3 $name, 4, "Delete all messages";

  $hash->{fhem} = {messages => []};
  saveMessageHashToStateFile($hash);

  #Delete all message readings
  readingsBeginUpdate($hash);
  for my $reading (grep { /^recipientMessageCnt.*/ } keys %{$hash->{READINGS}}) {
   readingsBulkUpdate($hash, $reading, undef);
   readingsDelete($hash, $reading);
   Log3 $name, 5, "[MessageQueue] Deleted reading $reading";
  }

  #-- Delete all msg modul readings
  for my $reading (grep { /^fhemMsg.*/ } keys %{$hash->{READINGS}}) {
   readingsDelete($hash, $reading);
  }

  readingsBulkUpdate($hash, "lastMessageReceived", undef);
  readingsDelete($hash, "lastMessageReceived");

  readingsBulkUpdate($hash, "state", "OK");

  readingsEndUpdate($hash, 1);

  #-- Last error string
  $hash->{LASTERRMSG} = "nothing";

  #-- Reset message counter
  $hash->{MSGCNT} = 0;
}


#########################################################################################
#
# PostMe_Set - Implements the Set function
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub MessageQueue_Set($$$@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  my ( $a, $h ) = parseParams( join " ", @args);

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Set()";

  Log3 $name, 5, "Value cmd: ".$cmd;
  Log3 $name, 5, "Value args: ".join("|",@args);
  Log3 $name, 5, "Value a: ".join(" ",@$a);
  Log3 $name, 5, "Value h: ".Dumper $h;

  unless ( $cmd =~ /^(add|delete|clear)$/i ) {
    return undef;
    my $usage = "Unknown command $cmd, choose one of add delete clear:noArg";

    return $usage;
  }
  
  return "Unable to add message: Device is disabled"
      if ( IsDisabled($name) );

  return MessageQueue_Add($hash, $cmd, $a, $h)
      if ( $cmd eq "add" );

  return MessageQueue_Delete($hash, $name, $cmd, @args)
      if( $cmd eq "delete" );

  return MessageQueue_Clear( $hash )
      if ( $cmd eq "clear" );

}

#########################################################################################
#
# PostMe_Get - Implements the Get function
# 
# Parameter hash = hash of device addressed
#
#########################################################################################

sub MessageQueue_Get($$$@) {
  my ($hash, $name, $cmd, @args) = @_;
  my ( $a, $h ) = parseParams( join " ", @args );

  Log3 $name, 3, "MessageQueue $name: called function MessageQueue_Get()";

  Log3 $name, 5, "Value cmd: ".$cmd;
  Log3 $name, 5, "Value args: ".join("|",@args);
  Log3 $name, 5, "Value a: ".join(" ", @$a);
  Log3 $name, 5, "Value h: ".Dumper $h;

  my $pmn;
  my $res = "";
  

  unless ( $cmd =~ /^(json|all|jsontest|dump|upgrade|dumphash|resethash|load|save|version|test)$/i ) {
    my $usage = "Unknown command $cmd, choose one of version:noArg json all:noArg jsontest dump upgrade:noArg dumphash:noArg resethash:noArg load:noArg save:noArg test";

    return $usage;
  }

  my $msgcnt = ReadingsVal($name,"messagesCnt", 0);
  
  # Module version
  return "MessageQueue.version => $mqVersion" 
    if ($cmd eq "version");
  
  # json transform
  return getMessageAsJson($hash, $name, $cmd, @args)
    if ( $cmd eq 'json' );

    # Get a list of all messages
    if ($cmd eq "all") {
      my $res = "";
      foreach my $msgarray (@{$hash->{fhem}{messages}}) {
        #my $s = Dumper $d;
        #Log3 $name,3,"[MessageQueue] Message hash dump: $s";
        my $priority = defined($msgarray->{priority}) ? $msgarray->{priority} : "";
        
        # Handle message parameter
        my $parameter = "";
        if(defined($msgarray->{parameter})) {
          foreach my $key (sort keys %{$msgarray->{parameter}}) {
            $parameter .= $key."=".$msgarray->{parameter}->{$key};
            $parameter .= " ";
          }
        }

        my $dateTimeString = localtime(int($msgarray->{timestamp}));

        # Create message term
        $res .= $dateTimeString.": ".$msgarray->{timestamp}."@".$msgarray->{recipient}.",".$priority.",".$msgarray->{title}.",".$msgarray->{text}." ".$parameter;
        $res .= "\n";
      }

      # for( my $loop=1; $loop<=$msgcnt; $loop++){
      #   $res .= sprintf("%03d", $loop).": ";
      #     $res .= ReadingsVal($name, sprintf("message%03d", $loop), "");
      #     $res .= "\n";
      #  }
      return $res;
    } 
   
    # Hash dump of a specific message
    elsif ($cmd eq "dump" && $args[0] ne "") {
      my $msgno = int($args[0]);
      foreach my $msgarray (@{$hash->{fhem}{messages}}) {
        if(int($msgarray->{id}) == $msgno) {
          return Dumper $msgarray;
        }
      }
    }
    # Hash dump of all messages
    elsif ($cmd eq "dumphash") {
      return Dumper $hash->{fhem}{messages};
    }
    # Delete all messages from message hash
    elsif ($cmd eq "resethash") {
      $hash->{fhem} = {messages => []};
      return "done";
    }
    # Restore message hash from message state file
    elsif($cmd eq "load") {
      my $statefile = getStatefileName($hash);
      Log3 $name, 3, "MessageQueue $name: Module state file '".$statefile."'";
      loadMessageHashFromStateFile($hash);
      return "done";
    }
    # Backup message hash to message state file
    elsif($cmd eq "save") {
      my $statefile = getStatefileName($hash);
      Log3 $name, 3, "MessageQueue $name: Module state file '".$statefile."'";
      saveMessageHashToStateFile($hash);
      return "done";
    }
    # Optional upgrade function
    elsif ($cmd eq "upgrade") {
      ##readingsBeginUpdate($hash);
      $hash->{fhem} = {messages => []};

      ##for my $reading (grep { m/^message\d\d\d/ } sort keys %{$hash->{READINGS}}) {
      my $msgno = int(ReadingsVal($name, "messagesCnt", "0"));  
      for (my $messeagecnt = 1; $messeagecnt <= $msgno; $messeagecnt++) {
        my $val = ReadingsVal($name, sprintf("message%03d", $messeagecnt), "");
        if($val ne "" && $val =~ m/^\d{10}/) {
          ##my $messeagecnt = substr($reading, -3);
          my $msgHash = createMsgHashFromTerm($hash, $val);
          push(@{$hash->{fhem}{messages}}, $msgHash) if($msgHash != undef);
        }
      }

      ##readingsEndUpdate($hash, 1);

      return "done";
    }
    elsif($cmd eq "test") {
      #$hash->{fhem} = {messages => []};

      #my %msghash_copy = %{$MSGHASH_TEMPLATE};
      #my $msghash = \%msghash_copy;
      
      #-- remove all undef items
      #my @a = grep { exists $_->{uuid} } @{$hash->{fhem}{messages}};
      #$hash->{fhem} = {messages => [@a]};
      #saveMessageHashToStateFile($hash);

      #my @a = grep { $_->{uuid} =~ m/^cfe0c24c-bd55-46e1-86d6-69fc975ae3fd/ } @{$hash->{fhem}{messages}};
      #my $a = grep { $_->{recipient} =~ m/^andreas/ } @{$hash->{fhem}{messages}};

      my $lifetime = AttrVal($name, "MQ_MaxLifetime", undef);
      my $maxsize = AttrVal($name, "MQ_MaxSize", undef);

      my $cnt = grep { $_->{recipient} =~ m/^$args[0]/ } @{$hash->{fhem}{messages}};
      my $diff = $cnt - $maxsize;

      my @a;
      if(!$maxsize) {
        my $index = 1;
        my @a = grep { $_->{recipient} !~  m/^$args[0]/ || ($_->{recipient} =~  m/^$args[0]/ && $index++ > $diff) } @{$hash->{fhem}{messages}};
      }
      #my $limit = 0;
      #$limit = time() - ($lifetime * 84600) if($lifetime);
      #my @a = grep { $_->{recipient} !~  m/^$args[0]/ || $_->{timestamp} >= $limit } @{$hash->{fhem}{messages}} if($lifetime);
     
      #$hash->{fhem}{messages} = @a;
      return Dumper \@a;
      #return $a;
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
#########################################################################################
#
# MessageQueue_detailFn - Displays Info,Set and Get in detailed view of FHEM
# 
# Parameter = web argument list
#
#########################################################################################

sub MessageQueue_detailFn() {
  my ($FW_wname, $name, $room, $page) = @_;
  my $hash = $defs{$name};

  #-- Module recipient mode
  my $attrMode = AttrVal($name, "MQ_Mode", "single");

  my $state = ReadingsVal($name, "state", "");

  my $icon = AttrVal($name, "icon", "");
  $icon = FW_makeImage($icon, $icon, "icon") . "&nbsp;" if($icon);

  #-- Create recipient option list
  my @recipientList = split(" ", AttrVal($name, "MQ_recipients", ""));

  my $optionsUserList = "";
  my $optionsUserListIndex = 0;

  if($attrMode eq "multi" && scalar @recipientList >= 0) {
    foreach (@recipientList) {
      $optionsUserListIndex++;
      if($optionsUserListIndex == 1) {
        $optionsUserList .= qq{
            <option selected="selected" value="\@$_">$_</option>
        };
      }
      else {
        $optionsUserList .= qq{
            <option value="\@$_">$_</option>
        };
      }
    }
    $optionsUserList .= qq{
            <option value="\@all">all</option>
    };
  }

  my $html = qq {
    <script type="text/javascript">
      function createValueString() {
        var value1 = document.getElementById("val1_set$name").value;
        var value2 = document.getElementById("val2_set$name").value;

        var valueString = value1 + "," + value2;

        document.getElementById("val_set$name").value = valueString.trim();
      }

      function select$name(i) {
          if (i == 0) {
            document.getElementById("div_val1_set$name").style.display = "inline-block";
            document.getElementById("div_val2_set$name").style.display = "inline-block";
          }
          else if (i == 1) {
            document.getElementById("div_val1_set$name").style.display = "none";
            document.getElementById("div_val2_set$name").style.display = "none";
            document.getElementById("val_set$name").value = "";
          }
          else if (i == 2) {
            document.getElementById("div_val1_set$name").style.display = "inline-block";
            document.getElementById("div_val2_set$name").style.display = "inline-block";
          }
      }
    </script>
  };

  $html .= qq {
  <div id="ddtable" class="makeTable wide">
    <span class="mkTitle">DeviceOverview</span>
    <table class="block wide">
      <tbody>
        <tr class="odd">
          <td>
            <div class="col1">
              <a href="/fhem?detail=$name">$icon&nbsp;$name</a>
            </div>
          </td>
          <td informid="$name">
            <div id="$name" title="$state" class="col2">$state</div>
          </td>
        </tr>
      </tbody>
    </table>
  </div>
  };

  $html .= qq {
    <br>
  };

  if($attrMode eq "single" && scalar @recipientList == 0) {
    $html .= qq {
      <div class="makeSelect">
        <form method="post" action="/fhem" autocomplete="off">
          <input type="hidden" name="detail" value="$name">
          <input type="hidden" name="dev.set$name" value="$name">
          <input type="hidden" name="fwcsrf" value="csrf_199457312500663">
          <input type="submit" name="cmd.set$name" value="set" class="set">
          <div class="set downText">&nbsp;$name&nbsp;</div>
          <select id="sel_set$name" informid="sel_set$name" name="arg.set$name" class="set" onchange="select$name(this.selectedIndex)">
            <option selected="selected" value="add">add</option>
            <option value="clear">clear</option>
            <option value="delete">delete</option>
          </select>
          <div id="div_val1_set$name" style="display:none"></div>
          <div id="div_val2_set$name" style="display:inline-block">
            <input type="text" id="val_set$name" informid="val_set$name" name="val.set$name" size="30">
          </div> 
        </form>
      </div>
    };
  }
  elsif($attrMode eq "single" && scalar @recipientList >= 0) {
    $html .= qq {
      <div class="makeSelect">
        <form method="post" action="/fhem" autocomplete="off">
          <input type="hidden" name="detail" value="$name">
          <input type="hidden" name="dev.set$name" value="$name">
          <input type="hidden" name="fwcsrf" value="csrf_199457312500663">
          <input type="submit" name="cmd.set$name" value="set" class="set">
          <div class="set downText">&nbsp;$name&nbsp;</div>
          <select id="sel_set$name" informid="sel_set$name" name="arg.set$name" class="set" onchange="select$name(this.selectedIndex)">
            <option selected="selected" value="add">add</option>
            <option value="clear">clear</option>
            <option value="delete">delete</option>
          </select>
          <div id="div_val1_set$name" class="set downText">&nbsp;\@$recipientList[0]&nbsp;</div>
          <div id="div_val2_set$name" style="display:inline-block">
            <input type="text" id="val_set$name" informid="val_set$name" name="val.set$name" size="30">
          </div> 
        </form>
      </div>
    };
  }
  elsif($attrMode eq "multi" && scalar @recipientList >= 0) {
    $html .= qq {
      <div class="makeSelect">
        <form method="post" action="/fhem" autocomplete="off">
          <input type="hidden" name="detail" value="$name">
          <input type="hidden" name="dev.set$name" value="$name">
          <input type="hidden" name="fwcsrf" value="csrf_199457312500663">
          <input type="submit" name="cmd.set$name" value="set" class="set">
          <div class="set downText">&nbsp;$name&nbsp;</div>
          <select id="sel_set$name" informid="sel_set$name" name="arg.set$name" class="set" onchange="select$name(this.selectedIndex)">
            <option selected="selected" value="add">add</option>
            <option value="clear">clear</option>
            <option value="delete">delete</option>
          </select>
          <div id="div_val1_set$name" style="display:inline-block">
            <select id="val1_set$name" onchange="createValueString()">
              $optionsUserList
            </select>
          </div>
          <div id="div_val2_set$name" style="display:inline-block">
            <input id="val2_set$name" type="text" size="30" onchange="createValueString()">
          </div>
          <input type="hidden" id="val_set$name" informid="val_set$name" name="val.set$name">
        </form>
      </div>
    };
  }
  else {
    return undef;
  }  

  return $html;
}
1;

=pod
=item helper
=item summary Stores notifications into a messages queue to provide these to other applications in json format 
=item summary_DE Speichert Benachrichtigungen in einer Nachrichtenwarteschlange, um diese anderen Anwendungen im JSON-Format bereitzustellen

=begin html

  <a name="MessageQueue"></a>
  <h3>MessageQueue</h3
  <p>Stores notifications into a messages queue to provide these to other applications in json format</p>
  
  <a name="MessageQueuedefine"></a>
  <h4>Define</h4>
  <p>
    <code>define &lt;name&gt; MessageQueue</code>
    <br />Defines the MessageQueue system, &lt;name&gt; is an arbitrary name for the message queue. 
  </p>

  <a name="MessageQueueusage"></a>
  <h4>Usage</h4>
  <p>
  An limited number of messages may be added to the system with the <i>add</i> command.<br />
  The system is able to handle messages for a single or for multiple recipients. The maximun amount of messages stored <br />
  in the system is limited to 10000 items. It's possible to limit the messages queueing for a recipient<br />
  individual based on the message lifetime in days or based on the maximum numbers of messages. Both possibilities could <br />
  also be used in combination.
  </p>
  <strong>Message term</strong>
  <p>
    The message is a single-line text string in a specific format that can be added with the add command to the message queue:<br />
    <br />
    Single recipient mode:&nbsp;[TITLE],[PRIORITY],TEXT,[PARAMETER]<br />
    <br />
    Mutilple recipient mode:&nbsp;@RECIPIENT,[TITLE],[PRIORITY],TEXT,[PARAMETER]<br />
    <p>
    RECIPIENT - Name of the recipient in multiple recipient mode. The name must be equal to one of the defined recipients by the attribute MQrecipients (case sensitive)<br />
    TITLE - Optional message title<br />
    PRIORITY -  Optional priority flag 0-2<br />
    TEXT - Message text<br />
    PARAMETER - Optional parameters as key/value pairs seperated by a space<br />
    </p>
  </p>

  <a name="MessageQueueset"></a>     
  <h4>Set</h4>
  <ul>
    <li>
      <code>set &lt;name&gt; add &lt;message term&gt;</code><br />
      Add a message term to the meassage queue
    </li>
  </ul>

  <a name="MessageQueueget"></a>     
  <h4>Get</h4>
  <ul>
  </ul>

  <a name="MessageQueueattr"></a>     
  <h4>Attribute</h4>
  <ul>
  </ul>

  <a name="MessageQueuereadings"></a>     
  <h4>Readings</h4>
  <ul>
  </ul>

=end html

=begin html_DE

  <a name="MessageQueue"></a>
  <h3>MessageQueue</h3>
  <p>Speichert Benachrichtigungen in einer Nachrichtenwarteschlange, um diese anderen Anwendungen im JSON-Format bereitzustellen</p>

  <h4>Define</h4>
  <p>
    <code>define &lt;name&gt; MessageQueue</code>
    <br />
    Definiert das MessageQueue System, &lt;name&gt; ist ein beliebiger Name für das System.
  </p>

  <a name="MessageQueueusage"></a>
  <h4>Benutzung</h4>
  <p>
  Mit dem Befehl <i>add</i> kann dem System eine limitiete Anzahl von Nachrichten hinzugefügt werden.<br />
  Das System kann Nachrichten für einen einzelnen oder für mehrere Empfänger verarbeiten. Die Anzahl der gespeicherten Nachrichten, <br />
  ist auf 10000 Elemente begrenzt. Es ist möglich, die Anzahl der Nachrichten für eine Empfängerperson basierend auf der Lebensdauer <br />
  einer Nachricht in Tagen oder der maximalen Anzahl von Nachrichten zu begrenzen. Beide Möglichkeiten könnten auch in Kombination <br />
  genutzt werden.
  </p>

  <a name="MessageQueueset"></a>     
  <h4>Set</h4>
  <ul>
  </ul>

  <a name="MessageQueueget"></a>     
  <h4>Get</h4>
  <ul>
  </ul>

  <a name="MessageQueueattr"></a>     
  <h4>Attribute</h4>
  <ul>
  </ul>

  <a name="MessageQueuereadings"></a>     
  <h4>Readings</h4>
  <ul>
  </ul>

=end html_DE
=cut
