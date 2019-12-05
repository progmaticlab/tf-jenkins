#!/bin/bash -eE
set -o pipefail

[ "${DEBUG,,}" == "true" ] && set -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# setup env
source "$my_dir/definitions"

"$my_dir/../../infra/${SLAVE}/create_workers.sh"
