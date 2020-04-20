#!/bin/bash -eE
set -o pipefail
DEBUG='true'
[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"
source "$my_dir/functions.sh"
#source "$WORKSPACE/global.env"

#ENV_FILE="$WORKSPACE/stackrc.$JOB_NAME.env"
ENV_FILE="./stackrc.env"
touch "$ENV_FILE"
echo "export OS_REGION_NAME=${OS_REGION_NAME}" > "$ENV_FILE"
echo "export ENVIRONMENT_OS=${ENVIRONMENT_OS}" >> "$ENV_FILE"

IMAGE_TEMPLATE_NAME="${OS_IMAGES["${ENVIRONMENT_OS^^}"]}"
IMAGE_NAME=$(openstack image list --status active -c Name -f value | grep "${IMAGE_TEMPLATE_NAME}" | sort -nr | head -n 1)
IMAGE=$(openstack image show -c id -f value "$IMAGE_NAME")
echo "export IMAGE=$IMAGE" >> "$ENV_FILE"

IMAGE_SSH_USER=${OS_IMAGE_USERS["${ENVIRONMENT_OS^^}"]}
echo "export IMAGE_SSH_USER=$IMAGE_SSH_USER" >> "$ENV_FILE"

VM_TYPE=${VM_TYPE:-'medium'}
INSTANCE_TYPE=${VM_TYPES[$VM_TYPE]}
if [[ -z "$INSTANCE_TYPE" ]]; then
    echo "ERROR: invalid VM_TYPE=$VM_TYPE"
    exit 1
fi
echo "INFO: VM_TYPE=$VM_TYPE"

#multinodes parameters definition
CONTROLLER_NODES_COUNT=${CONTROLLER_NODES_COUNT:-1}
AGENT_NODES_COUNT=${AGENT_NODES_COUNT:-0}
BUILD_TAG=${BUILD_TAG:-'latest'}
VM_RETRIES=${VM_RETRIES:-5}
TOTAL_INSTANCES=$(( CONTROLLER_NODES_COUNT + AGENT_NODES_COUNT ))
CONTROLLER_PREFIX="CONTROLLER"
AGENT_PREFIX="AGENT"
CONTROLLER_NODES=""
AGENT_NODES=""
INSTANCE_IDS=""
CONTROLLER_INSTANCE_IDS=""
AGENT_INSTANCE_IDS=""
#find vcpu for flavor
INSTANCE_VCPU="$(nova flavor-show $INSTANCE_TYPE | grep vcpus | awk -F "|" '{print $3}')"
INSTANCE_VCPU=$(( $INSTANCE_VCPU + 0 ))
TOTAL_VCPU=$(( INSTANCE_VCPU * TOTAL_INSTANCES ))
# wait for free resource
while true; do
  [[ "$(($(nova list --tags "SLAVE=$SLAVE"  --field status | grep -c 'ID\|ACTIVE') + TOTAL_INSTANCES ))" -lt "$MAX_COUNT_VM" ]] && break
  echo "INFO: waiting for free worker"
  sleep 60
done

while true; do
  [[ "$(($(nova quota-show --detail | grep cores | sed 's/}.*/}/'| tr -d "}" | awk '{print $NF}') + TOTAL_VCPU ))" -lt "$MAX_COUNT_VCPU" ]] && break
  echo "INFO: waiting for CPU resources"
  sleep 60
done

function create_multiple_instances () {  
  NODES=""
  NODES_IDS=""
  local NODES_COUNT=$1
  local object_name_prefix=$2
  local name="${object_name_prefix}-${BUILD_TAG}"
  local instance_id=""
  local instance_ip=""
  for (( i=1; i<=$VM_RETRIES ; ++i ))
  do
    echo "INFO: Try to create controller nodes. Attemp ${i}"
    nova boot --flavor ${INSTANCE_TYPE} \
              --security-groups ${OS_SG} \
              --key-name=worker \
              --min-count ${NODES_COUNT} \
              --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
              --nic net-name=${OS_NETWORK} \
              --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
              --poll \
              $name
    local ready_nodes=0
    for ((j=1 ; j<=$NODES_COUNT; ++j))
    do
      if (( NODES_COUNT == 1 )); then
        object_name="${name}-"
      else      
        object_name="${name}-${j}"
      fi
      object_names+="$object_name,"  
      instance_id=$(openstack server show $object_name -c id -f value | tr -d '\n')
      NODES_IDS+="$instance_id,"
      instance_ip=$(get_instance_ip $object_name)
      NODES+="${instance_ip},"
      timeout 300 bash -c "\
      while /bin/true ; do \
          ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
          sleep 10 ; \
      done"
      if [[ $? != 0 ]] ; then
        echo "ERROR: VM $instance_id with ip $instance_ip is unreachable. Clean up and retry "
        INSTANCE_IDS=$NODES_IDS $my_dir/remove_workers.sh
        break
      fi
      image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
      if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
        ${my_dir}/../hooks/${image_up_script}/up.sh
      fi
      ready_nodes=$(( ready_nodes + 1 ))
    done
    if [[ "$ready_nodes" == $NODES_COUNT ]] ; then
      echo "INFO: Controller nodes were created successfully."
      echo "INFO: Controller nodes list is ${NODES}"
      instance_ip="$(echo ${NODES} | cut -d, -f1)"
      echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
      break
    else
      NODES_IDS=""
      NODES=""
      continue
    fi
  done
  if [[ -z "$NODES" && "$NODES_COUNT" != 0 ]] ; then
    echo "ERROR: ${object_name_prefix} nodes are not created; Exit"
    exit 1
  fi
}

function create_single_instance () {
  for (( i=1; i<=$VM_RETRIES ; ++i ))
  do 
    OBJECT_NAME=$BUILD_TAG
    nova boot --flavor ${INSTANCE_TYPE} \
              --security-groups ${OS_SG} \
              --key-name=worker \
              --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
              --nic net-name=${OS_NETWORK} \
              --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
              --poll \
              $OBJECT_NAME
    
    instance_id=$(openstack server show $OBJECT_NAME -c id -f value | tr -d '\n')
    instance_ip=$(get_instance_ip $OBJECT_NAME)
    timeout 300 bash -c "\
    while /bin/true ; do \
        ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
        sleep 10 ; \
    done"
    if [[ $? != 0 ]] ; then
      echo "ERROR: VM $instance_id with ip $instance_ip is unreachable. Clean up and retry "
      INSTANCE_IDS="$instance_id," $my_dir/remove_workers.sh
      continue
    else
      INSTANCE_IDS="$instance_id,"
      echo "INFO: VM $instance_id with ip $instance_ip is created with success."
      echo "export INSTANCE_IDS=$instance_id" >> "$ENV_FILE"
      echo "export instance_ip=$instance_ip" >> "$ENV_FILE" 
      image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
      if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
        ${my_dir}/../hooks/${image_up_script}/up.sh
      fi
    fi
  done
}
if (( TOTAL_INSTANCES == 1 )) ; then
  create_single_instance
fi
if (( TOTAL_INSTANCES > 1 )) ; then
  if (( CONTROLLER_NODES_COUNT > 0)) ; then
    create_multiple_instances $CONTROLLER_NODES_COUNT $CONTROLLER_PREFIX
    CONTROLLER_NODES=$NODES
    CONTROLLER_INSTANCE_IDS=$INSTANCE_IDS
  fi
  if (( AGENT_NODES_COUNT > 0)) ; then
    create_multiple_instances $AGENT_NODES_COUNT $AGENT_PREFIX
    CONTROLLER_NODES=$NODES
    CONTROLLER_INSTANCE_IDS=$INSTANCE_IDS
  fi
fi

# echo "INFO: run nova boot..."
# #Create CONTROLLER nodes
# for (( i=1; i<=$VM_RETRIES ; ++i ))
# do
#   echo "INFO: Try to create controller nodes. Attemp ${i}"
#   CONTROLLER_OBJECT_NAMES=""
#   CONTROLLER_OBJECT_NAME="CONTROLLER-${BUILD_TAG}"
#   nova boot --flavor ${INSTANCE_TYPE} \
#             --security-groups ${OS_SG} \
#             --key-name=worker \
#             --min-count ${CONTROLLER_NODES_COUNT} \
#             --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
#             --nic net-name=${OS_NETWORK} \
#             --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
#             --poll \
#             $CONTROLLER_OBJECT_NAME
#   ready_nodes=0
#   for ((j=1 ; j<=$CONTROLLER_NODES_COUNT; ++j))
#   do    
#     object_name="${CONTROLLER_OBJECT_NAME}-${j}"
#     CONTROLLER_OBJECT_NAMES+="$object_name,"
#     instance_id=$(openstack server show $object_name -c id -f value | tr -d '\n')
#     CONTROLLER_INSTANCE_IDS+="$instance_id,"
#     instance_ip=$(get_instance_ip $object_name)
#     CONTROLLER_NODES+="${instance_ip},"
#     timeout 300 bash -c "\
#     while /bin/true ; do \
#         ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
#         sleep 10 ; \
#     done"
#     if [[ $? != 0 ]] ; then
#       echo "ERROR: VM $instance_id with ip $instance_ip is unreachable. Clean up and retry "
#       INSTANCE_IDS=$CONTROLLER_INSTANCE_IDS $my_dir/remove_workers.sh
#       break
#     fi
#     image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
#     if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
#       ${my_dir}/../hooks/${image_up_script}/up.sh
#     fi
#     ready_nodes=$(( ready_nodes + 1 ))
#   done
#   if [[ "$ready_nodes" == $CONTROLLER_NODES_COUNT ]] ; then
#      echo "INFO: Controller nodes were created successfully  "
#      echo "INFO: Controller nodes list is ${CONTROLLER_NODES}"
#      instance_ip="$(echo ${CONTROLLER_NODES} | cut -d, -f1)"
#      echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
#      break
#   else
#      CONTROLLER_INSTANCE_IDS=""
#      CONTROLLER_NODES=""
#      continue
#   fi
# done
# if [[ -z "$CONTROLLER_NODES" && "$CONTROLLER_NODES_COUNT" != 0 ]] ; then
#   echo "ERROR: ${CONTROLLER_NODES} are not created; Exit"
#   exit 1
# fi
# for (( i=1; i<=$VM_RETRIES ; ++i ))
# do
#   echo "INFO: Try to create agent nodes. Attemp ${i}"
#   AGENT_OBJECT_NAMES=""
#   AGENT_OBJECT_NAME="AGENT-${BUILD_TAG}"
#   nova boot --flavor ${INSTANCE_TYPE} \
#             --security-groups ${OS_SG} \
#             --key-name=worker \
#             --min-count ${AGENT_NODES_COUNT} \
#             --tags "PipelineBuildTag=${PIPELINE_BUILD_TAG},SLAVE=${SLAVE},DOWN=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}" \
#             --nic net-name=${OS_NETWORK} \
#             --block-device source=image,id=$IMAGE,dest=volume,shutdown=remove,size=120,bootindex=0 \
#             --poll \
#             $AGENT_OBJECT_NAME
#   ready_nodes=0
#   for ((j=1 ; j<=$AGENT_NODES_COUNT; ++j))
#   do    
#     object_name="${AGENT_OBJECT_NAME}-${j}"  
#     AGENT_OBJECT_NAMES+="$object_name,"  
#     instance_id=$(openstack server show $object_name -c id -f value | tr -d '\n')
#     AGENT_INSTANCE_IDS+="$instance_id,"
#     instance_ip=$(get_instance_ip $object_name)
#     AGENT_NODES+="${instance_ip},"
#     timeout 300 bash -c "\
#     while /bin/true ; do \
#         ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
#         sleep 10 ; \
#     done"
#     if [[ $? != 0 ]] ; then
#       echo "ERROR: VM $instance_id with ip $instance_ip is unreachable. Clean up and retry "
#       INSTANCE_IDS=$AGENT_INSTANCE_IDS $my_dir/remove_workers.sh      
#       break
#     fi
#     image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
#     if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
#       ${my_dir}/../hooks/${image_up_script}/up.sh
#     fi
#     ready_nodes=$(( ready_nodes + 1 ))
#   done
#   if [[ "$ready_nodes" == $AGENT_NODES_COUNT ]] ; then
#      echo "INFO: Agent nodes were created successfully  "
#      echo "INFO: Agent nodes list is ${AGENT_NODES}"     
#      break
#   else
#      AGENT_INSTANCE_IDS=""
#      AGENT_NODES=""
#      continue
#   fi
# done
# if [[ -z "$AGENT_NODES" && "$AGENT_NODES_COUNT" != 0 ]] ; then
#   echo "ERROR: ${AGENT_NODES} are not created; Exit"
#   exit 1
# fi
CONTROLLER_NODES=$(echo "$CONTROLLER_NODES" | sed 's/\(.*\),/\1 /')
AGENT_NODES=$(echo "$AGENT_NODES" | sed 's/\(.*\),/\1 /')
AGENT_INSTANCE_IDS=$(echo "$AGENT_INSTANCE_IDS" | sed 's/\(.*\),/\1 /')
CONTROLLER_INSTANCE_IDS=$(echo "$CONTROLLER_INSTANCE_IDS" | sed 's/\(.*\),/\1 /')
INSTANCE_IDS="$AGENT_INSTANCE_IDS,$CONTROLLER_INSTANCE_IDS"
echo "export CONTROLLER_NODES=$CONTROLLER_NODES" >> "$ENV_FILE"
echo "export AGENT_NODES=$AGENT_NODES" >> "$ENV_FILE"
echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"
###At the end of the script I have CONTROLLER_NODES='ip1,ip2,ip3' and AGENT_NODES='ip1,ip2,ip3'
