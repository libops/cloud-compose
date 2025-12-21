#!/usr/bin/env bash

set -eou pipefail

pushd /home/cloud-compose

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

bash rotate-keys.sh \
    "internal-$GCP_INSTANCE_NAME@$GCP_PROJECT.iam.gserviceaccount.com" \
    "$GCP_PROJECT" \
    /mnt/disks/data/libops-internal/GOOGLE_APPLICATION_CREDENTIALS

popd
