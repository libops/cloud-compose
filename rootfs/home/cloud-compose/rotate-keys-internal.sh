#!/usr/bin/env bash

set -eou pipefail

pushd /home/cloud-compose

# shellcheck disable=SC1091
. ./env

bash rotate-keys.sh \
    "internal-services-$GCP_INSTANCE_NAME@$GCP_PROJECT.iam.gserviceaccount.com" \
    "$GCP_PROJECT" \
    /mnt/disks/data/libops/GOOGLE_APPLICATION_CREDENTIALS

popd
