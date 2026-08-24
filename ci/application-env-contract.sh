#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
profile="$repo_root/rootfs/home/cloud-compose/profile.sh"

if grep -Eq '^(update_runtime_env|update_compose_env|sync_compose_application_env)\(' "$profile"; then
  echo "profile still implements environment reconciliation" >&2
  exit 1
fi
grep -Fq 'run_as_cloud_compose "$managed_sitectl" host apps lifecycle init' \
  "$repo_root/rootfs/home/cloud-compose/run.sh" || {
  echo "application initialization does not delegate environment reconciliation to sitectl" >&2
  exit 1
}

if grep -Eq '(^|[,[:space:]])var\.extra_env\)?$' \
  "$repo_root/modules/gcp/main.tf" "$repo_root/modules/linux-vm-runtime/main.tf"; then
  echo "Application extra_env is still merged into a host environment map" >&2
  exit 1
fi

echo "Application environment boundary delegates to sitectl"
