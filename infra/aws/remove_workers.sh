#!/bin/bash -eE
set -o pipefail

# to remove just job's workers

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/definitions"
source "$my_dir/functions.sh"

if [[ -n $INSTANCE_IDS ]] ; then
    instance_ids=$(echo "$INSTANCE_IDS" | sed 's/,/ /g')
else
    instance_ids=$instance_id
fi

terminate_instances $instance_ids
