#!/bin/bash
# failover.sh
# wrapper script to repmgr
# needs : slave ip, user with replication client on both slave & whole cluster : maxscale monitor user is a good fiit.
  exec 1>/var/log/failover.log
  exec 2>/var/log/failover.err

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
#2   find the watermark on each children
        switchover $children $masterip monitor monitor

exit $?
