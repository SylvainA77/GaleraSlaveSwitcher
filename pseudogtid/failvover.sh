#!/bin/bash
# failover.sh

  exec 1>/var/log/failover.log
  exec 2>/var/log/failover.err

# user:password pair, must have administrative privileges.
user=root:x15ye7yW3hH0u9T0
# user:password pair, must have REPLICATION SLAVE privileges.
repluser=repl:LD8s5yq2u2SS
monscaleuser=monscale:T5dQ7rwF95kW

debug=1

  [[ -n "$debug" ]] &&  echo "`date`/ params:$@"

ARGS=$(getopt -o '' --long 'event:,initiator:,livenodes:,cluster:' -- "$@")

eval set -- "$ARGS"

while true; do
    case "$1" in
        --event)
            shift;
            event=$1
            shift;
        ;;
        --initiator)
            shift;
            initiator=$1
            shift;
        ;;
        --livenodes)
            shift;
            livenodes=$1
            shift;
        ;;
        --cluster)
            shift;
            cluster=$1
            shift;
        ;;
        --)
            shift;
            break;
        ;;
    esac
done
  [[ -n "$debug" ]] && echo " `date` / livenodes:$livenodes / event:$event / initiator:$initiator / cluster:$cluster /debug:$debug"

  monuser=`echo $monscaleuser | cut -d':' -f1`
  monpasswd=`echo $monscaleuser | cut -d':' -f2`

#1 recuperer le nouveau master du monitor qui viens de declencher l event
  read new_master_str new_master <<<$(echo "list servers" | maxadmin -pmariadb | grep Master | grep Synced | grep "$cluster" | cut -d'|' -f1,2)

  new_master=`echo "$new_master" | cut -d'|' -f 2 | tr -d " "`
  range=`echo "${new_master%?}"`

  [[ -n "$debug" ]] && echo "range:$range"
  [[ -n "$debug" ]] && echo "new_master=$new_master"
  [[ -n "$debug" ]] && echo "new_master_str=$new_master_str"
#2 recuperer les noms des fichiers binlog du nouveau master
  binlogs=$(mysql -u$monuser -p$monpasswd -h $new_master --xml  -B -e "show binary logs" | grep Log_name | tail -2 |cut -d'>' -f2 | cut -d'<' -f1 | tr "\n" :)

  [[ -n "$debug" ]] && echo "binlogs:$binlogs"

# lister les slaves
  slavelist=$(echo "list servers" | maxadmin -pmariadb | grep -v "$cluster" | grep Running | grep "$range" | cut -d'|' -f2 | tr "\n" :)

[[ -n "$debug" ]] && echo "slavelist:$slavelist"

#pour chaque slave :
  for node in `echo $slavelist | tr : "\n"`
  do
  [[ -n "$debug" ]] && echo "node:$node"
  [[ -n "$node" ]] || break

#3 recuperer le pseudo GTID
  pseudo_gtid=$( mysql -u$monuser -p$monpasswd -h $node -B -e "select * from pseudo_gtid.pseudo_gtid_v" |tail -1)
  [[ -n "$debug" ]] && echo "pseudo_gtid:$pseudo_gtid"
  [[ -n "$pseudo_gtid" ]] ||  exit 1

#4 trouver sa position dans le binlog local et l'offset; determiner si le changement de master est necessaire
  slave_master=$( mysql -u$monuser -p$monpasswd -h $node --table  -B -e "show slave status"  | grep bin | cut -d'|' -f3 )
  [[ -n "$debug" ]] && echo "new_master:$new_master"
  [[ -n "$debug" ]] && echo "slave_master:$slave_master"
  [[ "$slave_master" -eq "$new_master" ]] && mysql -u$monuser -p$monpaswd -h $node -e "start slave;"
  [[ "$slave_master" -eq "$new_master_str" ]] && echo "slave master = new_master" && break

  logbinaire=$( mysql -u$monuser -p$monpasswd -h $node --table  -B -e "show master status"  | grep bin | cut -d'|' -f2 | tr -d ' ' )
  echo "logbinaire=$logbinaire;node=$node;pseudo_gtid=$pseudo_gtid;monscaleuser=$monscaleuser;"
  gtid_pos=$(mysql -u$monuser -p$monpasswd -h $node --table -B -e "show binlog events in '$logbinaire'"|grep "$pseudo_gtid"|cut -d'|' -f3 | tr -d ' ')
  offset=$( mysql -u$monuser -p$monpasswd -h $node --table -B -e "show binlog events in '$logbinaire' from $gtid_pos" | wc -l)

  offset=`expr $offset - 2`

  [[ -n "$debug" ]] && echo "logbinaire:$logbinaire"
  [[ -n "$debug" ]] && echo "gtid_pos:$gtid_pos"
  [[ -n "$debug" ]] && echo "offset:$offset"

#5 trouver le gtid chez le nouveau master
  master_log_pos=""
  master_log_file=""

  for file in `mysql -u$monuser -p$monpasswd -h $new_master --xml  -B -e "show binary logs" | grep Log_name | tr '<>' '|' | cut -d'|' -f3`
  do
    [[ -n "$file" ]] || break
    [[ -n "$debug" ]] && echo "file=$file"
    master_log_pos=$(mysql -u$monuser -p$monpasswd -h $new_master -B -e "show binlog events in '$file'" | grep "$pseudo_gtid"  | cut -d'|' -f3 | tr -d ' ')
    [[ -n "$debug" ]] && echo "master_log_pos_tmp:$master_log_pos"
    [[ -n "$master_log_pos" ]] && master_log_file=`echo "$file"` && break 1
  done

  [[ -n "$debug" ]] && echo "master_log_pos:$master_log_pos"
  [[ -n "$debug" ]] && echo "master_log_file:$master_log_file"
  [[ -n "$master_log_pos" ]] || exit 1

#6 stop slave
#7 change master to + sql slave skip counter
  mysql -u$monuser -p$monpasswd -h $node -e "stop slave; change master to master_host='$new_master', master_log_file='$master_log_file', masterlog_pos=$master_log_pos; set global sql_slave_skip_counter=$offset;"

#8 start slave
  mysql -u$monuser -p$monpasswd | cut -d':' -f2` -h $node -e "start slave;"

 done
