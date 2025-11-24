#!/usr/bin/env bash

set -eou pipefail


# shellcheck disable=SC1091
source /home/cloud-compose/env
export HOME

DIR=${DIR:-/mnt/disks/data/compose}

if [ ! -d "$DIR" ]; then
  git clone -b "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" "$DIR"
fi

pushd "$DIR"
git pull origin "$DOCKER_COMPOSE_BRANCH"
/usr/bin/docker-credential-gcr configure-docker --registries us-docker.pkg.dev

# run the docker compose init command if it exists
/mnt/disks/data/init

# Pull all images and check if any were updated
shopt -s nullglob
RESTART=0
grep "image:" ./*.{yml,yaml} | awk -F': ' '{print $2}' | while read -r IMAGE; do
    # Skip empty lines and comments
    if [ -z "$IMAGE" ] || [[ "$IMAGE" =~ ^# ]]; then
      continue
    fi

    current_image_id=$(docker images --format "{{.ID}}" "$IMAGE" || echo "")
    docker pull "$IMAGE"
    new_image_id=$(docker images --format "{{.ID}}" "$IMAGE")

    if [ "$current_image_id" != "$new_image_id" ]; then
      RESTART=1
    fi
done
shopt -u nullglob

if [ "$RESTART" -eq 1 ]; then
  SERVICE=$(grep -sl "WorkingDirectory=$DIR" /etc/systemd/system/*.service | xargs basename)
  if [ -n "$SERVICE" ]; then
    systemctl restart "$SERVICE"
  fi
fi

popd
