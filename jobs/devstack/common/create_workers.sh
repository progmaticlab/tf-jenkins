#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NODES=${NODES:-'medium:1'}

function get_nodes_ips() {
  node=$1
  node_type=`echo $node | cut -d':' -f1`
  node_count=`echo $node | cut -d':' -f2`
  export VM_TYPE=$node_type
  export NODES_COUNT=$node_count
  "$my_dir/../../../infra/${SLAVE}/create_workers.sh "

  echo $INSTANCES_IPS
}

CONTROLLERS=`echo $NODES | cut -d',' -f1`
CONTROLLER_NODES=`get_nodes_ips $CONTROLLERS`
CONTROLLER_IDS=$INSTANCE_IDS

#support single node case and old behavior
instance_ip=`echo $CONTROLLER_NODES | cut -d',' -f1`

if [[ $NODES =~ ',' ]] ; then
  AGENTS=`echo $NODES | cut -d',' -f2`
  AGENT_NODES=`get_nodes_ips $AGENTS`
  AGENT_IDS=$INSTANCE_IDS
else
  AGENT_IDS=""
  AGENT_NODES=$CONTROLLER_NODES
fi

if [[ -n $CONTROLLER_NODES && -n $AGENT_NODES ]] ; then
  INSTANCE_IDS="$(echo "$CONTROLLER_IDS $AGENT_IDS" | sed 's/ /,/g')"
  echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"
  echo "export CONTROLLER_NODES=$CONTROLLER_NODES" >> "$ENV_FILE"
  echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
  echo "export AGENT_NODES=$AGENT_NODES" >> "$ENV_FILE"
  exit 0
else
  echo "ERROR: Instances were not created. Exit"
  exit 1
fi
