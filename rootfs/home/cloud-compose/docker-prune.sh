#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"

# shellcheck disable=SC1090
source "$profile_path"

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

lock_path="${CLOUD_COMPOSE_DOCKER_PRUNE_LOCK_PATH:-/run/cloud-compose-docker-prune.lock}"
exec 9>"$lock_path"
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "A Cloud Compose Docker prune is already running"
  exit 0
fi

echo "Pruning stopped containers, unused networks, dangling images, and build cache older than $prune_until"
docker container prune --force --filter "until=$prune_until"
docker network prune --force --filter "until=$prune_until"
docker image prune --force --filter "until=$prune_until"
docker builder prune --force --filter "until=$prune_until"
