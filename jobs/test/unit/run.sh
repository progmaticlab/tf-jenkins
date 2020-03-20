#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"

rsync -a -e "ssh -i $WORKER_SSH_KEY $SSH_OPTIONS" $WORKSPACE/src $IMAGE_SSH_USER@$instance_ip:./

echo "INFO: UT started"

function run_over_ssh() {
  res=0
cat <<EOF | ssh -i $WORKER_SSH_KEY $SSH_OPTIONS $IMAGE_SSH_USER@$instance_ip || res=1
[ "${DEBUG,,}" == "true" ] && set -x
export WORKSPACE=\$HOME
export DEBUG=$DEBUG
export PATH=\$PATH:/usr/sbin

# dont setup own registry
export CONTRAIL_DEPLOY_REGISTRY=0

export REGISTRY_IP=$REGISTRY_IP
export REGISTRY_PORT=$REGISTRY_PORT
export SITE_MIRROR=http://${REGISTRY_IP}/repository

export CONTRAIL_CONTAINER_TAG=$CONTRAIL_CONTAINER_TAG$TAG_SUFFIX

# to not to bind contrail sources to container
export CONTRAIL_DIR=""

export IMAGE=$REGISTRY_IP:$REGISTRY_PORT/tf-developer-sandbox
export DEVENVTAG=$CONTRAIL_CONTAINER_TAG$TAG_SUFFIX

# Some tests (like test.test_flow.FlowQuerierTest.test_1_noarg_query) expect
# PST timezone, and fail otherwise.
timedatectl
sudo timedatectl set-timezone America/Los_Angeles
timedatectl

cd src/tungstenfabric/tf-dev-env
if [[ -z "$@" && "\${ENVIRONMENT_OS,,}" == centos7 ]]; then
  local y=./config/etc/yum.repos.d
  mkdir -p \${y}
  cp ${WORKSPACE}/src/progmaticlab/tf-jenkins/jobs/common/pnexus.repo \${y}/
fi
./run.sh $@
EOF
return $res
}

if ! run_over_ssh ; then
  echo "ERROR: UT failed"
  exit 1
fi
if ! run_over_ssh test $TARGET ; then
  echo "ERROR: UT failed"
  exit 1
fi

echo "INFO: UT finished successfully"
