#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime="$repo_root/rootfs/home/cloud-compose/host-conf.sh"

grep -Fq 'host runtime install' \
  "$runtime" || {
  echo "managed package and artifact reconciliation does not delegate to sitectl" >&2
  exit 1
}

grep -Fq 'can(regex("^[0-9a-f]{64}$", artifact.sha256))' \
  "$repo_root/modules/gcp/variables.tf" || {
  echo "Terraform no longer validates managed artifact digests" >&2
  exit 1
}

echo "Managed artifact installation delegates to sitectl"
