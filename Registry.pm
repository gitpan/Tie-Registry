#!perl -w
# Registry.pm -- Perl module to easily use a Registry (on Win32 systems so far)
# by Tye McQueen, tye@metronet.com, see http://www.metronet.com/~tye/.

#
# Skip to "=head" line for user documentation.
#

package Tie::Registry;

use strict;
use vars qw( $PACK $VERSION @ISA @EXPORT @EXPORT_OK );

$VERSION= '0.12';	# Released 1997-12-29

use Carp;
require Exporter;
require Tie::Hash;
@ISA= qw(Exporter Tie::Hash);
@EXPORT= qw( $Registry );
@EXPORT_OK= qw( $RegObj %RegHash $Registry );
$PACK= "Tie::Registry";	# Used in error messages.

# Required other modules:
use Win32API::Registry 0.12 qw( :KEY_ :HKEY_ :REG_ );

#Optional other modules:
use vars qw( $_NoMoreItems $_FileNotFound $_TooSmall $_MoreData $_SetDualVar );

if(  eval { require Win32::WinError }  ) {
    $_NoMoreItems= Win32::WinError::constant("ERROR_NO_MORE_ITEMS",0);
    $_FileNotFound= Win32::WinError::constant("ERROR_FILE_NOT_FOUND",0);
    $_TooSmall= Win32::WinError::constant("ERROR_INSUFFICIENT_BUFFER",0);
    $_MoreData= Win32::WinError::constant("ERROR_MORE_DATA",0);
} else {
    $_NoMoreItems= "^No more data";
    $_FileNotFound= "cannot find the file";
    $_TooSmall= " data area passed to ";
    $_MoreData= "^more data is avail";
}
if(  $_SetDualVar= eval { require SetDualVar }  ) {
    import SetDualVar;
}


#Implementation details:
#    When opened:
#	HANDLE		long; actual handle value
#	MACHINE		string; name of remote machine ("" if local)
#	PATH		list ref; machine-relative full path for this key:
#			["LMachine","System","Disk"]
#			["HKEY_LOCAL_MACHINE","System","Disk"]
#	DELIM		char; delimeter used to separate subkeys (def="\\")
#	OS_DELIM	char; always "\\" for Win32
#	ACCESS		long; usually KEY_ALL_ACCESS, perhaps KEY_READ, etc.
#	ROOTS		string; var name for "Lmachine"->HKEY_LOCAL_MACHINE map
#	FLAGS		int; bits to control certain options
#    Often:
#	VALUES		ref to list of value names (data/type never cached)
#	SUBKEYS		ref to list of subkey names
#	SUBCLASSES	ref to list of subkey classes
#	SUBTIMES	ref to list of subkey write times
#	MEMBERS		ref to list of subkey_name.DELIM's, DELIM.value_name's
#	MEMBHASH	hash ref to with MEMBERS as keys and 1's as values
#    Once Key "Info" requested:
#	Class CntSubKeys CntValues MaxSubKeyLen MaxSubClassLen
#	MaxValNameLen MaxValDataLen SecurityLen LastWrite
#    When tied to a hash and iterating over key values:
#	PREVIDX		int; index of last MEMBERS element return
#    When tied to a hash and iterating over key values:
#	UNLOADME	list ref; information about Load()ed key


#Package-local variables:

# Option flag bits:
use vars qw( $Flag_ArrVal $Flag_FastDel );
$Flag_ArrVal= 1;
$Flag_FastDel= 2;

# Short-hand for HKEY_* constants:
use vars qw( $RegObj %_Roots %RegHash $Registry );
%_Roots= (
    "Classes" =>	HKEY_CLASSES_ROOT,
    "CUser" =>		HKEY_CURRENT_USER,
    "LMachine" =>	HKEY_LOCAL_MACHINE,
    "Users" =>		HKEY_USERS,
    "PerfData" =>	HKEY_PERFORMANCE_DATA,	# Too picky to be useful
    "CConfig" =>	HKEY_CURRENT_CONFIG,
    "DynData" =>	HKEY_DYN_DATA,		# Too picky to be useful
);

# Basic master Registry object:
$RegObj= {};
@$RegObj{qw( HANDLE MACHINE PATH DELIM OS_DELIM ACCESS FLAGS ROOTS )}= (
    "NONE", "", [], "\\", "\\", KEY_READ|KEY_WRITE, 0, "${PACK}::_Roots" );
bless $RegObj;

# Fill cache for master Registry object:
@$RegObj{qw( VALUES SUBKEYS SUBCLASSES SUBTIMES )}= (
    [],  [ keys(%_Roots) ],  [],  []  );
grep( s#$#$RegObj->{DELIM}#,
  @{ $RegObj->{MEMBERS}= [ @{$RegObj->{SUBKEYS}} ] } );
@$RegObj{qw( Class MaxSubKeyLen MaxSubClassLen MaxValNameLen
  MaxValDataLen SecurityLen LastWrite CntSubKeys CntValues )}=
    ( "", 0, 0, 0, 0, 0, 0, 0, 0 );

# Create master Registry tied hash:
$RegObj->Tie( \%RegHash );

# Create master Registry combination object and tied hash reference:
$Registry= \%RegHash;
bless $Registry;


# Preloaded methods go here.


use vars qw( @_new_Opts %_new_Opts );
@_new_Opts= qw( ACCESS DELIM MACHINE );
@_new_Opts{@_new_Opts}= (1) x @_new_Opts;

sub _new
{
  my $this= shift( @_ );
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my $class= ref($this) || $this;
  my $self= {};
  my( $handle, $rpath, $opts )= @_;
    if(  @_ < 2  ||  "ARRAY" ne ref($rpath)  ||  3 < @_
     ||  3 == @_ && "HASH" ne ref($opts)  ) {
	croak "Usage:  ${PACK}->_new( \$handle, \\\@path, {OPT=>VAL,...} );\n",
	      "  options: @_new_Opts\nCalled";
    }
    @$self{qw( HANDLE PATH )}= ( $handle, $rpath );
    @$self{qw( MACHINE ACCESS DELIM OS_DELIM ROOTS FLAGS )}=
      ( $this->Machine, $this->Access, $this->Delimeter,
        $this->OS_Delimeter, $this->_Roots, $this->_Flags );
    if(  ref($opts)  ) {
      my @err= grep( ! $_new_Opts{$_}, keys(%$opts) );
	@err  and  croak "${PACK}->_new:  Invalid options (@err)";
	@$self{ keys(%$opts) }= values(%$opts);
    }
    bless $self, $class;
    return $self;
}


sub _split
{
  my $self= shift( @_ );
    $self= tied(%$self)  if  tied(%$self);
  my $path= shift( @_ );
  my $delim= @_ ? shift(@_) : $self->Delimeter;
  my $list= [ split( /\Q$delim/, $path ) ];
    $list;
}


sub _rootKey
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $keyPath= shift(@_);
  my $delim= @_ ? shift(@_) : $self->Delimeter;
  my( $root, $subPath );
    if(  "ARRAY" eq ref($keyPath)  ) {
	$subPath= $keyPath;
    } else {
	$subPath= $self->_split( $keyPath, $delim );
    }
    $root= shift( @$subPath );
    if(  $root =~ /^HKEY_/  ) {
      my $handle= Win32API::Registry::constant($root,0);
	$handle  or  croak "Invalid HKEY_ constant ($root): $!";
	return( $self->_new( $handle, [$root], {DELIM=>$delim} ),
	        $subPath );
    } elsif(  $root =~ /^([-+]|0x)?\d/  ) {
	return( $self->_new( $root, [sprintf("0x%lX",$root)],
			     {DELIM=>$delim} ),
		$subPath );
    } else {
      my $roots= $self->Roots;
	if(  $roots->{$root}  ) {
	    return( $self->_new( $roots->{$root}, [$root], {DELIM=>$delim} ),
	            $subPath );
	}
	croak "No such root key ($root)";
    }
}


sub _open
{
  my $this= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my $subPath= shift(@_);
  my $sam= @_ ? shift(@_) : $this->Access;
  my $subKey= join( $this->OS_Delimeter, @$subPath );
  my $handle= 0;
    $this->RegOpenKeyEx( $subKey, 0, $sam, $handle )
      or  return wantarray ? () : undef;
    return  $this->_new( $handle, [ @{$this->_Path}, @$subPath ],
			 { ACCESS=>$sam } );
}


sub ObjectRef
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    $self;
}


sub _connect
{
  my $this= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my $subPath= pop(@_);
    $subPath= $this->_split( $subPath )   unless  ref($subPath);
  my $machine= @_ ? shift(@_) : shift(@$subPath);
  my $handle= 0;
  my( $temp )= $this->_rootKey( [@$subPath] );
    $temp->RegConnectRegistry( $machine, $temp->Handle, $handle )
      or  return wantarray ? () : undef;
  my $self= $this->_new( $handle, [shift(@$subPath)], {MACHINE=>$machine} );
    ( $self, $subPath );
}


use vars qw( @Connect_Opts %Connect_Opts );
@Connect_Opts= qw(Access Delimeter);
@Connect_Opts{@Connect_Opts}= (1) x @Connect_Opts;

sub Connect
{
  my $this= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my( $machine, $key, $opts )= @_;
  my $delim= "";
  my $sam;
  my $subPath;
    if(  @_ < 2  ||  3 < @_
     ||  3 == @_ && "HASH" ne ref($opts)  ) {
	croak "Usage:  \$obj= ${PACK}->Connect(",
	      " \$Machine, \$subKey, { OPT=>VAL,... } );\n",
	      "  options: @Connect_Opts\nCalled";
    }
    if(  ref($opts)  ) {
      my @err= grep( ! $Connect_Opts{$_}, keys(%$opts) );
	@err  and  croak "${PACK}->Connect:  Invalid options (@err)";
    }
    $delim= "$opts->{Delimeter}"  if  defined($opts->{Delimeter});
    $delim= $this->Delimeter   if  "" eq $delim;
    $sam= defined($opts->{Access}) ? $opts->{Access} : $this->Access;
    $sam= Win32API::Registry::constant($sam,0)   if  $sam =~ /^KEY_/;
    ( $this, $subPath )= $this->_connect( $machine, $key );
    return wantarray ? () : undef   unless  defined($this);
  my $self= $this->_open( $subPath, $sam );
    return wantarray ? () : undef   unless  defined($self);
    $self->Delimeter( $delim );
    return $self;
}


#$key= new Tie::Registry "LMachine/System/Disk";
#$key= new Tie::Registry "//Server1/LMachine/System/Disk";
#Tie::Registry->new( HKEY_LOCAL_MACHINE, {DELIM=>"/",ACCESS=>KEY_READ} );
#Tie::Registry->new( [ HKEY_LOCAL_MACHINE, ".../..." ], {DELIM=>$DELIM} );
#$key->new( ... );

use vars qw( @new_Opts %new_Opts );
@new_Opts= qw(Access Delimeter);
@new_Opts{@new_Opts}= (1) x @new_Opts;

sub new
{
  my $this= shift( @_ );
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my( $subKey, $opts )= @_;
  my $delim= "";
  my $dlen;
  my $sam;
  my $subPath;
    if(  @_ < 1  ||  2 < @_
     ||  2 == @_ && "HASH" ne ref($opts)  ) {
	croak "Usage:  \$obj= ${PACK}->new( \$subKey, { OPT=>VAL,... } );\n",
	      "  options: @new_Opts\nCalled";
    }
    if(  defined($opts)  ) {
      my @err= grep( ! $new_Opts{$_}, keys(%$opts) );
	@err  and  die "${PACK}->new:  Invalid options (@err)";
    }
    $delim= "$opts->{Delimeter}"  if  defined($opts->{Delimeter});
    $delim= $this->Delimeter   if  "" eq $delim;
    $dlen= length($delim);
    $sam= defined($opts->{Access}) ? $opts->{Access} : $this->Access;
    $sam= Win32API::Registry::constant($sam,0)   if  $sam =~ /^KEY_/;
    if(  "ARRAY" eq ref($subKey)  ) {
	$subPath= $subKey;
	if(  "NONE" eq $this->Handle  ) {
	    ( $this, $subPath )= $this->_rootKey( $subPath );
	}
    } elsif(  $delim x 2 eq substr($subKey,0,2*$dlen)  ) {
      my $path= $this->_split( substr($subKey,2*$dlen), $delim );
      my $mach= shift(@$path);
	if(  ! @$path  ) {
	    return $this->_new( "NONE", $path,
				{MACHINE=>$mach,DELIM=>$delim} );
	}
	( $this, $subPath )= $this->_connect( $mach, $path );
	return wantarray ? () : undef   if  ! defined($this);
	if(  0 == @$subPath  ) {
	    $this->Delimeter( $delim );
	    return $this;
	}
    } elsif(  $delim eq substr($subKey,0,$dlen)  ) {
	( $this, $subPath )= $this->_rootKey( substr($subKey,$dlen), $delim );
    } elsif(  "NONE" eq $this->Handle  ) {
      my( $mach )= $this->Machine;
	if(  $mach  ) {
	    ( $this, $subPath )= $this->_connect( $mach, $subKey );
	} else {
	    ( $this, $subPath )= $this->_rootKey( $subKey, $delim );
	}
    } else {
	$subPath= $this->_split( $subKey, $delim );
    }
    return wantarray ? () : undef   unless  defined($this);
    if(  0 == @$subPath  &&  $sam == $this->Access  ) {
	$this->Delimeter( $delim );
	return $this;
    }
  my $self= $this->_open( $subPath, $sam );
    return wantarray ? () : undef   unless  defined($self);
    $self->Delimeter( $delim );
    return $self;
}


sub Open
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    $self->new( @_ );
}


sub Flush
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$key->Flush;";
  my( @flush )= qw( VALUES SUBKEYS SUBCLASSES SUBTIMES MEMBERS Class
		    CntSubKeys CntValues MaxSubKeyLen MaxSubClassLen
		    MaxValNameLen MaxValDataLen SecurityLen LastWrite
		    PREVIDX );
    return 0   if  "NONE" eq $self->Handle;
    delete( @$self{@flush} );
    $self->RegFlushKey;
}


sub _DualVal
{
  my( $hRef, $num )= @_;
    if(  $_SetDualVar  &&  $$hRef{$num}  ) {
	&SetDualVar( $num, "$$hRef{$num}", 0+$num );
    }
    $num;
}


use vars qw( @_RegDataTypes %_RegDataTypes );
@_RegDataTypes= qw( REG_NONE REG_SZ REG_EXPAND_SZ REG_BINARY
		    REG_DWORD_LITTLE_ENDIAN REG_DWORD_BIG_ENDIAN
		    REG_DWORD REG_LINK REG_MULTI_SZ REG_RESOURCE_LIST
		    REG_FULL_RESOURCE_DESCRIPTOR
		    REG_RESOURCE_REQUIREMENTS_LIST );
# Make sure REG_DWORD appears _after_ other REG_DWORD_* items above.
foreach(  @_RegDataTypes  ) {
    $_RegDataTypes{Win32API::Registry::constant($_,0)}= $_;
}

sub GetValue
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    1 == @_  or  croak "Usage:  (\$data,\$type)= \$key->GetValue('ValName');";
  my( $valName )= @_;
  my( $valType, $valData, $dLen )= (0,"",0);
    return wantarray ? () : undef   if  "NONE" eq $self->Handle;
    $self->RegQueryValueEx( $valName, [], $valType, $valData,
      $dLen= ( defined($self->{MaxValDataLen}) ? $self->{MaxValDataLen} : 0 )
    )  or  return wantarray ? () : undef;
    if(  REG_DWORD == $valType  ) {
	$valData= sprintf "0x%08.8lX", unpack("L",$valData)
    } elsif(  $_SetDualVar  &&  REG_BINARY == $valType
          &&  length($valData) <= 4  ) {
	&SetDualVar( $valData, $valData, hex reverse unpack("h*",$valData) );
    }
    if(  wantarray  ) {
	return(  $valData,  _DualVal( \%_RegDataTypes, $valType )  );
    } else {
	return $valData;
    }
}


sub _NoMoreItems
{
    $_NoMoreItems =~ /^\d/
       ?  $^E == $_NoMoreItems
       :  $^E =~ /$_NoMoreItems/io;
}


sub _FileNotFound
{
    $_FileNotFound =~ /^\d/
       ?  $^E == $_FileNotFound
       :  $^E =~ /$_FileNotFound/io;
}


sub _TooSmall
{
    $_TooSmall =~ /^\d/
       ?  $^E == $_TooSmall
       :  $^E =~ /$_TooSmall/io;
}


sub _MoreData
{
    $_MoreData =~ /^\d/
       ?  $^E == $_MoreData
       :  $^E =~ /$_MoreData/io;
}


sub _enumValues
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my( @names )= ();
  my $pos= 0;
  my $name= "";
  my $nlen= 1+$self->Information("MaxValNameLen");
    while(  $self->RegEnumValue($pos++,$name,$nlen,[],[],[],[])  ) {
	push( @names, $name );
    }
    if(  ! _NoMoreItems()  ) {
	return wantarray ? () : undef;
    }
    $self->{VALUES}= \@names;
    1;
}


sub ValueNames
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \@names= \$key->ValueNames;";
    $self->_enumValues   unless  $self->{VALUES};
    return @{$self->{VALUES}};
}


sub _enumSubKeys
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my( @subkeys, @classes, @times )= ();
  my $pos= 0;
  my( $subkey, $class, $time )= ("","","");
  my( $namSiz, $clsSiz )= $self->Information(
			    qw( MaxSubKeyLen MaxSubClassLen ));
    $namSiz++;  $clsSiz++;
    while(  $self->RegEnumKeyEx(
	      $pos++, $subkey, $namSiz, [], $class, $clsSiz, $time )  ) {
	push( @subkeys, $subkey );
	push( @classes, $class );
	push( @times, $time );
    }
    if(  ! _NoMoreItems()  ) {
	return wantarray ? () : undef;
    }
    $self->{SUBKEYS}= \@subkeys;
    $self->{SUBCLASSES}= \@classes;
    $self->{SUBTIMES}= \@times;
    1;
}


sub SubKeyNames
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \@names= \$key->SubKeyNames;";
    $self->_enumSubKeys   unless  $self->{SUBKEYS};
    return @{$self->{SUBKEYS}};
}


sub SubKeyClasses
{
  my $self= shift(@_);
    @_  and  croak "Usage:  \@classes= \$key->SubKeyClasses;";
    $self->_enumSubKeys   unless  $self->{SUBCLASSES};
    return @{$self->{SUBCLASSES}};
}


sub SubKeyTimes
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \@times= \$key->SubKeyTimes;";
    $self->_enumSubKeys   unless  $self->{SUBTIMES};
    return @{$self->{SUBTIMES}};
}


sub _MemberNames
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$arrayRef= \$key->_MemberNames;";
    if(  ! $self->{MEMBERS}  ) {
	$self->_enumValues   unless  $self->{VALUES};
	$self->_enumSubKeys   unless  $self->{SUBKEYS};
      my( @members )= (  map( $_.$self->{DELIM}, @{$self->{SUBKEYS}} ),
			 map( $self->{DELIM}.$_, @{$self->{VALUES}} )  );
	$self->{MEMBERS}= \@members;
    }
    return $self->{MEMBERS};
}


sub _MembersHash
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$hashRef= \$key->_MembersHash;";
    if(  ! $self->{MEMBHASH}  ) {
      my $aRef= $self->_MemberNames;
	$self->{MEMBHASH}= {};
	@{$self->{MEMBHASH}}{@$aRef}= (1) x @$aRef;
    }
    return $self->{MEMBHASH};
}


sub MemberNames
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \@members= \$key->MemberNames;";
    return @{$self->_MemberNames};
}


sub Information
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my( $time, $nkeys, $nvals, $xsec, $xkey, $xcls, $xname, $xdata )=
      ("",0,0,0,0,0,0,0);
  my $clen= 8;
    if(  ! $self->RegQueryInfoKey( [], [], $nkeys, $xkey, $xcls,
				   $nvals, $xname, $xdata, $xsec, $time )  ) {
	return wantarray ? () : undef;
    }
    if(  defined($self->{Class})  ) {
	$clen= length($self->{Class});
    } else {
	$self->{Class}= "";
    }
    while(  ! $self->RegQueryInfoKey( $self->{Class}, $clen,
				      [],[],[],[],[],[],[],[],[])
        &&  _MoreData  ) {
	$clen *= 2;
    }
  my( %info );
    @info{ qw( LastWrite CntSubKeys CntValues SecurityLen
	       MaxValDataLen MaxSubKeyLen MaxSubClassLen MaxValNameLen )
    }=       ( $time,    $nkeys,    $nvals,   $xsec,
               $xdata,       $xkey,       $xcls,         $xname );
    if(  @_  ) {
      my( %check );
	@check{keys(%info)}= keys(%info);
      my( @err )= grep( ! $check{$_}, @_ );
	if(  @err  ) {
	    croak "${PACK}::Information- Invalid info requested (@err)";
	}
	return @info{@_};
    } else {
	return %info;
    }
}


sub Delimeter
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    $self= $RegObj   unless  ref($self);
  my( $oldDelim )= $self->{DELIM};
    if(  1 == @_  &&  "" ne "$_[0]"  ) {
	delete $self->{MEMBERS};
	delete $self->{MEMBHASH};
	$self->{DELIM}= "$_[0]";
    } elsif(  0 != @_  ) {
	croak "Usage:  \$oldDelim= \$key->Delimeter(\$newDelim);";
    }
    $oldDelim;
}


sub Handle
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$handle= \$key->Handle;";
    $self= $RegObj   unless  ref($self);
    $self->{HANDLE};
}


sub Path
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$path= \$key->Path;";
  my $delim= $self->{DELIM};
    $self= $RegObj   unless  ref($self);
    if(  "" eq $self->{MACHINE}  ) {
	$delim . join( $delim, @{$self->{PATH}} ) . $delim;
    } else {
	$delim x 2
	  . join( $delim, $self->{MACHINE}, @{$self->{PATH}} )
	  . $delim;
    }
}


sub _Path
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$arrRef= \$key->_Path;";
    $self= $RegObj   unless  ref($self);
    $self->{PATH};
}


sub Machine
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$machine= \$key->Machine;";
    $self= $RegObj   unless  ref($self);
    $self->{MACHINE};
}


sub Access
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$access= \$key->Access;";
    $self= $RegObj   unless  ref($self);
    $self->{ACCESS};
}


sub OS_Delimeter
{
  my $self= shift(@_);
    @_  and  croak "Usage:  \$backslash= \$key->OS_Delimeter;";
    $self->{OS_DELIM};
}


sub _Roots
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$varName= \$key->_Roots;";
    $self= $RegObj   unless  ref($self);
    $self->{ROOTS};
}


sub Roots
{
  my $self= shift(@_);
    @_  and  croak "Usage:  \$hashRef= \$key->Roots;";
    $self= $RegObj   unless  ref($self);
    eval "\\%$self->{ROOTS}";
}


sub TIEHASH
{
  my( $this )= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my( $key )= @_;
    if(  1 == @_  &&  ref($key)  &&  ref($key) =~ /[^A-Z]/  ) {
	return $key;
    }
    return $this->new( @_ );
}


sub Tie
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my( $hRef )= @_;
    if(  1 != @_  ||  ! ref($hRef)  ||  "$hRef" !~ /(^|=)HASH\(/  ) {
	croak "Usage: \$key->Tie(\\\%hash);";
    }
    tie %$hRef, ref($self), $self;
}


sub TiedRef
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $hRef= @_ ? shift(@_) : {};
    return wantarray ? () : undef   if  ! defined($self);
    $self->Tie($hRef);
    bless $hRef, ref($self);
    $hRef;
}


sub _Flags
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $oldFlags= $self->{FLAGS};
    if(  1 == @_  ) {
	$self->{FLAGS}= shift(@_);
    } elsif(  0 != @_  ) {
	croak "Usage:  \$oldBits= \$key->_Flags(\$newBits);";
    }
    $oldFlags;
}


sub ArrayValues
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $oldFlag= $Flag_ArrVal == ( $Flag_ArrVal & $self->{FLAGS} );
    if(  1 == @_  ) {
      my $bool= shift(@_);
	if(  $bool  ) {
	    $self->{FLAGS} |= $Flag_ArrVal;
	} else {
	    $self->{FLAGS} &= ~$Flag_ArrVal;
	}
    } elsif(  0 != @_  ) {
	croak "Usage:  \$oldBool= \$key->ArrayValues(\$newBool);";
    }
    $oldFlag;
}


sub FastDelete
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $oldFlag= $Flag_FastDel == ( $Flag_FastDel & $self->{FLAGS} );
    if(  1 == @_  ) {
      my $bool= shift(@_);
	if(  $bool  ) {
	    $self->{FLAGS} |= $Flag_FastDel;
	} else {
	    $self->{FLAGS} &= ~$Flag_FastDel;
	}
    } elsif(  0 != @_  ) {
	croak "Usage:  \$oldBool= \$key->FastDelete(\$newBool);";
    }
    $oldFlag;
}


sub _parseTiedEnt
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $ent= shift(@_);
  my $delim= shift(@_);
  my $dlen= length( $delim );
  my $parent= @_ ? shift(@_) : 0;
  my $off;
    if(  $delim x 2 eq substr($ent,0,2*$dlen)  &&  "NONE" eq $self->Handle  ) {
	if(  0 <= ( $off= index( $ent, $delim x 2, 2*$dlen ) )  ) {
	    (  substr( $ent, 0, $off ),  substr( $ent, 2*$dlen+$off )  );
	} elsif(  $delim eq substr($ent,-$dlen)  ) {
	    ( substr($ent,0,-$dlen) );
	} elsif(  2*$dlen <= ( $off= rindex( $ent, $delim ) )  ) {
	    (  substr( $ent, 0, $off ),  undef,  substr( $ent, $dlen+$off )  );
	} elsif(  $parent  ) {
	    ();
	} else {
	    ( $ent );
	}
    } elsif(  $delim eq substr($ent,0,$dlen)  &&  "NONE" ne $self->Handle  ) {
	( undef, substr($ent,$dlen) );
    } elsif(  $self->{MEMBERS}  &&  $self->_MembersHash->{$ent}  ) {
	( substr($ent,0,-$dlen) );
    } elsif(  0 <= ( $off= index( $ent, $delim x 2 ) )  ) {
	(  substr( $ent, 0, $off ),  substr( $ent, 2*$dlen+$off ) );
    } elsif(  $delim eq substr($ent,-$dlen)  ) {
	if(  $parent
	 &&  0 <= ( $off= rindex( $ent, $delim, length($ent)-2*$dlen ) )  ) {
	    (  substr($ent,0,$off),  undef,  undef,
	       substr($ent,$dlen+$off,-$dlen)  );
	} else {
	    ( substr($ent,0,-$dlen) );
	}
    } elsif(  0 <= ( $off= rindex( $ent, $delim ) )  ) {
	(  substr( $ent, 0, $off ),  undef,  substr( $ent, $dlen+$off )  );
    } else {
	( undef, undef, $ent );
    }
}


sub FETCH
{
  my $self= shift(@_);
  my $ent= shift(@_);
  my $delim= $self->Delimeter;
  my( $key, $val, $ambig )= $self->_parseTiedEnt( $ent, $delim, 0 );
  my $sub;
    if(  defined($key)  ) {
	if(  defined($self->{MEMBHASH})
	 &&  $self->{MEMBHASH}->{$key.$delim}
	 &&  0 <= index($key,$delim)  ) {
	    return wantarray ? () : undef
	      unless  $sub= $self->new( $key,
			      {"Delimeter"=>$self->OS_Delimeter} );
	    $sub->Delimeter($delim);
	} else {
	    return wantarray ? () : undef
	      unless  $sub= $self->new( $key );
	}
    } else {
	$sub= $self;
    }
    if(  defined($val)  ) {
	$self->ArrayValues ? [ $sub->GetValue( $val ) ]
			   : $sub->GetValue( $val );
    } elsif(  ! defined($ambig)  ) {
	$sub->TiedRef;
    } elsif(  defined($key)  ) {
	$sub->FETCH(  $ambig  );
    } elsif(  "" eq $ambig  ) {
	$self->ArrayValues ? [ $sub->GetValue( $ambig ) ]
			   : $sub->GetValue( $ambig );
    } else {
      my $data= [ $sub->GetValue( $ambig ) ];
	return $sub->ArrayValues ? $data : $$data[0]
	  if  0 != @$data;
	$data= $sub->new( $ambig );
	return defined($data) ? $data->TiedRef : wantarray ? () : undef;
    }
}


#sub AskDel
#{
#  my $self= shift(@_);
#  my( $kv, $name )= @_;
#    print STDERR "Delete ", $self->Path, "'s $kv `$name'? ";
#    <STDIN> =~ /^y/i;
#}
sub DELETE
{
  my $self= shift(@_);
  my $ent= shift(@_);
  my $delim= $self->Delimeter;
  my( $key, $val, $ambig, $subkey )= $self->_parseTiedEnt( $ent, $delim, 1 );
  my $sub;
  my $fast= $self->FastDelete;
  my $old= 1;	# Value returned if FastDelete is set.
    if(  defined($key)
     &&  ( defined($val) || defined($ambig) || defined($subkey) )  ) {
	return wantarray ? () : undef
	  unless  $sub= $self->new( $key );
    } else {
	$sub= $self;
    }
    if(  defined($val)  ) {
	$old= $sub->GetValue($val)   unless  $fast;
#	$sub->AskDel("value",$val)  &&
	$sub->RegDeleteValue( $val );
    } elsif(  defined($subkey)  ) {
	if(  ! $fast  and  $old= $sub->FETCH( $subkey.$delim )  )
	    {   my $copy= {};   %$copy= %$old;   $old= $copy;   }
#	$sub->AskDel("key",$subkey)  &&
	$sub->RegDeleteKey( $subkey );
    } elsif(  defined($ambig)  ) {
	if(  defined($key)  ) {
	    $old= $sub->DELETE($ambig);
	} else {
	    $old= $sub->GetValue($ambig);#  unless  $fast;
	    if(  defined( $old )  ) {
#		$sub->AskDel("value",$ambig) &&
		$sub->RegDeleteValue( $ambig );
	    } else {
		if(  ! $fast  and  $old= $sub->FETCH( $ambig.$delim )  )
		    {   my $copy= {};   %$copy= %$old;   $old= $copy;   }
#		$sub->AskDel("key",$ambig) &&
		$sub->RegDeleteKey( $ambig );
	    }
	}
    } elsif(  defined($key)  ) {
	if(  ! $fast  and  $old= $sub->FETCH( $key.$delim )  )
	    {   my $copy= {};   %$copy= %$old;   $old= $copy;   }
#	$sub->AskDel("key",$key) &&
	$sub->RegDeleteKey( $key );
    } else {
	croak "${PACK}->DELETE:  Key ($ent) can never be deleted";
    }
    $old;
}


sub SetValue
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my $name= shift(@_);
  my $data= shift(@_);
  my( $type )= @_;
  my $size= length($data);
    if(  ! defined($type)  ) {
	if(  "ARRAY" eq ref($data)  ) {
	    ( $data, $type )= @$data;
	    $size= length($data);
	} else {
	    $type= REG_SZ;
	}
    }
    if(  REG_MULTI_SZ == $type  &&  "ARRAY" eq ref($data)  ) {
	$data= pack(  "a*" x (1+@$data),  map( $_."\0", @$data, "" )  );
	$size= length($data);
    } elsif(  REG_SZ == $type  ||  REG_EXPAND_SZ == $type  ) {
	$size++	 unless  "\0" eq substr($data,0,-1);	# For the trailing '\0'
    } elsif(  REG_DWORD == $type  &&  $data =~ /^0x[0-9a-fA-F]{3,}$/  ) {
	$data= pack( "L", $data );
    }
    # We could to $data=pack("l",$data) [or "L"] for REG_DWORD but I
    # see no nice way to always destinguish when to do this or not.
    $self->RegSetValueEx( $name, 0, $type, $data, $size );
}


sub StoreKey
{
  my $this= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my $subKey= shift(@_);
  my $data= shift(@_);
  my $ent;
  my $self;
    if(  ! ref($data)  ||  "$data" !~ /(^|=)HASH/  ) {
	croak "${PACK}->StoreKey:  Subkey data must be a HASH reference";
    }
    if(  defined( $$data{""} )  &&  "HASH" eq ref($$data{""})  ) {
	$self= $this->CreateKey( $subKey, delete $$data{""} );
    } else {
	$self= $this->CreateKey( $subKey );
    }
    return wantarray ? () : undef   if  ! defined($self);
    foreach $ent (  keys(%$data)  ) {
	return wantarray ? () : undef
	  unless  $self->STORE( $ent, $$data{$ent} );
    }
    $self;
}


# = { "" => {OPT=>VAL}, "val"=>[], "key"=>{} } creates a new key
# = "string" creates a new REG_SZ value
# = [ data, type ] creates a new value
sub STORE
{
  my $self= shift(@_);
  my $ent= shift(@_);
  my $data= shift(@_);
  my $delim= $self->Delimeter;
  my( $key, $val, $ambig, $subkey )= $self->_parseTiedEnt( $ent, $delim, 1 );
  my $sub;
    if(  defined($key)
     &&  ( defined($val) || defined($ambig) || defined($subkey) )  ) {
	return wantarray ? () : undef
	  unless  $sub= $self->new( $key );
    } else {
	$sub= $self;
    }
    if(  defined($val)  ) {
	croak "${PACK}->STORE:  Value data cannot be a HASH reference"
	  if  ref($data)  &&  "$data" =~ /(^|=)HASH/;
	$sub->SetValue( $val, $data );
    } elsif(  defined($subkey)  ) {
	croak "${PACK}->STORE:  Subkey data must be a HASH reference"
	  unless  ref($data)  &&  "$data" =~ /(^|=)HASH/;
	$sub->StoreKey( $subkey, $data );
    } elsif(  defined($ambig)  ) {
	if(  ref($data)  &&  "$data" =~ /(^|=)HASH/  ) {
	    $sub->StoreKey( $ambig, $data );
	} else {
	    $sub->SetValue( $ambig, $data );
	}
    } elsif(  defined($key)  ) {
	croak "${PACK}->STORE:  Subkey data must be a HASH reference"
	  unless  ref($data)  &&  "$data" =~ /(^|=)HASH/;
	$sub->StoreKey( $key, $data );
    } else {
	croak "${PACK}->STORE:  Key ($ent) can never be created nor set";
    }
}


sub EXISTS
{
  my $self= shift(@_);
  my $ent= shift(@_);
    defined( $self->FETCH($ent) );
}


sub FIRSTKEY
{
  my $self= shift(@_);
  my $members= $self->_MemberNames;
    $self->{PREVIDX}= 0;
    @{$members} ? $members->[0] : undef;
}


sub NEXTKEY
{
  my $self= shift(@_);
  my $prev= shift(@_);
  my $idx= $self->{PREVIDX};
  my $members= $self->_MemberNames;
    if(  ! defined($idx)  ||  $prev ne $members->[$idx]  ) {
	$idx= 0;
	while(  $idx < @$members  &&  $prev ne $members->[$idx]  ) {
	    $idx++;
	}
    }
    $self->{PREVIDX}= ++$idx;
    $members->[$idx];
}


sub DESTROY
{
  my $self= shift(@_);
    return   if  tied(%$self);
  my $unload= $self->{UNLOADME};
  my $debug= $ENV{DEBUG_TIE_REGISTRY};
    if(  defined($debug)  ) {
	if(  1 < $debug  ) {
	  my $hand= $self->Handle;
	    carp "${PACK} destroying ", $self->Path, " (",
		 "NONE" eq $hand ? $hand : sprintf("0x%lX",$hand), ")";
	} else {
	    warn "${PACK} destroying ", $self->Path, ".\n";
	}
    }
    $self->RegCloseKey
      unless  "NONE" eq $self->Handle;
    if(  defined($unload)  ) {
	$self->UnLoad;
	## carp "Never unloaded Tie::Registry::Load($$unload[2])";
    }
}


use vars qw( @CreateKey_Opts %CreateKey_Opts );
@CreateKey_Opts= qw( Access Class Options Delimeter Security Volatile Backup );
@CreateKey_Opts{@CreateKey_Opts}= (1) x @CreateKey_Opts;

sub CreateKey
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
  my( $subKey, $opts )= @_;
  my( $sam )= $self->Access;
  my( $delim )= $self->Delimeter;
  my( $class )= "";
  my( $flags )= 0;
  my( $secure )= [];
  my( $garb )= 0;
  my( $result )= \$garb;
  my( $handle )= 0;
  my( $subPath );
    if(  @_ < 1  ||  2 < @_
     ||  2 == @_ && "HASH" ne ref($opts)  ) {
	croak "Usage:  \$new= \$old->CreateKey( \$subKey, {OPT=>VAL,...} );\n",
	      "  options: @CreateKey_Opts\nCalled";
    }
    if(  defined($opts)  ) {
	$sam= $opts->{"Access"}   if  defined($opts->{"Access"});
	$class= $opts->{Class}   if  defined($opts->{Class});
	$flags= $opts->{Options}   if  defined($opts->{Options});
	$delim= $opts->{"Delimeter"}   if  defined($opts->{"Delimeter"});
	$secure= $opts->{Security}   if  defined($opts->{Security});
	if(  defined($opts->{Disposition})  ) {
	    "SCALAR" eq ref($opts->{Disposition})
	      or  croak "${PACK}->CreateKey option `Disposition'",
			" must provide a scalar reference";
	    $result= $opts->{Disposition};
	}
	$result= ${$opts->{Disposition}}   if  defined($opts->{Disposition});
	if(  0 == $flags  ) {
	    $flags |= REG_OPTION_VOLATILE
	      if  defined($opts->{Volatile})  &&  $opts->{Volatile};
	    $flags |= REG_OPTION_BACKUP_RESTORE
	      if  defined($opts->{Backup})  &&  $opts->{Backup};
	}
    }
    $self->RegCreateKeyEx( $subKey, 0, $class, $flags, $sam,
			   $secure, $handle, $$result )
      or  return wantarray ? () : undef;
  my $new= $self->_new( $handle, $self->_split($subKey,$delim) );
    $new->{ACCESS}= $sam;
    $new->{DELIM}= $delim;
    return $new;
}


use vars qw( $Load_Cnt @Load_Opts %Load_Opts );
$Load_Cnt= 0;
@Load_Opts= qw(NewSubKey);
@Load_Opts{@Load_Opts}= (1) x @Load_Opts;

sub Load
{
  my $this= shift(@_);
    $this= tied(%$this)  if  ref($this)  &&  tied(%$this);
  my( $file, $opts )= @_;
  my $subKey;
    @_ < 1  ||  2 < @_  ||  2 == @_ && "HASH" ne ref($opts)  and  croak
      "Usage:  \$key= ${PACK}->Load( \$fileName, {OPT=>VAL...} );\n",
      "  options: @Load_Opts @new_Opts\nCalled";
    if(  defined($opts)  &&  exists($opts->{NewSubKey})  ) {
	$subKey= delete $opts->{NewSubKey};
    } else {
	( $this )= $this->_rootKey( "LMachine" );	# or "Users"
	$subKey= "PerlTie:$$." . ++$Load_Cnt;
    }
    $this->RegLoadKey( $subKey, $file )
      or  return wantarray ? () : undef;
  my $self= $this->new( $subKey, defined($opts) ? $opts : () );
    $self->{UNLOADME}= [ $this, $subKey, $file ];
    $self;
}


sub UnLoad
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    @_  and  croak "Usage:  \$key->UnLoad;";
  my $unload= $self->{UNLOADME};
    "ARRAY" eq ref($unload)
      or  croak "${PACK}->UnLoad called on a key which was not Load()ed";
  my( $obj, $subKey, $file )= @$unload;
    $self->RegCloseKey;
    Win32API::Registry::RegUnLoadKey( $obj->Handle, $subKey );
}


sub AllowSave
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    $self->AllowPriv( "SeBackupPrivilege", @_ );
}


sub AllowLoad
{
  my $self= shift(@_);
    $self= tied(%$self)  if  tied(%$self);
    $self->AllowPriv( "SeRestorePrivilege", @_ );
}


# RegNotifyChangeKeyValue( hKey, bWatchSubtree, iNotifyFilter, hEvent, bAsync )


sub RegCloseKey { my $self= shift(@_);
    Win32API::Registry::RegCloseKey $self->Handle, @_; }
sub RegConnectRegistry { my $self= shift(@_);
    Win32API::Registry::RegConnectRegistry @_; }
sub RegCreateKey { my $self= shift(@_);
    Win32API::Registry::RegCreateKey $self->Handle, @_; }
sub RegCreateKeyEx { my $self= shift(@_);
    Win32API::Registry::RegCreateKeyEx $self->Handle, @_; }
sub RegDeleteKey { my $self= shift(@_);
    Win32API::Registry::RegDeleteKey $self->Handle, @_; }
sub RegDeleteValue { my $self= shift(@_);
    Win32API::Registry::RegDeleteValue $self->Handle, @_; }
sub RegEnumKey { my $self= shift(@_);
    Win32API::Registry::RegEnumKey $self->Handle, @_; }
sub RegEnumKeyEx { my $self= shift(@_);
    Win32API::Registry::RegEnumKeyEx $self->Handle, @_; }
sub RegEnumValue { my $self= shift(@_);
    Win32API::Registry::RegEnumValue $self->Handle, @_; }
sub RegFlushKey { my $self= shift(@_);
    Win32API::Registry::RegFlushKey $self->Handle, @_; }
sub RegGetKeySecurity { my $self= shift(@_);
    Win32API::Registry::RegGetKeySecurity $self->Handle, @_; }
sub RegLoadKey { my $self= shift(@_);
    Win32API::Registry::RegLoadKey $self->Handle, @_; }
sub RegNotifyChangeKeyValue { my $self= shift(@_);
    Win32API::Registry::RegNotifyChangeKeyValue $self->Handle, @_; }
sub RegOpenKey { my $self= shift(@_);
    Win32API::Registry::RegOpenKey $self->Handle, @_; }
sub RegOpenKeyEx { my $self= shift(@_);
    Win32API::Registry::RegOpenKeyEx $self->Handle, @_; }
sub RegQueryInfoKey { my $self= shift(@_);
    Win32API::Registry::RegQueryInfoKey $self->Handle, @_; }
sub RegQueryMultipleValues { my $self= shift(@_);
    Win32API::Registry::RegQueryMultipleValues $self->Handle, @_; }
sub RegQueryValue { my $self= shift(@_);
    Win32API::Registry::RegQueryValue $self->Handle, @_; }
sub RegQueryValueEx { my $self= shift(@_);
    Win32API::Registry::RegQueryValueEx $self->Handle, @_; }
sub RegReplaceKey { my $self= shift(@_);
    Win32API::Registry::RegReplaceKey $self->Handle, @_; }
sub RegRestoreKey { my $self= shift(@_);
    Win32API::Registry::RegRestoreKey $self->Handle, @_; }
sub RegSaveKey { my $self= shift(@_);
    Win32API::Registry::RegSaveKey $self->Handle, @_; }
sub RegSetKeySecurity { my $self= shift(@_);
    Win32API::Registry::RegSetKeySecurity $self->Handle, @_; }
sub RegSetValue { my $self= shift(@_);
    Win32API::Registry::RegSetValue $self->Handle, @_; }
sub RegSetValueEx { my $self= shift(@_);
    Win32API::Registry::RegSetValueEx $self->Handle, @_; }
sub RegUnLoadKey { my $self= shift(@_);
    Win32API::Registry::RegUnLoadKey $self->Handle, @_; }
sub AllowPriv { my $self= shift(@_);
    Win32API::Registry::AllowPriv @_; }


# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__

=head1 NAME

Tie::Registry - Powerful and easy ways to manipulate a registry
[on Win32 for now].

=head1 SYNOPSIS

  use Tie::Registry;

  $Registry->SomeMethodCall(arg1,...);

  $subKey= $Registry->{"Key\\SubKey\\"};
  $valueData= $Registry->{"Key\\SubKey\\\\ValueName"};
  $Registry->{"Key\\SubKey\\"}= { "NewSubKey" => {...} };
  $Registry->{"Key\\SubKey\\\\ValueName"}= "NewValueData";
  $Registry->{"\\ValueName"}= [ pack("fmt",$data), REG_DATATYPE ];

=head1 EXAMPLES

  $Registry->Delimeter("/");
  $diskKey= $Registry->{"LMachine/System/Disk/"};
  $data= $key->{"/Information"};
  $remoteKey= $Registry->{"//ServerA/LMachine/System/"};
  $remoteData= $remoteKey->{"Disk//Information"};
  foreach $entry (  keys(%$key)  ) {
      ...
  }
  foreach $subKey (  $key->SubKeyNames  ) {
      ...
  }
  $key->AllowSave( 1 );
  $key->RegSaveKey( "C:/TEMP/DiskReg", [] );

=head1 DESCRIPTION

The C<Tie::Registry> module lets you manipulate the Registry via
objects [as in "object oriented"] or via tied hashes.  But you
will probably mostly use objects which are also references to tied
hashes that allow you to mix both access methods [as shown above].

Skip to the L<SUMMARY> section if you just want to dive in and start
using the Registry from Perl.

Accessing and manipulating the registry is extremely simple using
C<Tie::Registry>.  A single, simple expression can return you almost
any bit of information stored in the Registry.  C<Tie::Registry>
also gives you full access to the "raw" underlying API calls so that
you can do anything with the Registry in Perl that you could do in
C.  But the "simple" interface has been carefully designed to handle
almost all operations itself without imposing arbitrary limits while
providing sensible defaults so you can list only the parameters you
care about.

But first, an overview of the Registry itself.

=head2 The Registry

The Registry is a forest:  a collection of several tree structures.
The root of each tree is a key.  These root keys are identified by
predefined constants whose names start with "HKEY_".  Although all
keys have a few attributes associated with each [a class, a time
stamp, and security information], the most important aspect of keys
is that each can contain subkeys and can contain values.

Each subkey has a name:  a string which cannot be blank and cannot
contain the delimeter character [backslash: C<'\\'>] nor nul
[C<'\0'>].  Each subkey is also a key and so can contain subkeys
and values [and has a class, time stamp, and security information].

Each value has a name:  a string which E<can> be blank and can
contain any character except for nul, C<'\0'> [including the delimeter
character].  Each value also has data associated with it.  Each
value's data is a contiguous chunk of bytes, which is exactly what
a Perl string value is so Perl strings will usually be used to
represent value data.

Each value also has a data type which says how to interpret the
value data.  The primary data types are:

=over

=item REG_SZ

A null-terminated string.

=item REG_EXPAND_SZ

A null-terminated string which contains substrings consisting of a
percent sign [C<'%'>], an environment variable name, then a percent
sign, that should be replaced with the value associate with that
environment variable.  The system does not automatically do this
substitution.

=item REG_BINARY

Some arbitrary binary value.

=item REG_MULTI_SZ

Several null-terminated strings concatenated together with an extra
trailing C<'\0'> to mark the end of the list.

=item REG_DWORD

A long [4-byte] integer value.  These values are usually returned
packed into a 4-character string and expected in the same format.

=back

In the underlying Registry calls, most places which take a
subkey name also allow you to pass in a subkey "path" -- a
string of several subkey names separated by the delimeter
character, backslash [C<'\\'>].  For example, doing
C<RegOpenKeyEx(HKEY_LOCAL_MACHINE,"SYSTEM\\DISK",...)>
is much like opening the C<"SYSTEM"> subkey of C<HKEY_LOCAL_MACHINE>,
then opening its "DISK" subkey, then closing the C<"SYSTEM"> subkey.

All of the <Tie::Registry> features allow you to use your own
delimeter in place of the system's delimeter, [C<'\\'>].  In most
of our examples we will use a forward slash [C<'/'>] as our
delimeter as it is easier to read and less error prone to use when
writing Perl code since you have to type two backslashes for
each backslash you want in a string.

You can also connect to the registry of other computers on your
network.  This will be discussed more later.

Although the Registry does not have a single root key, the
C<Tie::Registry> module creates a virtual root key for you
which has all of the C<HKEY_*> keys as subkeys.

=head2 Tied Hashes Documentation

Before you can use a tied hash, you must create one.  One way to
do that is via:

    use Tie::Registry qw( %RegHash );

which gives you access to C<%RegHash> which has been tied to the
virtual root key of the Registry.  There are also several ways
you can tie a hash variable to any other key of the Registry, which
are discussed later.

Note that you will most likely use C<$Registry> which is a
reference to C<%RegHash> [that is, C<$Registry= \%RegHash>] instead
of using C<%RegHash> directly.  So you would use C<$Registry-E<gt>{Key}>
rather than C<$RegHash{Key}> and use C<keys %{$Registry}> rather than
C<keys %RegHash>, for example.

For each hash which has been tied to a Registry key, the Perl
C<keys> function will return a list containing the name of each
of the key's subkeys with a delimeter character appended to it and
containing the name of each of the key's values with a delimeter
prepended to it.  For example:

    keys( %{ $Registry->{"HKEY_CLASSES_ROOT\\batfile\\"} } )

might yield the following list value:

    ( "DefaultIcon\\",  # The subkey named "DefaultIcon"
      "shell\\",        # The subkey named "shell"
      "shellex\\",      # The subkey named "shellex"
      "\\",             # The default value [named ""]
      "\\EditFlags" )   # The value named "EditFlags"

For the virtual root key, short-hand subkey names are used
as shown below.  You can use the short-hand name, the regular
C<HKEY_*> name, or any numeric value to access these keys, but
the short-hand names are all that will be returned by the C<keys>
function.

=over

=item "Classes" for HKEY_CLASSES_ROOT

Contains mappings between file name extensions and the uses
for such files along with configuration information for COM
[MicroSoft's Common Object Model] objects.  Usually a link to
the C<"SOFTWARE\\Classes"> subkey of the C<HKEY_LOCAL_MACHINE>
key.

=item "CUser" for HKEY_CURRENT_USER

Contains information specific to the currently logged-in user.
Mostly software configuration information.  Usually a link to
a subkey of the C<HKEY_USERS> key.

=item "LMachine" for HKEY_LOCAL_MACHINE

Contains all manner of information about the computer.

=item "Users" for HKEY_USERS

Contains one subkey, C<".DEFAULT">, which gets copied to a new
subkey whenever a new user is added.  Also contains a subkey for
each user of the system, though only the one for the current user
is usually loaded at any given time.

=item "PerfData" for HKEY_PERFORMANCE_DATA

Used to access data about system performance.  Access via this key
is "special" and all but the most carefully constructed calls will
fail, usually with C<ERROR_INSUFFICIENT_BUFFER>.  For example, you
can't enumerate key names without also enumerating values which
require huge buffers but the exact buffer size required cannot be
determined beforehand because C<RegQueryInfoKey()> E<always> fails
with C<ERROR_INSUFFICIENT_BUFFER> for C<HKEY_PERFORMANCE_DATA> no
matter how it is called.  So it is currently not very useful to
tie a hash to this key.  You can use it to create an object to use
for making carefully constructed calls to the underlying C<Reg*()>
routines.

=item "CConfig" for HKEY_CURRENT_CONFIG

Contains minimal information about the computer's current configuration.

=item "DynData" for HKEY_DYN_DATA

Dynamic data.  We have found no documentation for this key.

=back

A tied hash is much like a regular hash variable in Perl -- you give
it a key string inside braces, [C<{> and C<}>], and it gives you
back a value [or lets you set a value].  For C<Tie::Registry>
hashes, there are two types of values that will be returned.

=over

=item SubKeys

If you give it a string which represents a subkey, then it will
give you back a reference to a hash which has been tied to that
subkey.  It can't return the hash itself, so it returns a
reference to it.  It also blesses that reference so that it is
also an object so you can use it to call method functions.

=item Values

If you give it a string which is a value name, then it will give
you back a string which is the data for that value.  Alternately,
you can request that it give you both the data value string and
the data value type [we discuss how to request this later].  In
this case, it would return a reference to an array where the value
data string is element C<[0]> and the value data type is element
C<[1]>.

=back

The key string which you use in the tied hash must be intepreted
to determine whether it is a value name or a key name or a path
that combines several of these or even other things.  There are
two simple rules that make this interpretation easy and
unambiguous:
    Put a delimeter after each key name.
    Put a delimeter in front of each value name.

Exactly how the key string will be intepreted is governed by the
following cases, in the order listed.  These cases are designed to
"do what you mean"; most of the time you won't have to think about
them, especially if you follow the two simple rules above.  After
the list of cases we give several examples which should be
clear enough so feel free to skip to them unless you are worried
about the details.

=over

=item Remote machines

If the hash is tied to the virtual root of the registry [or the
virtual root of a remote machine's registry], then we treat hash
key strings which start with the delimeter character specially.

If the hash key string starts with two delimeters in a row, then
those should be immediately followed by the name of a remote
machine whose registry we wish to connect to.  That can be
followed by a delimeter and more subkey names, etc.  If the
machine name is not following by anything, then a virtual root
for the remote machine's registry is created, a hash is tied to
it, and a reference to that hash it is returned.

=item Hash key string starts with the delimeter

If the hash is tied to a virtual root key, then the leading
delimeter is ignored.  It should be followed by a valid Registry
root key name [either a short-hand name like C<"LMachine">, an
C<HKEY_*> value, or a numeric value].   This alternate notation is
allowed to be more consistant with the C<Open()> method function.

For all other Registry keys, the leading delimeter indicates
that the rest of the string is a value name.  The leading
delimeter is stripped and the rest of the string [which can
be empty and can contain more delimeters] is used as a value
name with no further parsing.

=item Exact match with direct subkey name followed by delimeter

If you have already called the Perl C<keys> function on the tied
hash [or have already called C<MemberNames> on the object] and the
hash key string exactly matches one of the strings returned, then
no further parsing is done.  In other words, if the key string
exactly matches the name of a direct subkey with a delimeter
appended, then a reference to a hash tied to that subkey is
returned.

This is only important if you have selected a delimeter other than
the system default delimeter and one of the subkey names contains
the delimeter you have chosen.  This rule allows you to deal with
subkeys which contain your chosen delimeter in their name as long
as you only traverse subkeys one level at a time and always
enumerate the list of members before doing so.

The main advantage of this is that Perl code which recursively
traverses a hash will work on hashes tied to Registry keys even if
a non-default delimeter has been selected.

=item Hash key string contains two delimeters in a row

If the hash key string contains two delimeters in a row, then
the string is split between those two delimeters.  The first
part is interpreted as a subkey name or a path of subkey
names separated by delimeters.  The second part is interpreted
as a value name.

=item Hash key string ends with a delimeter

If the key string ends with a delimeter, then it is treated
as a subkey name or path of subkey names separated by delimeters.

=item Hash key string contains a delimeter

If the key string contains a delimeter, then it is split after
the last delimeter.  The first part is treated as a subkey name or
path of subkey names separated by delimeters.  The second part
is ambiguous and is treated as outlined in the next item.

=item Hash key string contains no delimeters

If the hash key string contains no delimeters, then it is ambiguous.

If you are reading from the hash [fetching], then we first use the
key string as a value name.  If there is a value with a matching
name in the Registry key which the hash is tied to, then the value
data string [and possibly the value data type] is returned.
Otherwise, we retry by using the hash key string as a subkey name.
If there is a subkey with a matching name, then we return a reference
to a hash tied to that subkey.  Otherwise we return C<undef>.

If you are writing to the hash [storing], then we use the key
string as a subkey name only if the value you are storing is a
reference to a hash value.  Otherwise we use the key string as
a value name.

=back

=head3 Examples

Here are some examples showing different ways of accessing Registry
information using references to tied hashes:

=over

=item Canonical value fetch

    $tip18= $Registry->{"HKEY_LOCAL_MACHINE\\Software\\Microsoft\\"
               . "Windows\\CurrentVersion\\Explorer\\Tips\\\\18"};

Should return the text of important tip number 18.  Note that two
backslashes, C<"\\">, are required to get a single backslash into
a Perl double-quoted string.  Note that C<"\\"> is appended to
each key name [C<"HKEY_LOCAL_MACHINE"> through C<"Tips">] and
C<"\\"> is prepended to the value name, C<"18">.

=item Changing your delimeter

    $Registry->Delimeter("/");
    $tip18= $Registry->{"HKEY_LOCAL_MACHINE/Software/Microsoft/"
               . "Windows/CurrentVersion/Explorer/Tips//18"};

This usually makes things easier to read when working in Perl.
All remaining examples will assume the delimeter has been changed
as above.

=item Using intermediate keys

    $ms= $Registry->{"LMachine/Software/Microsoft/"};
    $tips= $ms->{"Windows/CurrentVersion/Explorer/Tips/"};
    $tip18= $winlogon->{"/18"};

Same as above but lets you efficiently re-access those intermediate
keys.

=item Chaining in a single statement

    $tip18= $Registry->{"LMachine/Software/Microsoft/"}->
              {"Windows/CurrentVersion/Explorer/Tips/"}->{"/18"};

Like above, this creates intermediate key objects then uses
them to access other data.  Once this statement finishes, the
intermediate key objects are destroying.  Several handles into
the Registry are opened and closed by this statement so it is
less efficient but there are times when this will be useful.

=item Even less efficient example of chaining

    $tip18= $Registry->{"LMachine/Software/Microsoft"}->
              {"Windows/CurrentVersion/Explorer/Tips"}->{"/18"};

Because we left off the trailing delimeters, C<Tie::Registry>
doesn't know whether final names, C<"Microsoft"> and C<"Tips">,
are subkey names or value names.  So this statement ends up
executing the same code as the next one.

=item What the above really does

    $tip18= $Registry->{"LMachine/Software/"}->{"Microsoft"}->
              {"Windows/CurrentVersion/Explorer/"}->{"Tips"}->{"/18"};

With more chains to go through, more temporary objects are created
and later destroyed than in our first chaining example.  Also,
when C<"Microsoft"> is looked up, C<Tie::Registry> first tries to
open it as a value and fails then tries it as a subkey.  The same
is true for when it looks up C<"Tips">.

=item Getting all of the tips

    $tips= $Registry->{"LMachine/Software/Microsoft/"}->
              {"Windows/CurrentVersion/Explorer/Tips/"}
      or  die "Can't find the Windows tips: $^E\n";
    foreach(  keys %$tips  ) {
        print "$_: ", $tips->{$_}, "\n";
    }

First notice that we actually check for failure for the first time.
Note that your version of Perl may not set C<$^E> properly [see
the L<BUGS> section].  We are assuming that the C<"Tips"> key
contains no subkeys.  Otherwise the C<print> statement would show
something like C<"Tie::Registry=HASH(0xc03ebc)"> for each subkey.

=back

=head3 Deleting items

You can use the Perl C<delete> function to delete a value from a
Registry key or to delete a subkey as long that subkey contains
no subkeys of its own.  See L<More Examples>, below, for more
information.

=head3 Storing items

You can use the Perl assignment operator [C<=>] to create new keys,
create new values, or replace values.  The values you store should
be in the same format as the values you would fetch from a tied
hash.  For example, you can use a single assignment statement to
copy an entire Registry tree.  The following statement:

    $Registry->{"LMachine/Software/Classes/Tie_Registry/"}=
      $Registry->{"LMachine/Software/Classes/batfile/"};

creates a C<"Tie_Registry"> subkey under the C<"Software\\Classes">
subkey of the C<HKEY_LOCAL_MACHINE> key.  Then it populates it
with copies of all of the subkeys and values in the C<"batfile">
subkey and all of its subkeys.  Note that you need to have
called C<$Registry-E<gt>ArrayValues(1)> for the proper value data
type information to be copied.  Note also that this release of
C<Tie::Registry> does not copy key attributes such as class name
and security information [this is planned for a future release].

The following statement creates a whole subtree in the Registry:

    $Registry->{"LMachine/Software/FooCorp/"}= {
        "FooWriter/" => {
            "/Version" => "4.032",
            "Startup/" => {
                "/Title" => "Foo Writer Deluxe ][",
                "/WindowSize" => [ pack("LL",$wid,$ht), REG_BINARY ],
                "/TaskBarIcon" => [ "0x0001", REG_DWORD ],
            },
            "Compatibility/" => {
                "/AutoConvert" => "Always",
                "/Default Palette" => "Windows Colors",
            },
        },
        "/License", => "0123-9C8EF1-09-FC",
    };

Note that all but the last Registry key used on the left-hand
side of the assignment ["FooCorp/"] must already exist for this
statement to succeed.  

By using the leading a trailing delimeters on each subkey name and
value name, C<Tie::Registry> will tell you if you try to assign
subkey information to a value or visa-versa.

=head3 More examples

=over

=item Adding a new tip

    $tips= $Registry->{"LMachine/Software/Microsoft/"}->
              {"Windows/CurrentVersion/Explorer/Tips/"}
      or  die "Can't find the Windows tips: $^E\n";
    $tips{'/186'}= "Be very careful when making changes to the Registry!";

=item Deleting our new tip

    $tips= $Registry->{"LMachine/Software/Microsoft/"}->
              {"Windows/CurrentVersion/Explorer/Tips/"}
      or  die "Can't find the Windows tips: $^E\n";
    $tip186= delete $tips{'/186'};

Note that Perl's C<delete> function returns the value that was deleted.

=item Adding a new tip differently

    $Registry->{"LMachine/Software/Microsoft/" .
                "Windows/CurrentVersion/Explorer/Tips//186"}=
      "Be very careful when making changes to the Registry!";

=item Deleting differently

    $tip186= delete $Registry->{"LMachine/Software/Microsoft/Windows/" .
                                "CurrentVersion/Explorer/Tips//186"};

Note that this only deletes the tail of what we looked up, the
C<"186"> value, not any of the keys listed.

=item Deleting a key

    $tips= delete $Registry->{"CUser/Software/Microsoft/Windows/" .
                              "CurrentVersion/Explorer/Tips/"};

WARNING:  This will delete all information about the current user's
tip preferences.  Actually executing this command would probably
cause the user to see the Welcome screen the next time they log in
and may cause more serious problems.  This statement is shown as
an example only and should not be used when experimenting.

This deletes the C<"Tips"> key and the values it contains.  The
C<delete> function will return a reference to a hash [not a tied
hash] containing the value names and value data that were deleted.

The information to be returned is copied from the Registry into a
regular Perl hash before the key is deleted.  If the key has many
subkeys, this copying could take a significant amount of memory
and/or processor time.  So you can disable this process by calling
the C<FastDelete> member function:

    $prevSetting= $regKey->FastDelete(1);

which will cause all subsequent delete operations to simply return
a true value if they succeed.

=item Undeleting a key

    $Registry->{"LMachine/Software/Microsoft/Windows/" .
                "CurrentVersion/Explorer/Tips/"}= $tips;

This adds back what we just deleted.  Note that this version of
C<Tie::Registry> will use defaults for the key attributes [such
as class and security] and not restore the previous attributes.

=item Not deleting a key

    $res= delete $Registry->{"CUser/Software/Microsoft/Windows/"}
    defined($res)  ||  die "Can't delete URL key: $^E\n";

WARNING:  Actually executing this command could cause serious
problems.  This statement is shown as an example only and should
not be used when experimenting.

Since the "Windows" key should contain subkeys, that C<delete>
statement should make no changes to the Registry, return C<undef>,
and set C<$^E> to "Access is denied" [but see the L<BUGS> section
about C<$^E>].

=item Not deleting again

    $tips= $Registry->{"CUser/Software/Microsoft/Windows/" .
                       "CurrentVersion/Explorer/Tips/"};
    delete $tips;

The Perl C<delete> function requires that its argument be an
expression that ends in a hash element lookup [or hash slice],
which is not the case here.  The C<delete> function doesn't
know which hash $tips came from and so can't delete it.

=back

=head2 Objects Documentation

The following member functions are defined for use on C<Tie::Registry>
objects:

=over 

=item new

The C<new> method creates a new C<Tie::Registry> object.  C<new>
is just a synonym for C<Open> so see C<Open> below for information
on what arguments to pass in.  Examples:

    $machKey= new Tie::Registry "LMachine"
      ||  die "Can't access HKEY_LOCAL_MACHINE key: $^E\n";
    $userKey= Tie::Registry->new("CUser")
      ||  die "Can't access HKEY_CURRENT_USER key: $^E\n";

=item Open
=item $subKey= $key->Open( $sSubKey, $rhOptions )

The C<Open> method opens a Registry key and returns a new
C<Tie::Registry> object associated with that Registry key.  If you
wish to use that object as a tied hash [not just as an object],
then use the C<TiedRef> method function after C<Open>.

C<sSubKey> is a string specifying a subkey to be opened.  Alternately
C<sSubKey> can be a reference to an array value containing the list
of increasingly deep subkeys specifying the path to the subkey to be
opened.

C<$rhOptions> is an optional reference to a hash containing extra
options.  The C<Open> method supports two options, C<"Delimeter">
and C<"Access">, and C<$rhOptions> should have only have zero or
more of these strings as keys.

The C<"Delimeter"> option specifies what string [usually a single
character] will be used as the delimeter to be appended to subkey
names and prepended to value names.  If this option is not specified,
the new key [C<$subKey>] inherits the delimeter of the old key
[C<$key>].

The C<"Access"> option specifies what level of access to the
Registry key you wish to have once it has been opened.  If this
option is not specified, the new key [C<$subKey>] is opened with
the same access level used when the old key [C<$key>] was opened. 
The virtual root of the Registry pretends it was opened with
access C<KEY_READ|KEY_WRITE> so this is the default access when
opening keys directory via C<$Registry>.

If the C<"Access"> option value is a string that starts with
C<"KEY_">, then it should match E<one> of the predefined access
levels [probably C<"KEY_READ">, C<"KEY_WRITE">, or
C<"KEY_ALL_ACCESS">] exported by the C<Win32API::Registry> module.
Otherwise, a numeric value is expected.  For maximum flexibility,
include C<use Win32API::Registry qw(:KEY_);>, for example, near
the top of your script so you can specify more complicated access
levels such as C<KEY_READ|KEY_WRITE>.

If C<sSubKey> does not begin with the delimeter [or C<sSubKey>
is an array reference], then the path to the subkey to be opened
will be relative to the path of the original key [C<$key>].  If
C<sSubKey> begins with a single delimeter, then the path to the
subkey to be opened will be relative to the virtual root of the
Registry on whichever machine the original key resides.  If
C<sSubKey> begins with two consectutive delimeters, then those
must be followed by a machine name which causes the C<Connect>
method function to be called.

Examples:

    $machKey= $Registry->Open( "LMachine", {Access=>KEY_READ,Delimeter=>"/"} )
      ||  die "Can't open HKEY_LOCAL_MACHINE key: $^E\n";
    $swKey= $machKey->Open( "Software" );
    $logonKey= $swKey->Open( "Microsoft/Windows NT/CurrentVersion/Winlogon/" );
    $NTversKey= $swKey->Open( ["Microsoft","Windows NT","CurrentVersion"] );
    $versKey= $swKey->Open( qw(Microsoft Windows CurrentVersion) );

    $remoteKey= $Registry->Open( "//HostA/LMachine/System/", {Delimeter=>"/"} )
      ||  die "Can't connect to HostA or can't open subkey: $^E\n";

=item Connect
=item $remoteKey= $Registry->Connect( $sMachineName, $sKeyPath, $rhOptions )

The C<Connect> method connects to the Registry of a remote machine,
and opens a key within it, then returns a new C<Tie::Registry>
object associated with that remote Registry key.  If you
wish to use that object as a tied hash [not just as an object],
then use the C<TiedRef> method function after C<Connect>.

C<sMachineName> is the name of the remote machine.  You don't have
to preceed the machine name with two delimeter characters.

C<sKeyPath> is a string specifying the remote key to be opened. 
Alternately C<sKeyPath> can be a reference to an array value
containing the list of increasingly deep keys specifying the path
to the key to be opened.

C<$rhOptions> is an optional reference to a hash containing extra
options.  The C<Connect> method supports two options, C<"Delimeter">
and C<"Access">.  See the C<Open> method documentation for more
information on these options.

C<sKeyPath> is already relative to the virtual root of the Registry
of the remote machine.  A single leading delimeter on C<sKeyPath>
will be ignored and is not required.

C<sKeyPath> can be empty in which case C<Connect> will return an
object representing the virtual root key of the remote Registry. 
Each subsequent use of C<Open> on this virtual root key will call
the system C<RegConnectRegistry> function.

The C<Connect> method can be called via any C<Tie::Registry> object,
not just C<$Registry>.  Attributes such as the desired level of access
and the delimeter will be inherited from the object used.

Examples:

    $remMachKey= $Registry->Connect( "HostA", "LMachine", {Delimeter->"/"} )
      ||  die "Can't connect to HostA's HKEY_LOCAL_MACHINE key: $^E\n";

    $remVersKey= $remMachKey->Connect( "www.microsoft.com",
                   "LMachine/Software/Microsoft/Inetsrv/CurrentVersion/",
                   { Access->KEY_READ, Delimeter->"/" } )
      ||  die "Can't check what version of IIS Microsoft is running: $^E\n";

    $remVersKey= $remMachKey->Connect( "www",
                   qw(LMachine Software Microsoft Inetsrv CurrentVersion) )
      ||  die "Can't check what version of IIS we are running: $^E\n";
    

=item ObjectRef

Documentation under construction.

=item Flush

Documentation under construction.

=item GetValue

Documentation under construction.

=item ValueNames

Documentation under construction.

=item SubKeyNames

Documentation under construction.

=item SubKeyClasses

Documentation under construction.

=item SubKeyTimes

Documentation under construction.

=item MemberNames

Documentation under construction.

=item Information

Documentation under construction.

=item Delimeter

Documentation under construction.

=item Handle

Documentation under construction.

=item Path

Documentation under construction.

=item Machine

Documentation under construction.

=item Access

Documentation under construction.

=item OS_Delimeter

Documentation under construction.

=item Roots

Documentation under construction.

=item Tie

Documentation under construction.

=item TiedRef

Documentation under construction.

=item ArrayValues

Documentation under construction.

=item FastDelete

Documentation under construction.

=item SetValue

Documentation under construction.

=item StoreKey

Documentation under construction.

=item CreateKey

Documentation under construction.

=item Load

Documentation under construction.

=item UnLoad

Documentation under construction.

=item AllowSave

Documentation under construction.

=item AllowLoad

Documentation under construction.

=back

=head1 SUMMARY

Most things can be done most easily via tied hashes.  Skip down to the
the L<Tied Hashes Summary> to get started quickly.

=head2 Objects Summary

Here are quick examples that document the most common functionality
of all of the method function [except for a few almost useless ones].

    # Just another way of saying Open():
    $key= new Tie::Registry "LMachine\\Software\\",
      { Access=>KEY_READ|KEY_WRITE, Delimeter=>"\\" };

    # Open a Registry key:
    $subKey= $key->Open( "SubKey/SubSubKey/",
      { Access=>KEY_ALL_ACCESS, Delimeter=>"/" } );

    # Connect to a remote Registry key:
    $remKey= $Registry->Connect( "MachineName", "LMachine/",
      { Access=>KEY_READ, Delimeter=>"/" } );

    # Get value data:
    $valueString= $key->GetValue("ValueName");
    ( $valueString, $valueType )= $key->GetValue("ValueName");

    # Get list of value names:
    @valueNames= $key->ValueNames;

    # Get list of subkey names:
    @subKeyNames= $key->SubKeyNames;

    # Get combined list of value names (with leading delimeters)
    # and subkey names (with trailing delimeters):
    @memberNames= $key->MemberNames;

    # Get all information about a key:
    %keyInfo= $key->Information;
    # keys(%keyInfo)= qw( Class LastWrite
    #   CntSubKeys MaxSubKeyLen MaxSubClassLen
    #   CntValues MaxValNameLen MaxValDataLen SecurityLen );

    # Get selected information about a key:
    ( $class, $cntSubKeys )= $key->Information( "Class", "CntSubKeys" );

    # Get and/or set delimeter:
    $delim= $key->Delimeter;
    $oldDelim= $key->Delimeter( $newDelim );

    # Get "path" for an open key:
    $path= $key->Path;
    # For example, "/CUser/Control Panel/Mouse/"
    # or "//NetServer/LMachine/System/DISK/".

    # Get name of machine where key is from:
    $mach= $key->Machine;
    # Will usually be "" indicating key is on local machine.

    # Get referenced to a tied hash for the object
    # so you can use the simpler tied hash interface:
    $key= $key->TiedRef;

    # Control whether hashes tied to this object return
    # array references when asked for value data:
    $oldBool= $key->ArrayValues( $newBool );

    # Control whether delete via hashes tied to this
    # object simply return a true value to save resources:
    $oldBool= $key->FastDelete( $newBool );

    # Add or set a value:
    $key->SetValue( "ValueName", $valueDataString );
    $key->SetValue( "ValueName", pack($format,$valueData), "REG_BINARY" );

    # Add or set a key:
    $key->CreateKey( "SubKeyName" );
    $key->CreateKey( "SubKeyName",
      { Access=>"KEY_ALL_ACCESS", Class=>"ClassName",
        Delimeter=>"/", Volatile=>1, Backup=>1 } );

    # Load an off-line Registry hive file into the on-line Registry:
    $newKey= $Registry->Load( "C:/Path/To/Hive/FileName" );
    $newKey= $key->Load( "C:/Path/To/Hive/FileName", "NewSubKeyName" );
    # Unload a Registry hive file loaded via the Load() method:
    $newKey->UnLoad;

    # (Dis)Allow yourself to load Registry hive files:
    $success= $Registry->AllowLoad( $bool );

    # (Dis)Allow yourself to save a Registry key to a hive file:
    $success= $Registry->AllowSave( $bool );

    # Save a Registry key to a new hive file:
    $key->RegSaveKey( "C:/Path/To/Hive/FileName", [] );

=head3 Other Useful Methods

See L<Win32API::Registry> for more information on these methods. 
These methods are provided for coding convenience and are
identical to the C<Win32API::Registry> functions except that these
don't take a handle to a Registry key, instead getting the handle
from the invoking object [C<$key>].

    $key->RegGetKeySecurity( $iSecInfo, $sSecDesc, $lenSecDesc );
    $key->RegLoadKey( $sSubKeyName, $sPathToFile );
    $key->RegNotifyChangeKeyValue(
      $bWatchSubtree, $iNotifyFilter, $hEvent, $bAsync );
    $key->RegQueryMultipleValues(
      $structValueEnts, $cntValueEnts, $Buffer, $lenBuffer );
    $key->RegReplaceKey( $sSubKeyName, $sPathToNewFile, $sPathToBackupFile );
    $key->RegRestoreKey( $sPathToFile, $iFlags );
    $key->RegSetKeySecurity( $iSecInfo, $sSecDesc );
    $key->RegUnLoadKey( $sSubKeyName );

=head2 Tied Hashes Summary

For fast learners, this may be the only section you need to read.
Always append one delimeter to the end of each Registry key name
and prepend one delimeter to the front of each Registry value name.

=head3 Opening keys

    use Tie::Registry;
    $Registry->Delimeter("/");                  # Set delimeter to "/".
    $swKey= $Registry->{"LMachine/Software/"};
    $winKey= $swKey->{"Microsoft/Windows/CurrentVersion/"};
    $userKey= $Registry->
      {"CUser/Software/Microsoft/Windows/CurrentVersion/"};
    $remoteKey= $Registry->{"//HostName/LMachine/"};

=head3 Reading values

    $progDir= $winKey->{"/ProgramFilesDir"};    # "C:\\Program Files"
    $tip21= $winKey->{"Explorer/Tips//21"};     # Text of tip #21.

    $winKey->ArrayValues(1);
    ( $devPath, $type )= $winKey->{"/DevicePath"};
    # $devPath eq "%SystemRoot%\\inf"
    # $type eq "REG_EXPAND_SZ"  [if you have SetDualVar.pm installed]
    # $type == REG_EXPAND_SZ  [if you did "use Win32API::Registry qw(REG_)"]

=head3 Setting values

    $winKey->{"Setup//SourcePath"}= "\\\\SwServer\\SwShare\\Windows";
    # Simple.  Assumes data type of REG_SZ.

    $winKey->{"Setup//Installation Sources"}=
      [ "D:\x00\\\\SwServer\\SwShare\\Windows\0\0", "REG_MULTI_SZ" ];
    # "\x00" and "\0" used to mark ends of each string and end of list.

    $userKey->{"Explorer/Tips//DisplayInitialTipWindow"}=
      [ pack("L",0), "REG_DWORD" ];
    $userKey->{"Explorer/Tips//Next"}= [ pack("S",3), "REG_BINARY" ];
    $userKey->{"Explorer/Tips//Show"}= [ pack("L",0), "REG_BINARY" ];

=head3 Adding keys

    $swKey->{"FooCorp/"}= {
        "FooWriter/" => {
            "/Version" => "4.032",
            "Startup/" => {
                "/Title" => "Foo Writer Deluxe ][",
                "/WindowSize" => [ pack("LL",$wid,$ht), REG_BINARY ],
                "/TaskBarIcon" => [ "0x0001", REG_DWORD ],
            },
            "Compatibility/" => {
                "/AutoConvert" => "Always",
                "/Default Palette" => "Windows Colors",
            },
        },
        "/License", => "0123-9C8EF1-09-FC",
    };

=head3 Listing all subkeys and values

    @members= keys( %{$swKey} );
    @subKeys= grep(  m#^/#,  keys( %{$swKey->{"Classes/batfile/"}} )  );
    # @subKeys= ( "/", "/EditFlags" );
    @valueNames= grep(  ! m#^/#,  keys( %{$swKey->{"Classes/batfile/"}} )  );
    # @valueNames= ( "DefaultIcon/", "shell/", "shellex/" );

=head3 Deleting values or keys with no subkeys

    $oldValue= delete $userKey->{"Explorer/Tips//Next"};

    $oldValues= delete $userKey->{"Explorer/Tips/"};
    # $oldValues will be reference to hash containing deleted keys values.

=head3 Closing keys

    undef $swKey;               # Explicit way to close a key.
    $winKey= "Anything else";   # Implicitly closes a key.
    exit 0;                     # Implicitly closes all keys.

=head1 AUTHOR

Tye McQueen, tye@metronet.com, see http://www.metronet.com/~tye/.

=head1 SEE ALSO

C<Win32API::Registry(3)> - Provides access to Reg*(), HKEY_*,
KEY_*, REG_* [required].

C<Win32::WinError(3)> - Defines ERROR_* values [optional].

L<SetDualVar(3)> - For returning REG_* values as combined
string/integer [optional].

=head1 BUGS

Because Tie::Registry requires Win32API::Registry which uses the
standard Perl tools for building extensions and these are not
supported with the ActiveState version of Perl, Tie::Registry
cannot be used with the ActiveState version of Perl.  Sorry.
The ActiveState version and standard version of Perl are merging
so you may want to switch to the standard version of Perl soon.

Because Perl hashes are case sensitive, certain lookups are also
case sensistive.  In particular, the "Classes", "CUser",
"LMachine", "Users", "PerfData", "CConfig", and "DynData" root
keys must always be entered without changing between upper and
lower case letters.  Also, the special rule for matching subkey
names that contain the user-selected delimeter only works if case
is matched.  All other key name and value name lookups should be
case insensitive because the underlying Reg*() calls ignore case.

=cut

# Autoload not currently supported by Perl under Windows.
