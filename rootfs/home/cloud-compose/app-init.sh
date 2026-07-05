#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
export HOME

# shellcheck disable=SC1091
source /home/cloud-compose/compose-apps.sh

while read -r app; do
  if [ -z "$app" ]; then
    continue
  fi

  clone_or_update_compose_app "$app"
  source_compose_app_env "$app"

  pushd "$DOCKER_COMPOSE_DIR" >/dev/null
  update_env COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"
  update_env SITE_NAME "${CLOUD_COMPOSE_INSTANCE_NAME:-${GCP_INSTANCE_NAME:-$app}}"
  update_env COMPOSE_BIND_PORT "$COMPOSE_BIND_PORT"
  run_compose_app_lifecycle "$app" init
  configure_sitectl_app_features "$app"
  popd >/dev/null
done < <(compose_app_names)
