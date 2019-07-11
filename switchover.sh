#!/bin/bash
# switchover.sh
# just a function lib
# needs : 1. slave ip,
#         2. new master ip,
#         3. user with replication client on both slave & whole cluster : maxscale monitor user is a good fit
  exec 1>/var/log/switchover.log
  exec 2>/var/log/switchover.err

sqlexec()
{
        [ $# -ne 2 ] && echo "sqlexec function requires 2 args : 1. credentials, 2. sql statement to execute" && exit -2
        mysql -B --skip_column_names $1 -e $2
        exit $?
}

switchover()
        [ $# -ne 4 ] && echo "Switchover fucnction requires 4 args : 1. slave ip, 2. new master ip, 3. user, 4. password" && exit -1

        mastercredentials="-u$3 -p$4 -h $2"
        slavecredentials="-u$3 -p$4 -h $1"

        #1 wait until slave is fully up to date
        while [ $readlogpos -ne $execlogpos ]
        do
                read readlogpos execlogpos <<<$( sqlexec $slavecredentials 'show slave status' | cut -f7,22 )
        done

        #2   find the watermark on the slave
        #2.1 find the last binlog file
        slavelastbinlogfile=$( sqlexec $slavecredentials 'show master status' | cut -f1 )

        #2.2 find the watermark (xid) on the last binlog entry
        watermark=$( sqlexec $slavecredentials "show binlog events in '$binlogfile'" | grep -i commit | tail -1 | cut -f6 | cut -d'*' -f2 | xargs )

        #3   find the watermark on the new master
        #3.1 find the list of binlog files in reverse order
        newmasterbinlogfiles =( $( sqlexec $mastercredentials 'show binary logs' | cut -f1 | tac ) )

        for eachbinlogfile in "${newmasterbinlogfiles[@]}"
        do
                watermarkGTID=$( sqlexec $mastercredentials "show binlog events in '$eachbinlogfile'" | grep -i -e commit -e begin | grep -i -e "$watermark" -B1 | head -1 | cut -f6 | cut -d' ' -f3)
                [[ ! -z "$watermarkGTID" ]] && break # as long as watermark is not matched, waterarkGTID stays unset/empty. Once watermarkGTID is set, we have found what we need and can exit the loop
        done

        #4 change slave settings and reconnect
        #4.1 stop slave
        sqlexec $slavecredentials 'stop slave'

        #4.2 change slave gtid
        sqlexec $slavecredentials "set global gtid_slave_pos=$watermakrGTID"
        
        #4.3 change master shot
        sqlexec $slavecredentials "change master to master_host=$newmasterip, master_use_gtid=slave_pos"

        #4.4 start slave
        sqlexec $slavecredentials 'start slave'

return $retcode
}

findnewmaster()
{
        [ $# -ne 1 ] && echo "findnewmaster function requires only 1 arg : slave ip" && exit -3

        #1.2 find which galeramonitor master was part of
        monitor=$( maxctrl --tsv show servers | grep -e ^Server -e ^Address  -e ^State -e ^Monitors | grep -C2 $1 | grep -A1 Synced  | tail -1 | cut -f2 )

        #1.3 find on other synced node in the same monitor
        newmasteraddress=$( maxctrl --tsv show servers | grep -e ^Address  -e ^State -e ^Monitors | grep -B3 $monitor | grep -B1 Synced | head -1 |cut -f2 )

        return $newmasteraddress
}

exit 0
