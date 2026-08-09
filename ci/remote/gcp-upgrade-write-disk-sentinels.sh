#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 || ! "$1" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]; then
    echo "usage: gcp-upgrade-write-disk-sentinels.sh SAFE_NONCE" >&2
    exit 2
fi

findmnt -n /mnt/disks/data >/dev/null
findmnt -n /mnt/disks/volumes >/dev/null
printf '%s' "$1" >/mnt/disks/data/.cloud-compose-upgrade-sentinel
printf '%s' "$1" >/mnt/disks/volumes/.cloud-compose-upgrade-sentinel
sync
