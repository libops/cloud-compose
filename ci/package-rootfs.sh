#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
output_dir="${1:-$repo_root/dist}"
asset_name="cloud-compose-rootfs.tar.gz"
contract_asset_name="cloud-compose-rootfs.contract.sha256"

if [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi
install -d -m 0755 -- "$output_dir"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-rootfs.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

cp -a -- "$repo_root/rootfs" "$tmp/rootfs"
find "$tmp/rootfs" -depth -type d -empty -delete
find "$tmp/rootfs" -type d -exec chmod 0755 -- {} +
find "$tmp/rootfs" -type f -exec chmod 0644 -- {} +
find "$tmp/rootfs" -type f -name '*.sh' -exec chmod 0755 -- {} +
bash "$repo_root/rootfs/etc/cloud-compose/libexec/rootfs-archive.sh" \
    contract "$tmp/rootfs" >"$tmp/$contract_asset_name"

LC_ALL=C tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$tmp" \
    -cf - rootfs | gzip -n -9 >"$tmp/$asset_name"

(
    cd "$tmp"
    sha256sum "$asset_name" >"${asset_name}.sha256"
)
install -m 0644 "$tmp/$asset_name" "$output_dir/$asset_name"
install -m 0644 "$tmp/${asset_name}.sha256" "$output_dir/${asset_name}.sha256"
install -m 0644 "$tmp/$contract_asset_name" "$output_dir/$contract_asset_name"
