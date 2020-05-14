#!/bin/bash -eEx
set -o pipefail

# WARNING !!!!
# it creates only one machine for now !

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"
source "$my_dir/functions.sh"
source "$WORKSPACE/global.env"

# parameters for workers
VM_TYPE=${VM_TYPE:-'medium'}
NODES_COUNT=${NODES_COUNT:-1}

ENV_FILE="$WORKSPACE/stackrc.$JOB_NAME.env"
touch "$ENV_FILE"
echo "export AWS_REGION=${AWS_REGION}" > "$ENV_FILE"
echo "export ENVIRONMENT_OS=${ENVIRONMENT_OS}" >> "$ENV_FILE"

IMAGE_VAR_NAME="IMAGE_${ENVIRONMENT_OS^^}"
IMAGE=${!IMAGE_VAR_NAME}
echo "export IMAGE=$IMAGE" >> "$ENV_FILE"

IMAGE_SSH_USER_VAR_NAME="IMAGE_${ENVIRONMENT_OS^^}_SSH_USER"
IMAGE_SSH_USER=${!IMAGE_SSH_USER_VAR_NAME}
echo "export IMAGE_SSH_USER=$IMAGE_SSH_USER" >> "$ENV_FILE"

VM_TYPE=${VM_TYPE:-'medium'}
INSTANCE_TYPE=${VM_TYPES[$VM_TYPE]}
if [[ -z "$INSTANCE_TYPE" ]]; then
    echo "ERROR: invalid VM_TYPE=$VM_TYPE"
    exit 1
fi

function clean_up_job () {
   local job_tag=$1
   local termination_list="$(list_instances ${job_tag})"
   if [[ -n "${termination_list}" ]] ; then
      echo "INFO: Instances to terminate: $termination_list"
      terminate_instances $termination_list
   fi
 }

function wait_for_instance_availability () {
  local instance_id=$1
  aws ec2 wait instance-running --region $AWS_REGION \
      --instance-ids $instance_id
  instance_ip=$(get_instance_ip $instance_id)

  timeout 300 bash -c "\
  while /bin/true ; do \
    ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip 'uname -a' && break ; \
    sleep 5 ; \
  done"

  export instance_ip
  image_up_script=${OS_IMAGES_UP["${ENVIRONMENT_OS^^}"]}
  if [[ -n "$image_up_script" && -e ${my_dir}/../hooks/${image_up_script}/up.sh ]] ; then
    ${my_dir}/../hooks/${image_up_script}/up.sh
  fi
}

# Spin VM
iname="${VM_TYPE}-$BUILD_TAG"
bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":120,"DeleteOnTermination":true}}'
job_tag="$iname"

for (( i=1; i<=$VM_RETRIES ; ++i )) ; do
  ready_nodes=0
  INSTANCE_IDS=""
  INSTANCE_IPS=""

  # wait for resource
  while true; do
    INSTANCES_COUNT=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters  "Name=instance-state-code,Values=16" \
                  "Name=tag:SLAVE,Values=${SLAVE}" \
        --query 'Reservations[*].Instances[*].[InstanceId]'\
        --output text | wc -l)
    [[ (( "$INSTANCES_COUNT" + "$NODES_COUNT" )) -lt "$MAX_COUNT" ]] && break
    sleep 60
  done

  INSTANCE_IDS=$(aws ec2 run-instances \
      --region $AWS_REGION \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$iname},{Key=PipelineBuildTag,Value=$PIPELINE_BUILD_TAG},{Key=JobTag,Value=$iname},{Key=SLAVE,Value=aws},{Key=DOWN,Value=${OS_IMAGES_DOWN["${ENVIRONMENT_OS^^}"]}}]" \
      --block-device-mappings "[${bdm}]" \
      --image-id $IMAGE \
      --count $NODES_COUNT \
      --instance-type $INSTANCE_TYPE \
      --key-name worker \
      --security-group-ids $AWS_SG \
      --subnet-id $AWS_SUBNET | \
      jq -r '.Instances[].InstanceId')
  for instance_id in $INSTANCE_IDS ; do
    wait_for_instance_availability $instance_id
    if [[ $? != 0 ]] ; then
      echo "ERROR: Node $instance_id is not available. Clean up"
      clean_up_job ${job_tag}
      break
    fi

    ready_nodes=$(( ready_nodes + 1 ))

    instance_ip=$(get_instance_ip $instance_id)
    INSTANCE_IPS+="$instance_ip,"
  done

  if (( ready_nodes == NODES_COUNT )) ; then
    echo "export INSTANCE_IDS=$INSTANCE_IDS" >> "$ENV_FILE"
    echo "export INSTANCE_IPS=$INSTANCE_IPS" >> "$ENV_FILE"

    instance_id=`echo $INSTANCE_IDS | cut -d' ' -f1`
    echo "export instance_id=$instance_id" >> "$ENV_FILE"
    instance_ip=`echo $INSTANCE_IPS | cut -d',' -f1`
    echo "export instance_ip=$instance_ip" >> "$ENV_FILE"
    exit 0
  else
     echo "INFO: Nodes are not created. Retry"
     continue
  fi
done

echo "INFO: Nodes are not created."
touch "$ENV_FILE"
exit 1
