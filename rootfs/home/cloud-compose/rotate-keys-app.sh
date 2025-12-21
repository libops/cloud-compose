#!/usr/bin/env bash

set -eou pipefail

pushd /home/cloud-compose

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

if [ ! -d "$DOCKER_COMPOSE_DIR/secrets" ]; then
  mkdir "$DOCKER_COMPOSE_DIR/secrets"
fi

bash rotate-keys.sh \
    "$GCP_INSTANCE_NAME@$GCP_PROJECT.iam.gserviceaccount.com" \
    "$GCP_PROJECT" \
    "$DOCKER_COMPOSE_DIR/secrets/GOOGLE_APPLICATION_CREDENTIALS"

popd
