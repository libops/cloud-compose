#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
rotate_keys_script="${CLOUD_COMPOSE_ROTATE_KEYS_PATH:-$script_dir/rotate-keys.sh}"
compose_apps_path="${CLOUD_COMPOSE_COMPOSE_APPS_PATH:-/home/cloud-compose/compose-apps.sh}"

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

# shellcheck disable=SC1090
source "$compose_apps_path"

APP_CREDENTIALS_FILE="${APP_CREDENTIALS_FILE:-/mnt/disks/data/cloud-compose/app/GOOGLE_APPLICATION_CREDENTIALS}"
ROTATION_APP_CREDENTIAL_OWNER="${ROTATION_CREDENTIAL_OWNER-100}"
ROTATION_CENTRAL_CREDENTIAL_OWNER="${ROTATION_CENTRAL_CREDENTIAL_OWNER-root}"
ROTATION_CREDENTIAL_GROUP="${ROTATION_CREDENTIAL_GROUP-cloud-compose}"
CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER="${CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER:-/mnt/disks/data/.cloud-compose/fresh-filesystem}"
CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY="${CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY:-}"
rotation_reconcile_orphans=false
rotation_action="${1:-rotate}"

if [[ -n "$ROTATION_CREDENTIAL_GROUP" &&
  ! "$ROTATION_CREDENTIAL_GROUP" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]]; then
  echo "ROTATION_CREDENTIAL_GROUP must be empty or a safe local group name" >&2
  exit 2
fi
if [[ ! "$ROTATION_CENTRAL_CREDENTIAL_OWNER" =~ ^([0-9]+|[a-z_][a-z0-9_-]{0,31}\$?)$ ]]; then
  echo "ROTATION_CENTRAL_CREDENTIAL_OWNER must be a numeric UID or safe local account name" >&2
  exit 2
fi

case "$rotation_action" in
  rotate | rollback | retire) ;;
  *)
    echo "Usage: $0 [rotate|rollback|retire]" >&2
    exit 2
    ;;
esac

case "${GCP_APP_CREDENTIALS_ENABLED:-false}" in
  true) app_credentials_enabled=true ;;
  false) app_credentials_enabled=false ;;
  *)
    echo "GCP_APP_CREDENTIALS_ENABLED must be true or false" >&2
    exit 2
    ;;
esac

case "${GCP_APP_SERVICE_ACCOUNT_MANAGED:-false}" in
  true) app_service_account_managed=true ;;
  false) app_service_account_managed=false ;;
  *)
    echo "GCP_APP_SERVICE_ACCOUNT_MANAGED must be true or false" >&2
    exit 2
    ;;
esac

rotate_keys() {
  ROTATION_CREDENTIAL_OWNER="$ROTATION_CENTRAL_CREDENTIAL_OWNER" \
  ROTATION_RECONCILE_ORPHANS="$rotation_reconcile_orphans" \
  CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER="$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" \
  CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY="$CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY" \
  bash "$rotate_keys_script" "$1" \
    "$GCP_APP_SERVICE_ACCOUNT_EMAIL" \
    "$GCP_PROJECT" \
    "$APP_CREDENTIALS_FILE"
}

require_inactive_app_service() {
  local load_state active_state

  load_state="$(systemctl show --property=LoadState --value -- cloud-compose.service)" || {
    echo "Could not determine whether cloud-compose.service is loaded" >&2
    return 1
  }
  active_state="$(systemctl show --property=ActiveState --value -- cloud-compose.service)" || {
    echo "Could not determine whether cloud-compose.service is inactive" >&2
    return 1
  }
  if [[ "$load_state" != "loaded" || "$active_state" != "inactive" ]]; then
    echo "Fresh-filesystem key reconciliation requires loaded, inactive cloud-compose.service; observed ${load_state}/${active_state}" >&2
    return 1
  fi
}

app_credential_key_id() {
  local file="$1" key_id

  key_id="$(jq -jr '
    (.private_key_id |
      select(type == "string" and length > 0 and (explode | index(0) == null))),
    "\u001f"
  ' "$file")" || return 1
  key_id="${key_id%$'\x1f'}"
  [[ "$key_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf '%s\n' "$key_id"
}

validate_app_credentials() {
  local file="$1" key_id

  [[ ! -L "$file" && -f "$file" ]] || return 1
  key_id="$(app_credential_key_id "$file")" || return 1
  jq -e \
    --arg key_id "$key_id" \
    --arg service_account "$GCP_APP_SERVICE_ACCOUNT_EMAIL" \
    --arg project_id "$GCP_PROJECT" '
      .type == "service_account" and
      .private_key_id == $key_id and
      .client_email == $service_account and
      .project_id == $project_id and
      .token_uri == "https://oauth2.googleapis.com/token" and
      (.private_key | type == "string" and
        startswith("-----BEGIN PRIVATE KEY-----") and
        contains("-----END PRIVATE KEY-----"))
    ' "$file" >/dev/null
}

restore_central_app_credentials() {
  local source="$1" target_dir target_tmp

  target_dir="$(dirname -- "$APP_CREDENTIALS_FILE")"
  if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
    echo "Application credential directory is unsafe: $target_dir" >&2
    return 1
  fi
  install -d -m 0750 -- "$target_dir"
  if [[ -L "$target_dir" || ! -d "$target_dir" ]]; then
    echo "Application credential directory changed during recovery: $target_dir" >&2
    return 1
  fi

  target_tmp="$(mktemp "${APP_CREDENTIALS_FILE}.tmp.XXXXXX")" || return 1
  if ! install -m 0440 "$source" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 1
  fi
  if ! touch -r "$source" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 1
  fi
  if ! chown -- "$ROTATION_CENTRAL_CREDENTIAL_OWNER" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 1
  fi
  if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]] &&
    ! chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 1
  fi
  if ! mv -f -- "$target_tmp" "$APP_CREDENTIALS_FILE"; then
    rm -f -- "$target_tmp"
    return 1
  fi
  validate_app_credentials "$APP_CREDENTIALS_FILE" || {
    echo "Recovered central application credentials failed validation" >&2
    return 1
  }
  echo "Recovered central application credentials from unanimous distributed copies"
}

recover_distributed_app_credentials() {
  local first_target="" target
  local -a pending_artifacts=(
    "${APP_CREDENTIALS_FILE}.rotation-pending.json"
    "${APP_CREDENTIALS_FILE}.rotation-staged.json"
    "${APP_CREDENTIALS_FILE}.rotation-previous.json"
    "${APP_CREDENTIALS_FILE}.rotation-replacement.json"
  )

  if [[ -f "$APP_CREDENTIALS_FILE" ]]; then
    return 0
  fi
  for target in "${pending_artifacts[@]}"; do
    if [[ -e "$target" || -L "$target" ]]; then
      if [[ "$target" == "${APP_CREDENTIALS_FILE}.rotation-pending.json" ]]; then
        return 0
      fi
      echo "Cannot recover central credentials while an orphaned rotation artifact remains: $target" >&2
      return 1
    fi
  done

  for target in "${app_credential_targets[@]}"; do
    if [[ ! -e "$target" && ! -L "$target" ]]; then
      continue
    fi
    if ! validate_app_credentials "$target"; then
      echo "Distributed application credentials are invalid: $target" >&2
      return 1
    fi
    if [[ -z "$first_target" ]]; then
      first_target="$target"
    elif ! cmp -s -- "$first_target" "$target"; then
      echo "Distributed application credentials disagree; refusing remote key reconciliation" >&2
      return 1
    fi
  done
  if [[ -n "$first_target" ]]; then
    if [[ "$app_service_account_managed" != "true" ]]; then
      echo "Caller-supplied app identities require operator-reviewed central credential recovery" >&2
      return 1
    fi
    restore_central_app_credentials "$first_target"
  fi
}

install_app_credentials() {
  local target="$1"
  local target_dir target_tmp

  target_dir="$(dirname -- "$target")"
  if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
    echo "Application credential directory is unsafe: $target_dir" >&2
    return 2
  fi
  install -d -m 0750 "$target_dir" || return 2
  if [[ -L "$target_dir" || ! -d "$target_dir" ]]; then
    echo "Application credential directory changed during preparation: $target_dir" >&2
    return 2
  fi
  if ! chown -- cloud-compose "$target_dir" || ! chmod 0750 "$target_dir"; then
    return 2
  fi
  if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]] && ! chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$target_dir"; then
    return 2
  fi

  if [[ -f "$target" && ! -L "$target" ]] && cmp -s -- "$APP_CREDENTIALS_FILE" "$target"; then
    if [[ -n "$ROTATION_APP_CREDENTIAL_OWNER" ]] && ! chown -- "$ROTATION_APP_CREDENTIAL_OWNER" "$target"; then
      return 2
    fi
    if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]] && ! chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$target"; then
      return 2
    fi
    if ! chmod 0440 "$target"; then
      return 2
    fi
    return 1
  fi

  target_tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 2
  if ! install -m 0440 "$APP_CREDENTIALS_FILE" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 2
  fi
  if [[ -n "$ROTATION_APP_CREDENTIAL_OWNER" ]] && ! chown -- "$ROTATION_APP_CREDENTIAL_OWNER" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 2
  fi
  if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]] && ! chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$target_tmp"; then
    rm -f -- "$target_tmp"
    return 2
  fi
  if ! mv -f -- "$target_tmp" "$target"; then
    rm -f -- "$target_tmp"
    return 2
  fi
  return 0
}

apps=()
app_credential_targets=()
compose_app_names_array apps

# Resolve every target before creating a cloud key. A malformed manifest or an
# invalid app path must fail without changing IAM state.
for app in "${apps[@]}"; do
  source_compose_app_env "$app"
  validate_compose_git_source
  app_credential_targets+=("$DOCKER_COMPOSE_DIR/secrets/GOOGLE_APPLICATION_CREDENTIALS")
done

credential_artifacts=(
  "$APP_CREDENTIALS_FILE"
  "${APP_CREDENTIALS_FILE}.rotation-pending.json"
  "${APP_CREDENTIALS_FILE}.rotation-staged.json"
  "${APP_CREDENTIALS_FILE}.rotation-previous.json"
  "${APP_CREDENTIALS_FILE}.rotation-replacement.json"
  "${APP_CREDENTIALS_FILE}.rotation.lock"
  "${app_credential_targets[@]}"
)
for target in "${credential_artifacts[@]}"; do
  if [[ -L "$target" || ( -e "$target" && ! -f "$target" ) ]]; then
    echo "Application credential artifact is unsafe: $target" >&2
    exit 2
  fi
done
for target in "${app_credential_targets[@]}"; do
  target_dir="$(dirname -- "$target")"
  if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
    echo "Application credential directory is unsafe: $target_dir" >&2
    exit 2
  fi
done

if [[ "$rotation_action" == "retire" ]]; then
  rotate_keys retire
  rm -f -- "${credential_artifacts[@]}"
  echo "Application file credentials retired"
  exit 0
fi

if [[ "$app_credentials_enabled" != "true" ]]; then
  for target in "${credential_artifacts[@]}"; do
    if [[ -e "$target" ]]; then
      echo "Managed app credentials are disabled but $target remains; re-enable credentials, run '$0 retire', then disable them" >&2
      exit 1
    fi
  done
  echo "Application file credentials are disabled"
  exit 0
fi

recover_distributed_app_credentials
if [[ ! -e "$APP_CREDENTIALS_FILE" && ! -L "$APP_CREDENTIALS_FILE" &&
  "$app_service_account_managed" == "true" &&
  ( -e "$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" || -L "$CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER" ) ]]; then
  require_inactive_app_service
  rotation_reconcile_orphans=true
fi

install -d -m 0750 "$(dirname -- "$APP_CREDENTIALS_FILE")"
if [[ "$rotation_action" == "rollback" ]]; then
  rotate_keys rollback
else
  rotate_keys prepare
fi
phase="$(rotate_keys status)"

if [[ "$phase" == "staged" ]]; then
  # Prove that IAM accepts the new private key before any running consumer is
  # switched to its credential inode. Propagation lag is handled with backoff.
  rotate_keys authenticate
  phase=authenticated
fi

if [[ -n "$ROTATION_CREDENTIAL_GROUP" ]]; then
  chgrp -- "$ROTATION_CREDENTIAL_GROUP" "$APP_CREDENTIALS_FILE"
fi

credentials_changed=false
for target in "${app_credential_targets[@]}"; do
  if install_app_credentials "$target"; then
    credentials_changed=true
  else
    install_status=$?
    if [[ "$install_status" -ne 1 ]]; then
      echo "Failed to install application credentials at $target" >&2
      exit "$install_status"
    fi
  fi
done

if [[ "$phase" == "authenticated" || "$phase" == "rollback" || "$credentials_changed" == "true" ]]; then
  # A file bind mount keeps its original inode. Reload only a service that was
  # already active; rotation must never turn an intentionally stopped app on.
  if systemctl is-active --quiet cloud-compose.service; then
    systemctl restart cloud-compose.service
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
