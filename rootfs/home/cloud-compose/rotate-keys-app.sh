#!/usr/bin/env bash

set -eou pipefail

pushd /home/cloud-compose

# shellcheck disable=SC1091
. ./env

if [ -d /mnt/disks/data/compose/secrets ]; then
  exit 0
fi

bash rotate-keys.sh \
    "$GCP_INSTANCE_NAME@$GCP_PROJECT.iam.gserviceaccount.com" \
    "$GCP_PROJECT" \
    /mnt/disks/data/compose/secrets/GOOGLE_APPLICATION_CREDENTIALS

popd
