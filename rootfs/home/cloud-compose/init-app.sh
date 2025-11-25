#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
. /home/cloud-compose/env

export DIR=${DIR:-/mnt/disks/data/compose}

if [ ! -d "$DIR" ]; then
  git clone -b "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$DIR"
fi

pushd "$DIR"
git pull origin "$DOCKER_COMPOSE_BRANCH" || echo "Unable to git pull"

/usr/bin/docker-credential-gcr configure-docker --registries us-docker.pkg.dev

# run the docker compose init command if it exists
/mnt/disks/data/init

bash /home/cloud-compose/rollout.sh

chgrp developers /mnt/disks/data/compose
chmod g+s /mnt/disks/data/compose

popd
