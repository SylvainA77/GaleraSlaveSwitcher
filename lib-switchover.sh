#!/bin/bash
###
# switchover.sh
# just a function lib to source in your own bash if you need
###
#              |||
# +------ooOO-(O O)-OOoo------+
# |            (_)            |
# |     Sylvain  Arbaudie     |
# |   arbaudie.it@gmail.com   |
# +---------------------------+
###
# original code & doc by Sylvain Arbaudie
# github repo : https://github.com/SylvainA77/GaleraSlaveSwitcher
###
# main contributor : Sebastien Giraud
#                    sebastien.giraud@mariadb.com
# functions description
#
# echoerr
# desc : sends all the debugs to stderr and adds a timestamp
# args : 1. string to log
#
# sqlexec
# desc : execute sql commands to the server you want, output formatted in a bash frield way
# args : 1. host/ip
#        2. sql statement
#
# switchover
# desc : switch the designated slave to the designated new master
# args : 1. slave host/ip
#        2. master host/ip
#
# findnewmaster
# desc : given a slave ip, finds a suitable new mlaster among the synced node of the galera cluster
# args : 1. failedmaster host/ip
#        2. initating maxscale monitor
#
# waitforslave
# desc : given credentials, connect to the machine and wait until slave is up to date (as in : read binlogs = exec binlogs)
# args : 1. slave host/ip
#
# getxid
# desc : given credentials, get watermark and DDLoffset
# args : 1. binlogdir
#
# getslavewatermark
# desc : given credentials, connect to the machine, get watermark and DDLoffset
# args : 1. slave host/ip
#
# getmasterGTID
# desc : given credentials, watermark, and offset, get the correspondiong GTID
# args : 1. master host/ip
#        2. watermark
#        3. offset
#
###

exec 2>/var/log/switchover.err

source /etc/.credentials

# create debug environment 
debug=0
[ $debug ] && { \
        DEBUG_FILE="/var/log/maxscale/debug.log"
        echo "DEBUG MODE ENABLED" 
        [ -f ${DEBUG_FILE} ] || \
                touch ${DEBUG_FILE} || \
                echoerr "ERROR : unable to create ${DEBUG_FILE}"
}


echoerr()
{
        echo "`date +%F:%T`:$@" 1>&2;
}

sqlexec()
{
       [[ -n "$debug" ]] && echoerr "sqlexec args : $*"
       #[ $# -ne 2 ] && echo "sqlexec function requires 2/3 args : ip, statement, [port] " && exit -1
#TODO
       local credentials=$( getcredentials $1 )
       local port=3306
       [[ $# -ge 4 ]] && port=$4
       [[ $# -eq 6 ]] && credentials="-u$5 -p$6 -h$1"

       [[ "$3" -eq 1 ]] && local binlogrouterservice=$( maxctrl --tsv list services | grep binlogrouter |cut -f1 )
       [[ "$3" -eq 1 ]] && local binlogrouter_user=$( maxctrl show service ${binlogrouterservice} | grep router_options | cut -d, -f2 | sed 's/.*=//' )	
       [[ "$3" -eq 1 ]] && local binlogrouter_pass=$( maxctrl show service ${binlogrouterservice} | grep router_options | cut -d, -f3 | sed 's/.*=//' )	
       [[ "$3" -eq 1 ]] && local port=$( maxctrl list listeners ${binlogrouterservice} --tsv | cut -f2 )
       [[ "$3" -eq 1 ]] && credentials="-u$binlogrouter_user -p$binlogrouter_pass -h$1"

       [[ -n "$debug" ]] && echoerr "credentials : $credentials"
       [[ -n "$debug" ]] && echoerr "request : mysql $2"
       [[ -n "$debug" ]] && echoerr "port : $port"
       echo "$2" | mysql -B --skip_column_names $credentials -P$port
       [ $? -ne 0 ] && exit $?
}

waitforslave()
{

        [[ -n "$debug" ]] && echoerr "waitforslave args : $*"
        [ $# -ne 1 ] && echo "waitforslave function requires 1 arg : slave ip" && exit -1

        local slave$1

        while [ $readlogpos -ne $execlogpos ]
        do
                read readlogpos execlogpos <<<$( sqlexec $slave "show slave status" $usebinlogrouter | cut -f7,22 )
                [[ -n "$debug" ]] && echoerr "readlogpos : $readlogpos / execlogpos : $execlogpos "
        done
}

getslavewatermark()
{

        [[ -n "$debug" ]] && echoerr "getslavwatermark args : $*"
        [ $# -ne 1 ] && echo "getslavewatermark function requires 1 arg : slave ip" && exit -1

        local slave=$1
        local watermark
        local endlogpos
        local DDLoffset
        
        #ALGO : lastslavegtid, xid + offset depuis le relaylog
        [[ -n "$debug" ]] && echoerr "find last relaylog file name"
        relay_log_file=$( sqlexec $slave "show slave status" 0 | cut -f8 )
        [[ -n "$debug" ]] && echoerr "find xid + offset from relaylog file :$relay_log_file"
        read endlogpos watermark<<<$( sqlexec $slave "show relaylog events in '$relay_log_file'" 0 | grep -i xid | tail -1 | cut -f2,6 | xargs )
        [[ -n "$debug" ]] && echoerr "endlogpos:$endlogpos, watermark:$watermark"
        DDLoffset=$( sqlexec $slave "show relaylog events in '$relay_log_file' from $endlogpos" 0 | grep -i gtid | wc -l)
        watermark=$(echo "$watermark" | cut -d'*' -f2 | cut -d'=' -f2 )
        [[ -n "$debug" ]] && echoerr "watermark : $watermark"
        [[ -n "$debug" ]] && echoerr "DDLoffset : $DDLoffset"

        echo "$watermark        $DDLoffset"
}

getxid()
{
	[[ -n "$debug" ]] && echoerr "getxid"
	[ $# -ne 0 ] && echo "getxid function requires 0 arg" && exit -1

        local watermark
        local endlogpos
        local DDLoffset

	local binlogrouterservice=$( maxctrl --tsv list services | grep binlogrouter |cut -f1 )
	local binlogfile=$( maxctrl show service ${binlogrouterservice} | grep binlog_name | cut -d '"' -f4 )
	local binlogdir=$( maxctrl show service ${binlogrouterservice} |grep router_option | sed 's/,/\n/g' | grep binlogdir | cut -d= -f2 )

	read endlogpos watermark <<<$( mysqlbinlog ${binlogdir}/${binlogfile} --base64-output=decode-rows | grep -e Xid --binary-files=text | tail -1 | cut -d ' ' -f8,13 )
	DDLoffset=$( mysqlbinlog ${binlogdir}/${binlogfile} --base64-output=decode-rows -j ${endlogpos} | grep -e GTID | wc -l )

	#local binlogfile=$( mysql -P5308 -h127.0.0.1 -umaxscale -pM4xscale_pw -e 'show slave status\G' | grep "^[[:space:]]*Master_Log_File:" | sed 's/ //g' | cut -d: -f2 )

        #ALGO : lastslavegtid, xid + offset depuis le relaylog
	###        [[ -n "$debug" ]] && echoerr "find last binlog file name"
	###        binlogfile=$( ls -ltr $binlogdir | tail -1 | cut [reste a cut et prendre la colonne qui nous interesse) )
	[[ -n "$debug" ]] && echoerr "find xid + offset from relaylog file :$binlogfile"
	####obsolete        
	####        read endlogpos watermark<<<$( mysqlbinlog $binlogdir/$binlogfile | grep -i xid | tail -1 | cut -f2,6 | xargs )
	####        [[ -n "$debug" ]] && echoerr "endlogpos:$endlogpos, watermark:$watermark"
	####        DDLoffset=$( sqlexec $slave "show relaylog events in '$relay_log_file' from $endlogpos" | grep -i gtid | wc -l)
	####        watermark=$(echo "$watermark" | cut -d'*' -f2 | cut -d'=' -f2 )
        [[ -n "$debug" ]] && echoerr "watermark : $watermark"
        [[ -n "$debug" ]] && echoerr "DDLoffset : $DDLoffset"

        echo "$watermark        $DDLoffset"
}

getreplcoordinates()
{

        [[ -n "$debug" ]] && echoerr "getreplcoordinates args : $*"
        [ $# -ne 3 ] && echoerr "getreplcoordinates function requires 3 args : master ip, watermark et DDLoffset " && exit -1
        local master=$1
        local watermark=$2
        local offset=$3
        local masterGTID=''
	local startpos=''
	local binlogfile=''

        [[ -n "$debug" ]] && echoerr "find list of binlog files (reverseorder) on new master"

        newmasterbinlogfiles=( $( sqlexec $master 'show binary logs' 0 | cut -f1 | tac ) )
        [[ -n "$debug" ]] && echoerr "newmasterbinlogfiles : ${newmasterbinlogfiles[@]}"
        [[ -n "$debug" ]] && echoerr "newmasterbinlogfiles number : ${#newmasterbinlogfiles[@]}"
        [[ -n "$debug" ]] && echoerr "parse each binlog file until watermark "

        for eachbinlogfile in "${newmasterbinlogfiles[@]}"
        do
                [[ -n "$debug" ]] && echoerr "eachbinlogfile :$eachbinlogfile"
                # we search for watermark in actual binlogfile
                #masterGTID=$( sqlexec $master "show binlog events in '$eachbinlogfile'" | grep -i -e xid -e gtid  | grep "-A$offset" -B1 -e "$watermark"  | grep -i gtid | tail -1 | cut -f6 | sed 's/GTID //' | sed 's/BEGIN //' )
                read binlogfile startpos masterGTID <<<$( sqlexec $master "show binlog events in '$eachbinlogfile'" 0 | grep -i -e xid -e gtid  | grep "-A$offset" -e "$watermark"  | grep -i gtid | cut -f 1,2,6 |sed 's/BEGIN GTID //' | sed 's/GTID //' )
                [[ -n "$debug" ]] && echoerr "DEBUG sqlexec $master show binlog events in $eachbinlogfile 0 | grep -i -e xid -e gtid  | grep -A$offset  -e $watermark  | grep -i gtid | cut -f 2,6 |sed 's/BEGIN GTID //'  )"
                [[ -n "$debug" ]] && echoerr "masterGTID : $masterGTID, startpos : $startpos"

                [[ ! -z "$masterGTID" ]] && break ; # as long as watermark is not matched, waterarkGTID stays unset/empty. Once watermarkGTID is set, we have found what we need and can exit the loop
        done

        echo "$masterGTID	$binlogfile	$startpos"
}

switchover()
{

        [[ -n "$debug" ]] && echoerr "switchover args : $*"
        [ $# -lt 3 ] && echoerr "Switchover function requires 3 args : 1. slave ip, 2. new master ip, 3. usebinlogrouter, 4 [optionnal : usegtid]" && exit -1
        local slave=$1
        local master=$2
	usebinlogrouter=$3
	local usegtid=${4:-1}
	local startpos=''
	local binlogfile=''
	local masterGTID=''
	local stmt=''

	#1   find the watermark on the slave
        [[ -n "$debug" ]] && echoerr "find watermark in relaylogfile"

        [[ -n "$usebinlogrouter" ]] && read watermark DDLoffset <<<$( getxid )
        [[ -n "$usebinlogrouter" ]] || read watermark DDLoffset <<<$( getslavewatermark $slave )

        #2   find the watermark on the new master
        read masterGTID binlogfile startpos <<<$( getreplcoordinates $master $watermark $DDLoffset )

	#TODO check gtid, binlog, and position and exit if this vairables are empty
	[[ -z $masterGTID ]] || [[ -z $binlogfile ]] || [[ -z $startpos ]] && {
		echoerr "ERROR variables not setted ! " 
		echoerr "Master GTID : $masterGTID " 
		echoerr "BinlogFile : $binlogfile " 
		echoerr "StartPos : $startpos " 
		exit 2;
	}

        #4 change slave settings and reconnect
        #4.1 stop slave
        #[[ -n "$debug" ]] && echoerr "stop slave"
        #sqlexec $slave 'stop slave'

        #4.2 change slave gtid
        [[ -n "$debug" ]] && echoerr "set gtid to $masterGTID"
       
        #[[ -n "$usebinlogrouter" ]] && stmt="set \@\@global.gtid_slave_pos=\"$masterGTID\""
        #[[ -n "$usebinlogrouter" ]] || stmt="set global gtid_slave_pos=\"$masterGTID\"" 
	
	[[ -n "$usegtid" ]] && sqlexec $slave "set @@global.gtid_slave_pos=\"$masterGTID\" " $usebinlogrouter
        [[ -n "$usegtid" ]] || sqlexec $slave "change master to master_log_file=\'$binlogfile\', master_log_post=$startpos" $usebinlogrouter

	#4.3 change master shot
        [[ -n "$debug" ]] && echoerr "change master"

	local tmp_slave_pos=''
	[[ -n "$usegtid" ]] && tmp_slave_pos=", master_use_gtid=slave_pos"

	sqlexec $slave "change master to master_host=\"$master\" $tmp_slave_pos" $usebinlogrouter

	#4.4 start slave
        [[ -n "$debug" ]] && echoerr "start slave"
        sqlexec $slave "start slave" $usebinlogrouter

return $retcode
}

findnewmaster()
{
        [[ -n "$debug" ]] && echoerr "findnewmaster args : $*"
        [ $# -ne 2 ] && echoerr "findnewmaster function requires 2 args : failed master ip & initiating maxscale monitor " && exit -4

        [[ -n "$debug" ]] && echoerr "find galera monitor of failed master"
	#TODO remake : retreive the galera monitor and the corresponding nodes in runnning mode  

        #1.2 find which galeramonitor master was part of
        monitor=$( maxctrl --tsv show servers | grep -e ^Server -e ^Address -e ^Monitors | grep -A1 $1 | grep -e^Monitors | grep -v $2 | cut -f2  )
        [[ -n "$debug" ]] && echoerr "monitor : $monitor "

        [[ -n "$debug" ]] && echoerr "find 1st synced member of same monitor group"

        #1.3 find on other synced node in the same monitor

        local myresult=$( maxctrl --tsv show servers | grep -e ^Address  -e ^State -e ^Monitors | grep -B3 "$monitor" | grep -B1 Synced | head -1 | cut -f2 | xargs )
        [[ -n "$debug" ]] && echoerr "newmasteraddress : $myresult"

        echo "$myresult"

        return 0
}
