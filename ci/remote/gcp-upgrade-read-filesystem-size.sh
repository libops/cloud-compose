#!/usr/bin/env bash

set -euo pipefail

filesystem="$(findmnt -n -o FSTYPE --target /mnt/disks/data)"
if [[ "$filesystem" != "ext4" ]]; then
    echo "Application-data mount uses ${filesystem:-an unknown filesystem}, expected ext4" >&2
    exit 1
fi
{
    read -r _header
    read -r size_bytes
    [[ "$size_bytes" =~ ^[1-9][0-9]*$ ]]
    printf '%s\n' "$size_bytes"
} < <(df --block-size=1 --output=size -- /mnt/disks/data)
