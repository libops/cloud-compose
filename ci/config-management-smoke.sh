#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# renovate: datasource=docker depName=python packageName=python versioning=docker
CONFIG_MANAGEMENT_IMAGE_DEFAULT="python:3.11-slim@sha256:e031123e3d85762b141ad1cbc56452ba69c6e722ebf2f042cc0dc86c47c0d8b3"
image="${CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE:-$CONFIG_MANAGEMENT_IMAGE_DEFAULT}"

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
