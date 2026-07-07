#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="${CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE:-python:3.11-slim}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd docker
require_cmd tar

tar \
  --exclude="./.git" \
  --exclude="./.terraform" \
  --exclude="./docs/site" \
  -C "$repo_root" \
  -cf - . |
  docker run --rm -i \
    --tmpfs /run \
    --tmpfs /tmp \
    "$image" \
    bash -lc 'mkdir -p /work && tar -C /work -xf - && cd /work && bash ci/config-management-smoke-inner.sh'
