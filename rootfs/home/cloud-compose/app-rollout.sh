#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

pushd "$DOCKER_COMPOSE_DIR"

retry_until_success git pull origin "$DOCKER_COMPOSE_BRANCH"
retry_until_success docker info

# Pull all images and check if any were updated
shopt -s nullglob
RESTART=0
while read -r IMAGE; do
    # Skip empty lines and comments
    if [ -z "$IMAGE" ] || [[ "$IMAGE" =~ ^# ]]; then
      continue
    fi

    current_image_id=$(docker images --format "{{.ID}}" "$IMAGE" || echo "")
    retry_until_success docker pull "$IMAGE"
    new_image_id=$(docker images --format "{{.ID}}" "$IMAGE")

    if [ "$current_image_id" != "$new_image_id" ]; then
      RESTART=1
    fi
done < <(grep "image:" ./*.{yml,yaml} 2>/dev/null| awk -F': ' '{print $2}')
shopt -u nullglob

if [ "$RESTART" -eq 1 ]; then
  SERVICE=$(grep -sl "WorkingDirectory=$DIR" /etc/systemd/system/*.service | xargs basename)
  if [ -n "$SERVICE" ]; then
    echo "Restarting $SERVICE"
    systemctl restart "$SERVICE"
  fi
fi

popd
