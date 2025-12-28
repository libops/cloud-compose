#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
export HOME

git config --global --add safe.directory "$DOCKER_COMPOSE_DIR"

if [ ! -d "$DOCKER_COMPOSE_DIR" ]; then
  echo "Directory '$DOCKER_COMPOSE_DIR' not found. Cloning repository."
  mkdir -p "$DOCKER_COMPOSE_DIR"
  pushd "$DOCKER_COMPOSE_DIR"
  retry_until_success git clone -b "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" .
  chown -R cloud-compose:cloud-compose .
else
  pushd "$DOCKER_COMPOSE_DIR"
  retry_until_success git pull origin "$DOCKER_COMPOSE_BRANCH"
fi

# set COMPOSE_PROJECT_NAME from value set in cloud-compose
# sourced from /home/cloud-compose/profile.sh which loads /home/cloud-compose/.env
update_env COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT_NAME"
update_env SITE_NAME "$GCP_INSTANCE_NAME"
retry_until_success /mnt/disks/data/init
popd
