#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
export HOME
cd /home/cloud-compose

# shellcheck disable=SC1091
source /home/cloud-compose/compose-apps.sh

apps=()
compose_app_names_array apps
for app in "${apps[@]}"; do
  source_compose_app_env "$app"

  if [[ ! -d "$DOCKER_COMPOSE_DIR/.git" ]]; then
    echo "Compose source was not prepared before application initialization: $DOCKER_COMPOSE_DIR" >&2
    exit 1
  fi

  pushd "$DOCKER_COMPOSE_DIR" >/dev/null
  scaffold_compose_app_defaults "$app"
  sync_compose_application_env
  update_compose_env COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"
  update_compose_env SITE_NAME "${CLOUD_COMPOSE_INSTANCE_NAME:-${GCP_INSTANCE_NAME:-$app}}"
  update_compose_env COMPOSE_BIND_PORT "$COMPOSE_BIND_PORT"
  run_compose_app_lifecycle "$app" init
  configure_sitectl_app_features "$app"
  popd >/dev/null
done
