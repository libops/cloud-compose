#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
export HOME

if [ ! -d "$DOCKER_COMPOSE_DIR" ]; then
  mkdir -p "$DOCKER_COMPOSE_DIR"
  echo "Directory '$DOCKER_COMPOSE_DIR' not found. Cloning repository."
  retry_until_success git clone -b "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$DOCKER_COMPOSE_DIR"
fi

pushd "$DOCKER_COMPOSE_DIR"
retry_until_success git pull origin "$DOCKER_COMPOSE_BRANCH"
# set COMPOSE_PROJECT_NAME from value set in cloud-compose
# sourced from /home/cloud-compose/profile.sh which loads /home/cloud-compose/.env
update_env COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"
update_env SITE_NAME "$GCP_INSTANCE_NAME"
retry_until_success /mnt/disks/data/init
popd
