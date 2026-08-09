#!/usr/bin/env bash

set -euo pipefail

_cc_mount_overlays_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_mount_overlays_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_mount_overlays_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_mount_overlays_source _cc_mount_overlays_dir _cc_mount_overlays_installed_home
if [[ -n "$_cc_mount_overlays_installed_home" &&
    ( "$_cc_mount_overlays_installed_home" == "/" ||
        "$_cc_mount_overlays_source" == "${_cc_mount_overlays_installed_home%/}/"* ) ]]; then
    _cc_mount_overlays_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_mount_overlays_checked_programs="$_cc_mount_overlays_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_mount_overlays_checked_programs
# shellcheck disable=SC1090
source "$_cc_mount_overlays_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_mount_overlays_source" \
    CLOUD_COMPOSE_PROFILE_PATH \
    /home/cloud-compose/profile.sh \
    "$_cc_mount_overlays_dir/profile.sh"
cloud_compose_bind_source_program \
    "$_cc_mount_overlays_source" \
    CLOUD_COMPOSE_OVERLAY_INIT_PATH \
    /home/cloud-compose/overlay-init.sh \
    "$_cc_mount_overlays_dir/overlay-init.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
overlay_script="$CLOUD_COMPOSE_OVERLAY_INIT_PATH"
readonly profile_path overlay_script

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
