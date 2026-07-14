#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

case "${CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED:-false}" in
  true | TRUE | 1 | yes | YES) ;;
  *)
    echo "Cloud Compose Docker pruning is disabled"
    exit 0
    ;;
esac

prune_until="${CLOUD_COMPOSE_DOCKER_PRUNE_UNTIL:-168h}"
if [[ ! "$prune_until" =~ ^[0-9]+(s|m|h)$ ]]; then
  echo "CLOUD_COMPOSE_DOCKER_PRUNE_UNTIL must be a Docker duration such as 168h" >&2
  exit 2
fi

exec 9>/run/cloud-compose-docker-prune.lock
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "A Cloud Compose Docker prune is already running"
  exit 0
fi

echo "Pruning unused Docker data older than $prune_until"
docker system prune --all --force --filter "until=$prune_until"
