#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime="$repo_root/rootfs/home/cloud-compose/host-conf.sh"

grep -Fq 'host runtime install' "$runtime"
grep -Fq 'sitectl=/etc/cloud-compose/bin/bootstrap-sitectl' "$runtime"
grep -Fq 'sha256sum -c -' \
  "$repo_root/rootfs/etc/cloud-compose/libexec/bootstrap-sitectl.sh"

if grep -Eq 'install_packages\(|host artifacts install' "$runtime"; then
  echo "managed package reconciliation must remain in sitectl" >&2
  exit 1
fi

echo "Managed runtime uses the verified early-boot sitectl"
