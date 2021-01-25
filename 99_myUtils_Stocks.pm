#Module to get latest update on stocks, created to be used in smart-home project of group 3
package main;

use strict;
use warnings;
use Blocking;
use HttpUtils;
use JSON;
use POSIX;
use Encode qw(decode encode);


my $Module_Version = '0.0.1 - 09.12.2020';
my $error = "There is an Error in define function";






#____________FHEM-Standardfunktionen__________
#  1) Initialize($): Initialisiert das Modul und definiert Attribute und Funktionen
#     Als 99_myUtils_xxx Modul wird die Funktion automatisch beim Starten von FHEM initialisiert
#  2) Define($$): Erstellt ein Device. Syntax ist: 'define <Name> myUtils_Stocks <pollInterval>'
#     Kontrolle ob Sytax richtig eingegeben. Gegebenenfalls setzen von Standardwerten
#     Standardwerte für Attribute ChangeTime (1 Tag) und ChangePercent (5%) werden gesetzt
#     2 Sekunden nach Anlegen wird die Funktion PerformHttpRequest_Name aufgerufen
#  3) Undefine($$): Device wird entfernt, FileLog wird gelöscht, InternalTimer wird zurückgesetzt 

#############Initialize Funktion wird beim Starten des Servers aufgerufen###########
sub myUtils_Stocks_Initialize($)
{
   my ($hash) = @_; 

    $hash->{DefFn}    = "myUtils_Stocks_Define";
    $hash->{UndefFn}  = "myUtils_Stocks_Undefine";
    #$hash->{SetFn}    = "myUtils_Stocks_Set";
    #$hash->{GetFn}    = "myUtils_Stocks_Get";
    #$hash->{AttrFn}   = "myUtils_Stocks_Attr";
    $hash->{NotifyFn} = "myUtils_Stocks_Notify";
    $hash->{AttrList} = "Stock pollInterval queryTimeout ChangeTime ChangePercent NotificationHigh NotificationLow NotificationStart NotificationChange $main::readingFnAttributes";
                        
    return;
}

############Define-Funktion steuert Anlage neuer Devices###################
sub myUtils_Stocks_Define($$)
{
  
  my ($hash, $def, $attr ) = @_;
  my @a = split( "[ \t][ \t]*", $def );
  my $name   = $a[0];
  $hash->{NAME} = $name;



  if (@a < 1) {
    return 'wrong syntax: define <WKN> myUtils_Stocks <interval>';
  }

  if ($a[0] eq 'none') {
    return 'No Stock specified';
  }else {
     $attr{$hash->{NAME}}{"Stock"} = $a[0];
  }


  if(int(@a) > 2) {
  if ($a[2] > 0) {
    return 'interval too small, please use something > 5, default is 86.400' if ($a[2] < 5);
    $attr{$hash->{NAME}}{"pollInterval"} = $a[2];
  }else{
    return '0 is not a correct interval, default is 86.400';
    $attr{$hash->{NAME}}{"pollInterval"} = 86400;
  }
  }else{
    Log3 $name, 3, "$name: no valid interval specified, default is 86.400";
    $attr{$hash->{NAME}}{"pollInterval"} = 86400;
  }


  #$attr{$hash->{NAME}}{"pollInterval"} = 300;
  $attr{$hash->{NAME}}{"queryTimeout"} = 120;
  
  $attr{$hash->{NAME}}{"NotificationStart"} = "0";
  $attr{$hash->{NAME}}{"NotificationHigh"} = "0";
  $attr{$hash->{NAME}}{"NotificationLow"} = "0";
  $attr{$hash->{NAME}}{"NotificationChange"} = "0";
  
  #Event wenn neuer Call vollzogen
  $attr{$hash->{NAME}}{"event-on-update-reading"} = "Current_Price";

  #Standardwert fü Zeitspanne
  $attr{$hash->{NAME}}{"ChangeTime"} = 86400;

  #Standardwert fü Veräerung
  $attr{$hash->{NAME}}{"ChangePercent"} = 5;

  readingsSingleUpdate($hash, "state", "Initialized",1);
  readingsSingleUpdate($hash, "Start_Price", "loading...",0);

  my $stock = $attr{$hash->{NAME}}{"Stock"};
  Log3 $name, 3, "$name: New Stonk $stock added to watch list";


  InternalTimer(gettimeofday()+2, "myUtils_Stocks_PerformHttpRequest_Name", $hash);
  #UpdateTimer($hash, "myUtils_Stocks_PerformHttpRequest", 'start');

	return undef;

}

#######Action for undefining##############################################
sub myUtils_Stocks_Undefine($$)
{
    #my $hash = shift;                       # reference to the Fhem device hash 
    #my $name = shift;
    my ( $hash, $name ) = @_;                    # name of the Fhem device
    $name = $hash->{NAME};
    myUtils_Stocks_save();
    RemoveInternalTimer($hash);
    RemoveInternalTimer($name);
    #RemoveInternalTimer ("timeout:$name");
    fhem("delete FileLog_Aktie_$name");
    #StopQueueTimer($hash, {silent => 1});     
    #UpdateTimer($hash, \&HTTPMOD::GetUpdate, 'stop');
    #$error = FileDelete("./log/$name-Log-%Y.log");
    return undef;
}







#____________Abfragen des Firmennamens___________
#  1) PerformHttpRequest_Name($): Methode wird nur einmal nach define aufgerufen. Mithilfe der WKN Nummer wird die Seite der Aktie auf 
#     Boerse-Online aufgerufen. Callback der Response an ParseHttpResponse_Name
#  2) ParseHttpResponse_Name($): Verarbeitet die Response. Aus der zurückgegebene (weitergeleiteten) URL wird mit einem RegEx der Name ausgelesen
#     Der Name wird als Reading "Company abgespeichert"
#     Funktion ruft PerformHttpRequest_Data auf um Daten abzufragen

#########Anfrage senden###########
sub myUtils_Stocks_PerformHttpRequest_Name($)
{
  my ($hash, $def, $attr) = @_;
    my $name = $hash->{NAME};
    my $stock = $attr{$hash->{NAME}}{"Stock"};

    my $url = "https://www.boerse-online.de/suchergebnisse?_search=$stock";
    
    my $param = {
                    url        => $url,
                    timeout    => $attr{$hash->{NAME}}{"queryTimeout"},
                    hash       => $hash,                                                                                 
                    method     => "GET",                                                                                 
                    header     => "Content-Type: application/json",                            
                    callback   => \&myUtils_Stocks_ParseHttpResponse_Name                                                                  
                };

    HttpUtils_NonblockingGet($param);
}

############Antwort verarbeiten########
sub myUtils_Stocks_ParseHttpResponse_Name($)
{
    my ($param, $err, $data, $attr) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $stock = $attr{$hash->{NAME}}{"Stock"};
	  my $regex_name;

    my $company = "Aktie";
    my $url = $param->{url};
  

    if($err ne "")                                                                                                      
    {
        Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                              
        readingsSingleUpdate($hash, "API Call", "ERROR", 0);
        readingsSingleUpdate($hash, "state", "No Data",0);
        $company = "AMAZON";                                                      
    }
    elsif($data ne "")                                                                                                  
    {
      readingsSingleUpdate($hash, "API Call", "SUCCESS", 0);
      #my $regex_name = qr/finanzen.net:443\Waktien\W([\w\W]*)-aktie/mp;
      $regex_name = qr/boerse-online.de:443\Waktie\W([\w\W]*)-aktie/mp;
      if ( $url =~ /$regex_name/ ) {
          my $upper_name = uc($1);
          $company = $upper_name;
      }else {
        #Log3 $name, 3, "Could not receive company name of Stock $stock";
        }
    }else{
    Log3 $name, 3, "$name: Cannot find matching company";
  }
  readingsSingleUpdate($hash, "Company", "$company",0);
  return myUtils_Stocks_PerformHttpRequest_Data($hash);
}







#___________Abfragen der Daten (Kurs, abs./rel. Veränderung)_______
#  1) PerformHttpRequest_Data($): Reading "Company" wird ausgelesen. Finanzen.net wird mit "Company" die entsprechende Seite aufgerufen
#     Dies ist möglich, da Finanzen.net und Boerse-online den selben Syntax der Namen verwenden
#     Callback der Response an Funktion ParseHttpResponse_Data
#  2) ParseHttpResponse_Data($): Verarbeitet die Response. Mithilfe von RegExp wird der HTML-Quelltext analysiert und ausgewertet
#     Die gefundenen Werte werden in die entsprechenden Readings geschrieben
#     Der state des Devices wird mit $company: $kurs EUR geupdated
#     Mit einem InternalTimer wird die Funktion PerformHttpRequest_Data nach einem definierbaren Zeitraum (Attribut: "pollInterval") erneut aufgerufen

######HTTP Request to Stock Page############################################
sub myUtils_Stocks_PerformHttpRequest_Data($)
{
    my ($hash, $def, $attr) = @_;
    my $name = $hash->{NAME};

    my $status = IsDevice("$name");
    if($status eq 1){
    my $company_upper = ReadingsVal($name, "Company", "Undefined");
    my $company = lc($company_upper);

    my $url = "https://www.finanzen.net/aktien/$company-aktie";
    
    
    my $param = {
                    url        => $url,
                    timeout    => $attr{$hash->{NAME}}{"queryTimeout"},
                    hash       => $hash,                                                                                 
                    method     => "GET",                                                                                 
                    header     => "Content-Type: application/json",                            
                    callback   => \&myUtils_Stocks_ParseHttpResponse_Data                                                                  
                };

    HttpUtils_NonblockingGet($param);
    }else{
      Log3 $name, 3, "ERROR: Stock $name not exists - No Request sent";
    }
}

########Handle Response##############################################
sub myUtils_Stocks_ParseHttpResponse_Data($)
{
    my ($param, $err, $data, $attr) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};
    my $stock = $attr{$hash->{NAME}}{"Stock"};

    my $status = IsDevice("$name");
    if($status eq 1){

    my $price = "Preis";
    my $change_abs = "undefined";
    my $change_rel = "undefined";
    my $company = ReadingsVal($name, "Company", "Undefined");
    my $url = $param->{url};
  

    if($err ne "")                                                                                                      
    {
        Log3 $name, 3, "error while requesting ".$param->{url}." - $err";                                              
        readingsSingleUpdate($hash, "API Call", "ERROR", 0);
        readingsSingleUpdate($hash, "state", "No Data",0);
        InternalTimer(gettimeofday()+3600, "myUtils_Stocks_PerformHttpRequest_Data", $hash);                                                         
    }

    elsif($data ne "")                                                                                                  
    {
      readingsSingleUpdate($hash, "API Call", "SUCCESS", 0);
      #Regex füative Kursäerung anwenden
      my $regex_change_rel = qr/EUR[\w\W]{1,40}[\w\W]{0,50}">([\w\W]{0,5})<span>%/mp;
      if ( $data =~ /$regex_change_rel/ ) {
        $change_rel = $1;
      }else {
        #Log3 $name, 3, "$name: Could not receive relative change of Stock $stock $company";
        }


          #Regex füolute Kursäerung anwenden
          my $regex_change_abs = qr/<div class="col-xs-4 col-sm-3 [\w\W]{0,50}">([\d\W]*)<span>EUR/mp;
          if ( $data =~ /$regex_change_abs/ ) {
          $change_abs = $1;
          if ( $1 =~ m/\+/){
            $attr{$hash->{NAME}}{"icon"} = "rc_GREEN";
          }else{
            $attr{$hash->{NAME}}{"icon"} = "rc_RED";
          }
      }else {
        #Log3 $name, 3, "Could not receive absolute change of Stock $stock $company";
        }


      
      #Regex füis anwenden
      my $regex_current = qr/<div class="col-xs-5 col-sm-4 text-sm-right text-nowrap">([\d\W]{1,9})<span>EUR/mp;  
      if ( $data =~ /$regex_current/ ) {
        $price = $1;    
      }else {
        #Log3 $name, 3, "Could not receive data for Stock $stock $company";
        }


      readingsSingleUpdate($hash, "relative_Change", "$change_rel %",0);
      readingsSingleUpdate($hash, "absolute_Change", "$change_abs EUR",0);
      readingsSingleUpdate($hash, "Current_Price", "$price", 1);

      my $regexInsertion = qr/\d{2,}/mp;
      if(ReadingsVal($name, "Start_Price", "loading...") =~ /$regexInsertion/){}else{
        readingsSingleUpdate($hash, "Start_Price", "$price",0);
      }
      
      readingsSingleUpdate($hash, "state", "$company: $price EUR",0);   #Status Reading updaten

      if($price ne ""){
        myUtils_Stocks_Notification($name);
      }else{
      Log3 $name, 3, "$name: unknown ERROR";
    }
      

    }else{
      Log3 $name, 3, "$name: unknown ERROR: $url cant be loaded";
    }

    if(!(IsWe())){
      InternalTimer(gettimeofday()+$attr{$hash->{NAME}}{"pollInterval"}, "myUtils_Stocks_PerformHttpRequest_Data", $hash); #Timer erneut starten
    }else{
      InternalTimer(gettimeofday()+3600, "myUtils_Stocks_PerformHttpRequest_Data", $hash); #stündlich am Wochenende
    }
    
    }else{
      Log3 $name, 3, "ERROR: Stock $name not exists - No Response parsed";
    }
}










#__________Benachrichtigung____________
# 1) NotificationDefine($$$): Über diese Funktion kann die Zeit zwischen zwei Werten und die Veränderung in Prozent angegeben werden
#    Standardwerte sind 5% in einem Tag. Die neuen Werte überschreiben die Standardwerte (Attribute: ChangePercent, ChangeTime)
# 2) Notification($): Eigentlicher Ablauf der Benachrichtigungslogik: Attribute ChangePercent u. ChangeTime werden ausgelesen
#    Zeitinterval (Toleranz für Ungenauigkeit des InternalTimers) in dem der Referenzwert liegt wird berechnet
#    Entsprechende FileLog wird mit Zeitinterval abgefragt, Aktuelles Reading wird mit Referenzwert verrechnet
#    Ausgabe der Benachrichtung bei dementsprechender Veränderung

######################Ändern der Attribute für die Benachrichtigungs###############
sub myUtils_Stocks_NotificationDefine($$$){
  my ($time, $percent, $wkn) = @_;
  fhem("attr $wkn ChangeTime $time");
  fhem("attr $wkn ChangePercent $percent");
  Log3 $wkn, 3, "Attributes for Notification changed: Time $time, Percent $percent";
  #$attr{$hash->{NAME}}{"ChangeTime"} = $time;
  #$attr{$hash->{NAME}}{"ChangePercent"} = $percent;
}


######################Anpassen der Benachrichtigung################################


##################Workaround###############################
sub myUtils_Stocks_GetFileLog($$$){
  my ($wkn, $min_reference_time, $max_reference_time) = @_;
  fhem ("attr global logfile ./log/temp.log");
  my $reference_log = fhem("get FileLog_Aktie_$wkn - - $min_reference_time $max_reference_time");
  fhem ('{qx(truncate $currlogfile --size 0);;Log 1, "Logfile gelöscht";;}');
  fhem ("attr global logfile ./log/fhem-%Y-%m.log");
  return $reference_log;
}


####################Benachrichtigung#########################
sub myUtils_Stocks_Notification($)
{
  my ($wkn) = @_;
  my $company = ReadingsVal($wkn, "Company", "Undefined");
  my $reference_price;
  my $difference;
  my $high = "";
  my $high_time;
  my $low = "";
  my $low_time;
  my $start_price=0.1;
  my $end_price=0.1;
  my $start_difference;
  my $absolut_start_price=0.1;
  #my $regex_test_digit = qr/\D{3,}/mp;
  my $regex_test_digit = qr/.*,.*/mp;
  my $time = AttrVal("$wkn", "ChangeTime", 86400);
  my $time_hr = ($time/3600);
  my $percent = AttrVal("$wkn", "ChangePercent", 86400);




  my $timestamp = ReadingsTimestamp($wkn, "state", undef);
  my $ts_seconds = time_str2num($timestamp);

  #my $max_reference_time = POSIX::strftime("%Y-%m-%d_%H:%M:%S",localtime(time-$time+60));
  #my $min_reference_time = POSIX::strftime("%Y-%m-%d_%H:%M:%S",localtime(time-$time-60));

  #my $max_reference_time = POSIX::strftime("%Y-%m-%d_%H:%M:%S",localtime($ts_seconds-$time+90));
  my $max_reference_time = POSIX::strftime("%Y-%m-%d_%H:%M:%S",localtime(time));
  my $min_reference_time = POSIX::strftime("%Y-%m-%d_%H:%M:%S",localtime($ts_seconds-$time-90));

  #fhem ("attr global logfile ./log/temp.log");
  #my $reference_log = fhem("get FileLog_Aktie_$wkn - - $min_reference_time $max_reference_time");
  #fhem ("attr global logfile ./log/fhem-%Y-%m.log");
  my $reference_log = myUtils_Stocks_GetFileLog($wkn, $min_reference_time, $max_reference_time);
  my @entries = split /\n/, $reference_log;
  my $length = @entries;

  if ($length < 2){
    Log3 $wkn, 3, "$wkn: Not enough data for change calculation";
  }else {



  for (my $i=0; $i < $length; $i++) {

    if(@entries[$i] =~ /$regex_test_digit/g){

    my $regex = qr/[\W\w]*: ([\d\W]*)/mp;
    if ( @entries[$i] =~ /$regex/){
      $reference_price = $1;

      my $replacement = qr/\./p;
      my $subst = '';
      $reference_price = $reference_price =~ s/$replacement/$subst/r;

      $replacement = qr/\,/p;
      $subst = '.';
      $reference_price = $reference_price =~ s/$replacement/$subst/r;

      @entries[$i] = $reference_price;

      

      if($i eq 0){
        $start_price = @entries[$i];
      }
      if($i eq ($length-1)){
        $end_price = @entries[$i];
      }

      if($high ne ""){
        if(@entries[$i] > $high){
          $high = @entries[$i];
          $high_time = $i;
        }
      }else{
        $high = @entries[$i];
        $high_time = $i;
      }

      if($low ne ""){
        if(@entries[$i] < $low){
          $low = @entries[$i];
          $low_time = $i;
        }
      }else{
        $low = @entries[$i];
        $low_time = $i;
      }
      }

        
      }else{

        delete @entries[$i];


    }
    }
  }
  

  #my $current_price = ReadingsVal("$wkn", "Current_Price", undef);

      $absolut_start_price = ReadingsVal($wkn, "Start_Price", "0.1");
      my $replacement = qr/\./p;
      my $subst = '';
      $absolut_start_price = $absolut_start_price =~ s/$replacement/$subst/r;

      $replacement = qr/\,/p;
      $subst = '.';
      $absolut_start_price = $absolut_start_price =~ s/$replacement/$subst/r;

      $start_difference = sprintf("%.2f",((($end_price/$absolut_start_price)-1)*100));

  

      $difference = sprintf("%.2f",((($end_price/$start_price)-1)*100));
      #$difference = ((($end_price/$start_price)-1)*100);

      my $NotificationHigh = AttrVal("$wkn", "NotificationHigh", "0");
      my $NotificationChange = AttrVal("$wkn", "NotificationChange", "0");
      my $NotificationLow = AttrVal("$wkn", "NotificationLow", "0");
      my $NotificationStart = AttrVal("$wkn", "NotificationStart", "0");

      
      my $message = "Zusammenfassung:";
      my $check_notification = 0;

      if($NotificationHigh eq "1"){
        #push @message, "Höchster Preis der letzten $time_hrh: $high EUR";
        $check_notification = 1;
        $message = $message . "\n Höchster Preis der letzten $time_hr Stunden: $high EUR";
      }
      if($NotificationLow eq "1"){
        #push @message, "Niedrigster Preis der letzten $time_hrh: $low EUR";
        $check_notification = 1;
        $message = $message . "\n Niedrigster Preis der letzten $time_hr Stunden: $low EUR";
      }
      if($NotificationChange eq "1"){
        #push @message, "Wertänderung zum Startpreis: $start_difference%";
        $check_notification = 1;
        $message = $message . "\n Wertänderung zum Startpreis: $start_difference%";
      }
      if($NotificationStart eq "1"){
        #push @message, "Startpreis: $absolut_start_price EUR";
        $check_notification = 1;
        $message = $message . "\n Startpreis: $absolut_start_price EUR";
      }



      if($end_price eq $start_price){
        Log3 $wkn, 3, "$wkn: Price not changed - Bot notified";
        #fhem("set telegram message \@Daniel_Schönfeld $wkn: Price not changed");
      }else{

          if($difference < 0){

            if($difference < ($percent*(-1))){
              if($check_notification eq 1 ){
                #fhem("set telegram message \@-256499467 Aktie $company ($wkn) in den letzten $time_hr Stunden um mehr als $percent% gefallen \n\n  Zusammenfassung: \n  Wertänderung: $difference% \n  Wertänderung zum Startpreis: $start_difference% \n  Hoch-/Tiefpreis der letzten $time_hr Stunden: $high EUR/ $low EUR");
                fhem("set telegram message \@-256499467 Aktie $company ($wkn) in den letzten $time_hr Stunden um mehr als $percent% gefallen\n  Wertänderung: $difference% \n\n  $message");
                Log3 $wkn, 3, "$wkn: Stonks decreased more than $percent: $difference %  - Message sent";
              }
            }else{
              Log3 $wkn, 3, "$wkn: Stonks decreased but, not enough: $difference %  - No message sent";
              #fhem("set telegram message \@Daniel_Schönfeld $wkn: Stonks decreased but, not enough: $difference %");
            }

          }elsif($difference > 0) {

            if($difference > $percent){
              if($check_notification eq 1){
                Log3 $wkn, 3, "$wkn: Stonks increased more than $percent: $difference %  - Message sent";
                #fhem("set telegram message \@-256499467 Aktie $company ($wkn) in den letzten $time_hr Stunden um mehr als $percent% gestiegen \n\n  Zusammenfassung: \n  Wertänderung: $difference% \n  Wertänderung zum Startpreis: $start_difference% \n  Hoch-/Tiefpreis der letzten $time_hr Stunden: $high EUR/ $low EUR");
                fhem("set telegram message \@-256499467 Aktie $company ($wkn) in den letzten $time_hr Stunden um mehr als $percent% gestiegen\n  Wertänderung: $difference% \n\n  $message");
              }
            }else{
              Log3 $wkn, 3, "$wkn: Stonks increased, but not enough: $difference %  - No Message sent";
              #fhem("set telegram message \@Daniel_Schönfeld $wkn: Stonks increased, but not enough: $difference %");
            }
          }#elsif($difference = 0){
          # Log3 $wkn, 3, "$wkn: Price not changed";
          #}
      }


    
    
  

  

  return "$max_reference_time $min_reference_time Die Werte der letzten $time Sekunden \nStart: $start_price EUR \nEnde: $end_price EUR \nHochpunkt: $high EUR \nTiefpunkt: $low EUR \nVeränderung: $difference% \nPreis beim Hinzufügen: $absolut_start_price \nVeränderung zum Zeitpunkt des Hinzufügens: $start_difference% \nAnzahl Eintraege: $length \nletzter Wert von: $timestamp\nBenachrichtigung bei: +-$percent% in $time sec.";
}


#_________Funktionen, als Endpunkte für Funktionsaufrufe aus dem Frontend/FHEM_________
#  1) getStocks(): Über diese Funktion erhält das Frontend alle aktuellen Aktien
#  2) addDevice($$): Neue Aktiendevices können angelegt werden. Syntax: '{myUtils_Stocks_addDevice("WKN",Intervall)}'
#     Funktion ruft define Funktion auf
#     Funktion setzt Device in Raum "Aktien"
#     Funktion ruft createLog auf um neues LogFile für Aktie zu erstellen
#  3) createLog($$$): FileLog wird erstellt
#     Anlegen eines neuen Log-Files falls noch nicht vorhanden
#     Setzten des Raumes auf "Aktien"

##########Alle aktuellen Aktien erhalten###############
sub myUtils_Stocks_getStocks()
{
    my (@stocks) = defInfo('TYPE=myUtils_Stocks:FILTER=room=Aktien', 'NAME');
    my $json_str = encode_json(\@stocks);
    return $json_str;
    #return @stocks;
}

#Mit Funktion {myUtils_Stocks_addDevice("WKN",Intervall)} kann einen neue Aktie angelegt werden
sub myUtils_Stocks_addDevice($$)
{
  my ($stockName, $callInterval) = @_;
  myUtils_Stocks_save();
  fhem("define $stockName myUtils_Stocks $callInterval");
  fhem("attr $stockName room Aktien");
  myUtils_Stocks_createLog("./log/$stockName-Log-%Y.log", 3, "New Log-File created for stock: $stockName");


  #__Ändernd des Attributes in global nicht möglich. Muss manuell erfolgen
  #my $current_values = AttrVal("global", "ignoreRegexp", "");
  #my $regex = qr/.*FileLog_Aktie_.*/mp;
  #if ($current_values =~ m/$regex/) {
  #}else{
  #  if($current_values eq ".*FileLog_Aktie_.*"){
  #    fhem("attr global ignoreRegexp $current_values\|.*FileLog_Aktie.*");
  #    fhem("attr global ignoreRegexp $current_values\|.*FileLog_Aktie.*");
  #  }else{
  #    fhem("attr global ignoreRegexp .*FileLog_Aktie.*");
  #    fhem("attr global ignoreRegexp .*FileLog_Aktie.*");
  #  }
  #}

  return $stockName;
}

############LogFile füie erstellen########################
sub myUtils_Stocks_createLog($$$)
{
    my ($filename, $loglevel, $text) = @_;

    return if ($loglevel > AttrVal('global', 'verbose', 3));

    my ($seconds, $microseconds) = gettimeofday();
    my @t = localtime($seconds);
    my $nfile = ResolveDateWildcards($filename, @t);

    my $tim = sprintf("%04d.%02d.%02d %02d:%02d:%02d", $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    if (AttrVal('global', 'mseclog', 0)) {
        $tim .= sprintf(".%03d", $microseconds / 1000);
    }

    open(my $fh, '>>', $nfile);
    #print $fh "$tim $loglevel: $text\n";
    close $fh;

    my $regex_stock = qr/New Log-File created for stock: ([\w\W]{0,40})/mp;
    if ($text =~ /$regex_stock/) {
      my $stockName = $1;
      fhem("define FileLog_Aktie_$stockName FileLog ./log/$stockName-Log-%Y.log $stockName");
      fhem("attr FileLog_Aktie_$stockName logtype text");
      fhem("attr FileLog_Aktie_$stockName room Aktien");
      fhem("attr FileLog_Aktie_$stockName icon time_note");
      

    }else{}

    return undef;
}





#_________Save-Funktion_______
#  1) save(): Verantwortlich für das Sichern von Änderungen

###########Äderungen in fhem.config speichern#################
sub myUtils_Stocks_save()
{
  return fhem("attr global autosave 1");
}

#################################Notify-Funktion##########################
sub myUtils_Stocks_Notify($$)
{
  my ($own_hash, $dev_hash) = @_;
  my $ownName = $own_hash->{NAME}; # own name / hash

  return "" if(IsDisabled($ownName)); # Return without any further action if the module is disabled

  my $devName = $dev_hash->{NAME}; # Device that created the events

  my $events = deviceEvents($dev_hash,1);
  return if( !$events );

  foreach my $event (@{$events}) {
    $event = "" if(!defined($event));

    # Examples:
    # $event = "readingname: value" 
    # or
    # $event = "INITIALIZED" (for $devName equal "global")
    #
    # processing $event with further code
  }
}








# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was MYMODULE steuert/unterstüitem summary_DE Kurzbeschreibung in Deutsch was MYMODULE steuert/unterstü=begin html
 Englische Commandref in HTML
=end html

=begin html_DE
 Deutsche Commandref in HTML
=end html

# Ende der Commandref
=cut

1;
