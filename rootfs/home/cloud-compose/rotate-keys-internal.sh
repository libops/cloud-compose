#!/usr/bin/env bash

set -euo pipefail

_cc_rotate_keys_internal_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_rotate_keys_internal_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_rotate_keys_internal_source script_dir _cc_rotate_keys_internal_installed_home
if [[ -n "$_cc_rotate_keys_internal_installed_home" &&
  ( "$_cc_rotate_keys_internal_installed_home" == "/" ||
    "$_cc_rotate_keys_internal_source" == "${_cc_rotate_keys_internal_installed_home%/}/"* ) ]]; then
  _cc_rotate_keys_internal_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
  _cc_rotate_keys_internal_checked_programs="$script_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_rotate_keys_internal_checked_programs
# shellcheck disable=SC1090
source "$_cc_rotate_keys_internal_checked_programs"
cloud_compose_bind_source_program \
  "$_cc_rotate_keys_internal_source" CLOUD_COMPOSE_PROFILE_PATH \
  /home/cloud-compose/profile.sh "$script_dir/profile.sh"
cloud_compose_bind_source_program \
  "$_cc_rotate_keys_internal_source" CLOUD_COMPOSE_ROTATE_KEYS_PATH \
  /home/cloud-compose/rotate-keys.sh "$script_dir/rotate-keys.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
rotate_keys_script="$CLOUD_COMPOSE_ROTATE_KEYS_PATH"
readonly profile_path rotate_keys_script

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
CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER="${CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER:-/mnt/disks/data/.cloud-compose/fresh-filesystem}"
CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY="${CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY:-}"
rotation_reconcile_orphans=false
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
  ROTATION_RECONCILE_ORPHANS="$rotation_reconcile_orphans" \
  CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER="$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" \
  CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY="$CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY" \
  bash "$rotate_keys_script" "$1" \
    "$internal_service_account" \
    "$GCP_PROJECT" \
    "$INTERNAL_CREDENTIALS_FILE"
}

require_inactive_internal_service() {
  local load_state active_state

  load_state="$(systemctl show --property=LoadState --value -- cloud-compose-internal-services.service)" || {
    echo "Could not determine whether cloud-compose-internal-services.service is loaded" >&2
    return 1
  }
  active_state="$(systemctl show --property=ActiveState --value -- cloud-compose-internal-services.service)" || {
    echo "Could not determine whether cloud-compose-internal-services.service is inactive" >&2
    return 1
  }
  if [[ "$load_state" != "loaded" || "$active_state" != "inactive" ]]; then
    echo "Fresh-filesystem key reconciliation requires loaded, inactive cloud-compose-internal-services.service; observed ${load_state}/${active_state}" >&2
    return 1
  fi
}

if [[ ! -e "$INTERNAL_CREDENTIALS_FILE" && ! -L "$INTERNAL_CREDENTIALS_FILE" &&
  ( -e "$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" || -L "$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" ) ]]; then
  require_inactive_internal_service
  rotation_reconcile_orphans=true
fi

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
