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
# hence only 2 args are exepected : failed master ip --initiator=$INITIATOR
# and list of slaves to switchover --children=$CHILDREN
#TODO : add optional --target=$NEWMASTERIP parameter for manual triggering w/out maxscale
###
# stderr & logs are sent to /var/log/failover.err


exec 2>/var/log/failover.err

debug=1

[ $debug ] && echo "DEBUG MODE ENABLED" 

# we need all those juicy functions don't we ?
source /var/lib/lib-switchover.sh
source /etc/.credentials

ARGS=$(getopt -o '' --long 'initiator:,children:,monitor:' -- "$@")

[ $debug ] && echo "DEBUG : ARGS : $ARGS" 

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

[ $debug ] && echo "DEBUG : IFS 1 : $IFS " 

for child in "${childrens[@]}"
do
        [[ -n "$debug" ]] && echoerr "child:$child"
        thischild=$( echo $child | cut -d'[' -f2 | cut -d']' -f1 )
        sqlexec $thischild "stop slave"
        [[ -n "$debug" ]] && echoerr "sqlexec $thischild stop slave $?"
done

#2   find the new master
failedmaster=$( echo $initiator | cut -d'[' -f2 | cut -d']' -f1 )
masterip=$( findnewmaster $failedmaster $monitor )
[[ -n "$debug" ]] && echoerr "newmasterip:$masterip"
[ $debug ] && echo "DEBUG : Find new master : failedmaster : $failedmaster " 
[ $debug ] && echo "DEBUG : Find new master : masterip : $masterip  " 

#3   perform the switchover on every oprhaned child

# format of $children is : [IP]:port,[IP]:port,*
# so we have to break the string into an array of strings using , as a separator
IFS=',' read -ra childrens <<< "$children"
[ $debug ] && echo "DEBUG : IFS 2 : $IFS " 
for child in "${childrens[@]}"
do
        # format of $child is still [IP]:port
        # so we have to extract the ip using both brackets as separators
        thischild=$( echo $child | cut -d'[' -f2 | cut -d']' -f1 )
        switchover $thischild $masterip
        [[ -n "$debug" ]] && echoerr "switchover $thischild $masterip $?"
done

[ $debug ] && echo "DEBUG : End of file failover.sh " 

exit $?
