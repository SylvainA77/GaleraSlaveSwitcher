#!/bin/bash
###
# failover.sh
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
# this bash script is intended to be triggered by maxscale event API
# up to 4 args are expected : failed master ip --initiator=$INITIATOR
#                               format of $initiator is : [IP]:port
#                             list of slaves to switchover --children=$CHILDREN
#                               format of $children is : [IP]:port,[IP]:port,*
#                             name of the monitor which detect the master_down event : --monitor=monitorname
#                             (optional) target new master : --target=[IP]:port
#                               target disable new master lookup in maxscale
###
# alternatively can be called from command line with only 2 args : 
#                           target new master : --target=[IP]:port
#                           list of slaves to switch over : --children=[IP]:port,[IP]:port,*
###
#TODO
###
# stderr & logs are sent to /var/log/failover.err

set +x

exec 2>/var/log/failover.err

debug=1

# we need all those juicy functions, don't we ?
source /var/lib/lib-switchover.sh
source /etc/.credentials

ARGS=$(getopt -o '' --long 'initiator:,children:,monitor:,target:' -- "$@")

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
        --monitor)
            shift;
            monitor=$1
            shift;
        ;;
        --target)
            shift;
            target=$1
            shift;
        ;;
        --)
            shift;
            break;
        ;;
    esac
done

#1 stopping slave to try and preserve relaylogs

# format of $children is : [IP]:port,[IP]:port,*
# so we have to break the string into an array of strings using , as a separator
IFS=',' read -ra childrens <<< "$children"
for child in "${childrens[@]}"
do
        [[ -n "$debug" ]] && echoerr "child:$child"
        thischild=$( echo $child | cut -d'[' -f2 | cut -d']' -f1 )
        sqlexec $thischild "stop slave"
        [[ -n "$debug" ]] && echoerr "sqlexec $thischild stop slave $?"
done

#2   find the new master
#2.1 if --target, then bypass maxscale
[[ -n "$target" ]] && masterip=$( echo $target | cut -d'[' -f2 | cut -d']' -f1 )
[[ -n "$debug" ]] && echoerr "target:$target"

#2.2 if --initiator, then call maxscale
[[ -n $"initiator" ]] && failedmaster=$( echo $initiator | cut -d'[' -f2 | cut -d']' -f1 )
[[ -n $"initiator" ]] && masterip=$( findnewmaster $failedmaster $monitor )
[[ -n "$debug" ]] && echoerr "initiator:$initiator"

[[ -n "$debug" ]] && echoerr "masterip:$masterip"

#3   perform the switchover on every oprhaned child to $masterip
# format of $children is : [IP]:port,[IP]:port,*
# so we have to break the string into an array of strings using , as a separator
IFS=',' read -ra childrens <<< "$children"
for child in "${childrens[@]}"
do
        # format of $child is still [IP]:port
        # so we have to extract the ip using both brackets as separators
        thischild=$( echo $child | cut -d'[' -f2 | cut -d']' -f1 )
        switchover $thischild $masterip
        [[ -n "$debug" ]] && echoerr "switchover $thischild $masterip $?"
done

exit $?
