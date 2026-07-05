#!/usr/bin/env bash

set -eou pipefail

pushd /home/cloud-compose

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

# shellcheck disable=SC1091
source /home/cloud-compose/compose-apps.sh

APP_CREDENTIALS_FILE="/mnt/disks/data/cloud-compose/app/GOOGLE_APPLICATION_CREDENTIALS"
mkdir -p "$(dirname "$APP_CREDENTIALS_FILE")"
bash rotate-keys.sh \
    "$GCP_APP_SERVICE_ACCOUNT_EMAIL" \
    "$GCP_PROJECT" \
    "$APP_CREDENTIALS_FILE"

chgrp cloud-compose "$APP_CREDENTIALS_FILE"

while read -r app; do
  if [ -z "$app" ]; then
    continue
  fi

  source_compose_app_env "$app"
  mkdir -p "$DOCKER_COMPOSE_DIR/secrets"
  install -o 100 -g cloud-compose -m 0440 \
    "$APP_CREDENTIALS_FILE" \
    "$DOCKER_COMPOSE_DIR/secrets/GOOGLE_APPLICATION_CREDENTIALS"
done < <(compose_app_names)

popd
