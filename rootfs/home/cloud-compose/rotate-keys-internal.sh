#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
rotate_keys_script="${CLOUD_COMPOSE_ROTATE_KEYS_PATH:-$script_dir/rotate-keys.sh}"

# shellcheck disable=SC1090
source "$profile_path"

case "${CLOUD_COMPOSE_PROVIDER:-}" in
  gcp) ;;
  "")
    echo "CLOUD_COMPOSE_PROVIDER is required for service-account key rotation" >&2
    exit 1
    ;;
  *) exit 0 ;;
esac

INTERNAL_CREDENTIALS_FILE="${INTERNAL_CREDENTIALS_FILE:-/mnt/disks/data/libops-internal/GOOGLE_APPLICATION_CREDENTIALS}"
ROTATION_CREDENTIAL_GROUP="${ROTATION_CREDENTIAL_GROUP-cloud-compose}"
internal_service_account="internal-$GCP_INSTANCE_NAME@$GCP_PROJECT.iam.gserviceaccount.com"
rotation_action="${1:-rotate}"

if [[ -n "$ROTATION_CREDENTIAL_GROUP" &&
  ! "$ROTATION_CREDENTIAL_GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]]; then
  echo "ROTATION_CREDENTIAL_GROUP must be empty or a safe local group name" >&2
  exit 2
fi

case "$rotation_action" in
  rotate | rollback) ;;
  *)
    echo "Usage: $0 [rotate|rollback]" >&2
    exit 2
    ;;
esac

rotate_keys() {
  bash "$rotate_keys_script" "$1" \
    "$internal_service_account" \
    "$GCP_PROJECT" \
    "$INTERNAL_CREDENTIALS_FILE"
}

if [[ "$rotation_action" == "rollback" ]]; then
  rotate_keys rollback
else
  rotate_keys prepare
fi
phase="$(rotate_keys status)"

if [[ "$phase" == "staged" ]]; then
  rotate_keys authenticate
  phase=authenticated
fi

if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]]; then
  chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$INTERNAL_CREDENTIALS_FILE"
fi

if [[ "$phase" == "authenticated" || "$phase" == "rollback" ]]; then
  # Recreate containers so their credential bind mounts reference the newly
  # installed inode, but do not start an intentionally inactive service.
  if systemctl is-active --quiet cloud-compose-internal-services.service; then
    systemctl restart cloud-compose-internal-services.service
  fi
fi

if [[ "$phase" == "authenticated" ]]; then
  rotate_keys ready
  phase=ready
fi
if [[ "$phase" == "rollback" ]]; then
  rotate_keys rollback-ready
  phase=idle
fi
if [[ "$phase" == "ready" || "$phase" == "grace" ]]; then
  rotate_keys commit
fi
