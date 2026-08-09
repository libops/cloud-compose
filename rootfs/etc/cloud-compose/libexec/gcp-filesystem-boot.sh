#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: gcp-filesystem-boot.sh FRESH_FILESYSTEM_IDENTITY USE_OVERLAY PREP_PROGRAM PERSIST_PROGRAM FSTAB_RECONCILE_PROGRAM" >&2
    exit 2
fi

fresh_filesystem_identity="$1"
use_overlay="$2"
filesystem_prep="$3"
filesystem_persist="$4"
filesystem_reconcile="$5"

require_root_owned_data_program() {
    local path="$1" metadata

    if [[ -L "$path" || ! -f "$path" ]]; then
        echo "Checked filesystem data program is missing or unsafe: $path" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$path")" || return 1
    if [[ "$metadata" != "0:0:600:1:regular file" ]]; then
        echo "Checked filesystem data program is not an unlinked root-owned mode-0600 file: $path" >&2
        return 1
    fi
}

case "$use_overlay" in
    true | false) ;;
    *)
        echo "USE_OVERLAY must be true or false" >&2
        exit 2
        ;;
esac

require_root_owned_data_program "$filesystem_reconcile"

rm -f /run/cloud-compose-filesystems-ready
bash "$filesystem_prep" /dev/disk/by-id/google-data /mnt/disks/data \
    --publish-fresh-marker "$fresh_filesystem_identity"
bash "$filesystem_prep" /dev/disk/by-id/google-docker-volumes /mnt/disks/volumes
mkdir -p /mnt/disks/data/docker/volumes
if ! mountpoint -q /mnt/disks/data/docker/volumes; then
    mount --bind /mnt/disks/volumes /mnt/disks/data/docker/volumes
fi
for required_mount in /mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes; do
    if ! mountpoint -q -- "$required_mount"; then
        echo "Required cloud-compose mount is unavailable: $required_mount" >&2
        exit 1
    fi
done

if [[ "$use_overlay" == "true" ]]; then
    mkdir -p /mnt/disks/prod-readonly
    if ! mountpoint -q /mnt/disks/prod-readonly; then
        mount -o ro "$(readlink -f /dev/disk/by-id/google-prod-volumes)" \
            /mnt/disks/prod-readonly
    fi
    CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM="$filesystem_reconcile" bash "$filesystem_persist" \
        /dev/disk/by-id/google-data \
        /dev/disk/by-id/google-docker-volumes \
        /dev/disk/by-id/google-prod-volumes
else
    CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM="$filesystem_reconcile" bash "$filesystem_persist" \
        /dev/disk/by-id/google-data \
        /dev/disk/by-id/google-docker-volumes
fi
install -m 0600 /dev/null /run/cloud-compose-filesystems-ready
