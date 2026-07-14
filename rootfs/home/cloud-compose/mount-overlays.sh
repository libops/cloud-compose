#!/usr/bin/env bash

set -euo pipefail

profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-/home/cloud-compose/profile.sh}"
overlay_script="${CLOUD_COMPOSE_OVERLAY_INIT_PATH:-/home/cloud-compose/overlay-init.sh}"

# shellcheck disable=SC1090
source "$profile_path"

if [[ -z "${DOCKER_VOLUME_OVERLAYS:-}" ]]; then
    exit 0
fi
if [[ "${CLOUD_COMPOSE_PROVIDER:-}" != "gcp" ]]; then
    echo "Docker volume overlays are supported only on GCP" >&2
    exit 1
fi
if ! mountpoint -q /mnt/disks/prod-readonly; then
    echo "The production overlay source is not mounted read-only" >&2
    exit 1
fi

read -r -a volumes <<<"$DOCKER_VOLUME_OVERLAYS"
if [[ "${#volumes[@]}" -eq 0 ]]; then
    echo "DOCKER_VOLUME_OVERLAYS did not contain a volume name" >&2
    exit 1
fi
for volume in "${volumes[@]}"; do
    bash "$overlay_script" "$volume"
done
