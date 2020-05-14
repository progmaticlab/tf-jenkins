#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NODES=${NODES:-'medium:1'}

controllers=`echo $NODES | cut -d',' -f1`
controller_node_type=`echo $controllers | cut -d':' -f1`
controller_node_count=`echo $controllers | cut -d':' -f2`
export VM_TYPE=$controller_node_type
export NODES_COUNT=$controller_node_count
"$my_dir/../../../infra/${SLAVE}/create_workers.sh"

ENV_FILE="$WORKSPACE/stackrc.$JOB_NAME.env"
CONTROLLER_IDS=`cat $ENV_FILE | grep INSTANCE_IDS | cut -d'=' -f2`
CONTROLLER_NODES=`cat $ENV_FILE | grep INSTANCE_IPS | cut -d'=' -f2`
sed -i '/INSTANCE_IDS=/c\' "$ENV_FILE"
sed -i '/INSTANCE_IPS=/c\' "$ENV_FILE"

#support single node case and old behavior
instance_ip=`echo $CONTROLLER_NODES | cut -d',' -f1`

if [[ $NODES =~ ',' ]] ; then
  agents=`echo $NODES | cut -d',' -f2`
  agent_node_type=`echo $agents | cut -d':' -f1`
  agent_node_count=`echo $agents | cut -d':' -f2`
  export VM_TYPE=$agent_node_type
  export NODES_COUNT=$agent_node_count
  "$my_dir/../../../infra/${SLAVE}/create_workers.sh"

  AGENT_IDS=`cat $ENV_FILE | grep INSTANCE_IDS | cut -d'=' -f2`
  AGENT_NODES=`cat $ENV_FILE | grep INSTANCE_IPS | cut -d'=' -f2`
  sed -i '/INSTANCE_IDS=/c\' "$ENV_FILE"
  sed -i '/INSTANCE_IPS=/c\' "$ENV_FILE"
else
  AGENT_IDS=""
  AGENT_NODES=$CONTROLLER_NODES
fi

if [[ -n $CONTROLLER_NODES && -n $AGENT_NODES ]] ; then
  INSTANCE_IDS="$(echo "$CONTROLLER_IDS $AGENT_IDS" | sed 's/ /,/g')"
  sed -i '/instance_id=/c\' "$ENV_FILE"
  sed -i '/instance_ip=/c\' "$ENV_FILE"
  echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"
  echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
  echo "export CONTROLLER_NODES=$CONTROLLER_NODES" >> "$ENV_FILE"
  echo "export AGENT_NODES=$AGENT_NODES" >> "$ENV_FILE"
  exit 0
else
  echo "ERROR: Instances were not created. Exit"
  exit 1
fi
