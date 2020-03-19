#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"

env_file="$WORKSPACE/$ENV_FILE"
cat <<EOF > $env_file
CONTRAIL_REGISTRY=$CONTAINER_REGISTRY
CONTAINER_TAG=$CONTRAIL_CONTAINER_TAG$TAG_SUFFIX
SCAN_REGISTRY=tungstenfabric
SCAN_REGISTRY_USER=$DOCKERHUB_USERNAME
SCAN_REGISTRY_PASSWORD=$DOCKERHUB_PASSWORD
SCAN_REPORTS_STASH=/tmp/scan_reports
SCAN_THRESHOLD=9.8
AQUASEC_HOST_IP=$AQUASEC_HOST_IP
AQUASEC_VERSION=4.6
AQUASEC_REGISTRY=registry.aquasec.com
AQUASEC_REGISTRY_USER=$AQUASEC_USERNAME
AQUASEC_REGISTRY_PASSWORD=$AQUASEC_PASSWORD
SCANNER_USER=$AQUASEC_SCANNER_USERNAME
SCANNER_PASSWORD=$AQUASEC_SCANNER_PASSWORD
EOF

scp -i $WORKER_SSH_KEY $SSH_OPTIONS $my_dir/$JOB_FILE $AQUASEC_HOST_USERNAME@$AQUASEC_HOST_IP:./
scp -i $WORKER_SSH_KEY $SSH_OPTIONS $env_file $AQUASEC_HOST_USERNAME@$AQUASEC_HOST_IP:./$ENV_FILE

echo "INFO: Prepare the Aquasec environment"
cat <<EOF | ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $AQUASEC_HOST_USERNAME@$AQUASEC_HOST_IP
export WORKSPACE=\$HOME
[ "${DEBUG,,}" == "true" ] && set -x
export PATH=\$PATH:/usr/sbin

DISTRO=$(cat /etc/*release | egrep '^ID=' | awk -F= '{print $2}' | tr -d \")
# setup additional packages
if [ x"\$DISTRO" == x"ubuntu" ]; then
  export DEBIAN_FRONTEND=noninteractive
  sudo -E apt-get install -y jq curl
else
  sudo yum -y install epel-release
  sudo yum install -y jq curl
fi
sudo docker system prune -a -f || true

EOF

echo "INFO: Start scanning containers"
cat <<EOF | ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $AQUASEC_HOST_USERNAME@$AQUASEC_HOST_IP
export WORKSPACE=\$HOME
source ./$ENV_FILE
sudo -E ./$JOB_FILE
EOF
echo "INFO: Scanning containers is done"
