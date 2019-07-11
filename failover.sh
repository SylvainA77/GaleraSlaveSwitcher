#!/bin/bash
# failover.sh
# wrapper script to repmgr
# needs : slave ip, user with replication client on both slave & whole cluster : maxscale monitor user is a good fiit.
  exec 1>/var/log/failover.log
  exec 2>/var/log/failover.err

# we need all those juicy functions don't we ?
source ./switchover.sh

ARGS=$(getopt -o '' --long 'initiator:,children:' -- "$@")

eval set -- "$ARGS"

while true; do
    case "$1" in
        --initiator)
            shift;
            initiator=$1
            shift;
        ;;
        --children)
            shift;
            children=$1
            shift;
        ;;
        --)
            shift;
            break;
        ;;
    esac
done

#1   find the new master
        masterterip=$( findnewmaster $initiator )
#2   perform the switchover on every oprhaned child

        # format of $children is : [IP]:port,[IP]:port,*
        # so we have to break the string into an array of strings using , as a separator
        IFS=',' read -ra childrens <<< "$children"
        for child in `${children[@]}`
        do
                # format of $child is still [IP]:port
                # so we have to extract the ip using both brackets as separators
                thischild=$( echo $child | cut -d'[' -f2 | cut 'd']' -f1 )
                switchover $thischild $masterip monitor monitor
        done
exit $?
