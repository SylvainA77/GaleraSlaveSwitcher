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

echoerr()
{
        echo "`date +%F:%T`:$@" 1>&2;
}

sqlexec()
{
       [[ -n "$debug" ]] && echoerr "sqlexec args : $*"
       [ $# -ne 2 ] && echo "sqlexec function requires 2 args : ip, statement " && exit -1

       local credentials=$( getcredentials $1 )
       [[ -n "$debug" ]] && echoerr "credentials : $credentials"
       echo "$2" | mysql -B --skip_column_names $credentials
       [ $? -ne 0 ] && exit $?
}

waitforslave()
{

        [[ -n "$debug" ]] && echoerr "waitforslave args : $*"
        [ $# -ne 1 ] && echo "waitforslave function requires 1 arg : slave ip" && exit -1

        local slave$1

        while [ $readlogpos -ne $execlogpos ]
        do
                read readlogpos execlogpos <<<$( sqlexec $slave "show slave status" | cut -f7,22 )
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
        relay_log_file=$( sqlexec $slave "show slave status" | cut -f8 )
        [[ -n "$debug" ]] && echoerr "find xid + offset from relaylog file :$relay_log_file"
        read endlogpos watermark<<<$( sqlexec $slave "show relaylog events in '$relay_log_file'" | grep -i xid | tail -1 | cut -f2,6 | xargs )
        [[ -n "$debug" ]] && echoerr "endlogpos:$endlogpos, watermark:$watermark"
        DDLoffset=$( sqlexec $slave "show relaylog events in '$relay_log_file' from $endlogpos" | grep -i gtid | wc -l)
        watermark=$(echo "$watermark" | cut -d'*' -f2 | cut -d'=' -f2 )
        [[ -n "$debug" ]] && echoerr "watermark : $watermark"
        [[ -n "$debug" ]] && echoerr "DDLoffset : $DDLoffset"

        echo "$watermark        $DDLoffset"
}

getmasterGTIDfromwatermark()
{

        [[ -n "$debug" ]] && echoerr "getmasterGTIDfromwatermark args : $*"
        [ $# -ne 3 ] && echoerr "getimasterGTIDfromwatermark function requires 3 args : master ip, watermark et DDLoffset " && exit -1
        local master=$1
        local watermark=$2
        local offset=$3
        local masterGTID=""

        [[ -n "$debug" ]] && echoerr "find list of binlog files (reverseorder) on new master"

        newmasterbinlogfiles=( $( sqlexec $master 'show binary logs' | cut -f1 | tac ) )
        [[ -n "$debug" ]] && echoerr "newmasterbinlogfiles : ${newmasterbinlogfiles[@]}"
        [[ -n "$debug" ]] && echoerr "newmasterbinlogfiles number : ${#newmasterbinlogfiles[@]}"
        [[ -n "$debug" ]] && echoerr "parse each binlog file until watermark "

        for eachbinlogfile in "${newmasterbinlogfiles[@]}"
        do
                [[ -n "$debug" ]] && echoerr "eachbinlogfile :$eachbinlogfile"
                # we search for watermark in actual binlogfile

                masterGTID=$( sqlexec $master "show binlog events in '$eachbinlogfile'" | grep -i -e xid -e gtid  | grep "-A$offset" -e "$watermark"  | head -1 | cut -f6 | cut -d' ' -f3 )
                [[ -n "$debug" ]] && echoerr "masterGTID : $masterGTID"

                [[ ! -z "$masterGTID" ]] && break # as long as watermark is not matched, waterarkGTID stays unset/empty. Once watermarkGTID is set, we have found what we need and can exit the loop
        done

        echo "$masterGTID"
}

switchover()
{

        [[ -n "$debug" ]] && echoerr "switchover args : $*"
        [ $# -ne 2 ] && echo "Switchover function requires 2 args : 1. slave ip, 2. new master ip" && exit -1
        local slave=$1
        local master=$2

        #1   find the watermark on the slave
        [[ -n "$debug" ]] && echoerr "find watermark in relaylogfile"

        read watermark DDLoffset <<<$( getslavewatermark $slave )

        #2   find the watermark on the new master

        local masterGTID=$( getmasterGTIDfromwatermark $master $watermark $DDLoffset )

        #4 change slave settings and reconnect
        #4.1 stop slave
        [[ -n "$debug" ]] && echoerr "stop slave"
        sqlexec $slave 'stop slave'

        #4.2 change slave gtid
        [[ -n "$debug" ]] && echoerr "set gtid to $masterGTID"
        sqlexec $slave "set global gtid_slave_pos=$masterGTID"

        #4.3 change master shot
        [[ -n "$debug" ]] && echoerr "change master"
        sqlexec $slave 'change master to master_host=$newmasterip, master_use_gtid=slave_pos'

        #4.4 start slave
        [[ -n "$debug" ]] && echoerr "start slave"
        sqlexec $slave 'start slave'

return $retcode
}

findnewmaster()
{
        [[ -n "$debug" ]] && echoerr "findnewmaster args : $*"
        [ $# -ne 2 ] && echoerr "findnewmaster function requires 2 args : failed master ip & initiating maxscale monitor " && exit -4

        [[ -n "$debug" ]] && echoerr "find galera monitor of failed master"

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
