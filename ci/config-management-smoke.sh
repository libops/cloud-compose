#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# renovate: datasource=docker depName=python packageName=python versioning=docker
CONFIG_MANAGEMENT_IMAGE_DEFAULT="python:3.11-slim@sha256:e031123e3d85762b141ad1cbc56452ba69c6e722ebf2f042cc0dc86c47c0d8b3"
image="${CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE:-$CONFIG_MANAGEMENT_IMAGE_DEFAULT}"
container_entrypoint="$repo_root/ci/config-management-smoke-container.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd tar
[[ -f "$container_entrypoint" && ! -L "$container_entrypoint" ]] || {
  echo "Config-management smoke container entrypoint is missing or unsafe" >&2
  exit 1
}

tar \
  --exclude="./.git" \
  --exclude="./.terraform" \
  --exclude="./docs/site" \
  -C "$repo_root" \
  -cf - . |
  docker run --rm -i \
    --mount "type=bind,src=${container_entrypoint},dst=/usr/local/libexec/cloud-compose-config-management-smoke,readonly" \
    --tmpfs /run \
    --tmpfs /tmp \
    "$image" \
    /usr/local/libexec/cloud-compose-config-management-smoke
