#!/usr/bin/env bash

set -euo pipefail

_cc_docker_prune_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_docker_prune_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_docker_prune_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_docker_prune_source _cc_docker_prune_dir _cc_docker_prune_installed_home
if [[ -n "$_cc_docker_prune_installed_home" &&
  ( "$_cc_docker_prune_installed_home" == "/" ||
    "$_cc_docker_prune_source" == "${_cc_docker_prune_installed_home%/}/"* ) ]]; then
  _cc_docker_prune_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
  _cc_docker_prune_checked_programs="$_cc_docker_prune_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_docker_prune_checked_programs
# shellcheck disable=SC1090
source "$_cc_docker_prune_checked_programs"
cloud_compose_bind_source_program \
  "$_cc_docker_prune_source" \
  CLOUD_COMPOSE_PROFILE_PATH \
  /home/cloud-compose/profile.sh \
  "$_cc_docker_prune_dir/profile.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
readonly profile_path

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
