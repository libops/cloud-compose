#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
output_dir="${1:-$repo_root/dist}"
asset_name="cloud-compose-rootfs.tar.gz"

if [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi
install -d -m 0755 -- "$output_dir"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-rootfs.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

LC_ALL=C tar \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    -C "$repo_root" \
    -cf - rootfs | gzip -n -9 >"$tmp/$asset_name"

(
    cd "$tmp"
    sha256sum "$asset_name" >"${asset_name}.sha256"
)
install -m 0644 "$tmp/$asset_name" "$output_dir/$asset_name"
install -m 0644 "$tmp/${asset_name}.sha256" "$output_dir/${asset_name}.sha256"
