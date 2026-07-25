#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "key rotation contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/apps/alpha" "$tmp/apps/beta"
order_log="$tmp/order.log"
post_count="$tmp/post-count"
auth_count="$tmp/auth-count"
list_count="$tmp/list-count"
sync_count="$tmp/sync-count"
key_state="$tmp/key-state.json"
: >"$order_log"
printf '0\n' >"$post_count"
printf '0\n' >"$auth_count"
printf '0\n' >"$list_count"
printf '0\n' >"$sync_count"

cat >"$tmp/profile.sh" <<'EOF'
#!/usr/bin/env bash
export CLOUD_COMPOSE_PROVIDER=gcp
export PATH="${TEST_BIN:?}:/usr/bin:/bin"
EOF

cat >"$tmp/compose-apps.sh" <<'EOF'
#!/usr/bin/env bash
compose_app_names_array() {
  local -n result="$1"
  result=(alpha beta)
}
source_compose_app_env() {
  case "$1" in
    alpha) DOCKER_COMPOSE_DIR="${TEST_ROOT:?}/apps/alpha" ;;
    beta) DOCKER_COMPOSE_DIR="${TEST_ROOT:?}/apps/beta" ;;
    *) return 1 ;;
  esac
}
validate_compose_git_source() {
  [[ "${FAKE_SOURCE_INVALID:-false}" != "true" ]]
}
EOF

cat >"$tmp/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'CHOWN %s\n' "$*" >>"${ORDER_LOG:?}"
exit 0
EOF
cat >"$tmp/bin/chgrp" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_CHGRP_FAIL_BETA:-false}" == "true" && "${!#}" == */apps/beta/secrets ]]; then
  exit 1
fi
printf 'CHGRP %s\n' "$*" >>"${ORDER_LOG:?}"
exit 0
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'SLEEP %s\n' "${1:-}" >>"${ORDER_LOG:?}"
EOF
cat >"$tmp/bin/sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count="$(<"${SYNC_COUNT:?}")"
count=$((count + 1))
printf '%s\n' "$count" >"$SYNC_COUNT"
printf 'SYNC %s\n' "$count" >>"${ORDER_LOG:?}"
if [[ -n "${FAKE_SYNC_FAIL_AT:-}" && "$count" == "$FAKE_SYNC_FAIL_AT" ]]; then
  exit 1
fi
EOF
cat >"$tmp/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "dgst" ]]; then
  cat >/dev/null
  printf 'test-signature'
  exit 0
fi
echo "unexpected openssl call: $*" >&2
exit 2
EOF

cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    property=""
    for argument in "$@"; do
      case "$argument" in
        --property=*) property="${argument#--property=}" ;;
      esac
    done
    unit="${!#}"
    if [[ "${FAKE_SYSTEMCTL_QUERY_FAIL:-false}" == "true" ]]; then
      exit 1
    fi
    case "$property" in
      LoadState) printf '%s\n' "${FAKE_SYSTEMCTL_LOAD_STATE:-loaded}" ;;
      ActiveState)
        case "$unit" in
          cloud-compose.service) printf '%s\n' "${FAKE_APP_STATE:-inactive}" ;;
          cloud-compose-internal-services.service) printf '%s\n' "${FAKE_INTERNAL_STATE:-inactive}" ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 2 ;;
    esac
    ;;
  is-active)
    unit="${!#}"
    case "$unit" in
      cloud-compose.service)
        if [[ -n "${FAKE_APP_ACTIVE+x}" ]]; then
          [[ "$FAKE_APP_ACTIVE" == "true" ]]
        else
          [[ "${FAKE_APP_STATE:-active}" == "active" ]]
        fi
        ;;
      cloud-compose-internal-services.service)
        if [[ -n "${FAKE_INTERNAL_ACTIVE+x}" ]]; then
          [[ "$FAKE_INTERNAL_ACTIVE" == "true" ]]
        else
          [[ "${FAKE_INTERNAL_STATE:-active}" == "active" ]]
        fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  restart)
    unit="${2:-}"
    expected="${EXPECTED_CONSUMER_KEY_ID:?}"
    if [[ "$unit" == "cloud-compose.service" ]]; then
      jq -e --arg id "$expected" '.private_key_id == $id' \
        "${TEST_ROOT:?}/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" >/dev/null
      jq -e --arg id "$expected" '.private_key_id == $id' \
        "$TEST_ROOT/apps/beta/secrets/GOOGLE_APPLICATION_CREDENTIALS" >/dev/null
    fi
    if [[ "${FAKE_RESTART_FAIL:-false}" == "true" ]]; then
      printf 'RESTART_FAILED %s %s\n' "$unit" "$expected" >>"${ORDER_LOG:?}"
      exit 1
    fi
    printf 'RESTART %s %s\n' "$unit" "$expected" >>"${ORDER_LOG:?}"
    ;;
  *)
    echo "unexpected systemctl call: $*" >&2
    exit 2
    ;;
esac
EOF

cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${!#}"
format=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-c" ]]; then
    format="$argument"
  fi
  previous="$argument"
done
if [[ -n "${FAKE_FRESH_MARKER:-}" ]]; then
  marker_dir="$(dirname -- "$FAKE_FRESH_MARKER")"
  marker_root="$(dirname -- "$marker_dir")"
  case "$target:$format" in
    "$marker_root:%u:%a") printf '0:1775\n'; exit 0 ;;
    "$marker_dir:%u:%g:%a") printf '0:0:700\n'; exit 0 ;;
    "$FAKE_FRESH_MARKER:%u:%g:%a:%h") printf '0:0:600:1\n'; exit 0 ;;
  esac
fi
exec /usr/bin/stat "$@"
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
url=""
output=""
write_format=""
previous=""
for argument in "$@"; do
  case "$previous" in
    -X) method="$argument" ;;
    -o) output="$argument" ;;
    -w) write_format="$argument" ;;
  esac
  if [[ "$argument" == http* ]]; then
    url="$argument"
  fi
  previous="$argument"
done

write_response() {
  local body="$1"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$body" >"$output"
  else
    printf '%s\n' "$body"
  fi
}

write_status() {
  local status="$1" body="${2-}"
  if [[ -z "$body" ]]; then
    body='{}'
  fi
  write_response "$body"
  if [[ -n "$write_format" ]]; then
    printf '%s' "$status"
  fi
}

if [[ "$url" == *169.254.169.254* ]]; then
  write_response '{"access_token":"metadata-token"}'
  exit 0
fi

if [[ "$url" == "https://oauth2.googleapis.com/token" ]]; then
  count="$(<"${AUTH_COUNT:?}")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$AUTH_COUNT"
  printf 'AUTH %s\n' "$count" >>"${ORDER_LOG:?}"
  if ((count <= ${FAKE_AUTH_FAIL_UNTIL:-0})); then
    exit 22
  fi
  write_response '{"access_token":"replacement-token","expires_in":3600,"token_type":"Bearer"}'
  exit 0
fi

if [[ "$method" == GET && "$url" == */keys ]]; then
  count="$(<"${LIST_COUNT:?}")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$LIST_COUNT"
  if [[ -n "${FAKE_INJECT_KEY_ON_LIST:-}" &&
    "$count" == "${FAKE_INJECT_KEY_ON_LIST_NUMBER:-2}" ]]; then
    service_account="${url#*serviceAccounts/}"
    service_account="${service_account%/keys}"
    injected_name="projects/test-project/serviceAccounts/${service_account}/keys/${FAKE_INJECT_KEY_ON_LIST}"
    jq --arg name "$injected_name" \
      '. + [{name: $name, disabled: false}] | unique_by(.name)' \
      "$KEY_STATE" >"$KEY_STATE.tmp"
    mv "$KEY_STATE.tmp" "$KEY_STATE"
  fi
  jq -c '{keys: [.[] | {
    keyType: (.keyType // "USER_MANAGED"),
    name: .name,
    disabled: .disabled
  }]}' "${KEY_STATE:?}"
  exit 0
fi

if [[ "$method" == POST && "$url" == */keys ]]; then
  count="$(<"${POST_COUNT:?}")"
  printf '%s\n' "$((count + 1))" >"$POST_COUNT"
  printf 'POST\n' >>"${ORDER_LOG:?}"
  service_account="${url#*serviceAccounts/}"
  service_account="${service_account%/keys}"
  key_name="projects/test-project/serviceAccounts/${service_account}/keys/${NEW_KEY_ID:?}"
  if [[ "${FAKE_POST_MODE:-success}" != "fail-no-create" &&
    "${FAKE_POST_MODE:-success}" != "rejected-400" ]]; then
    jq --arg name "$key_name" '. + [{name: $name, disabled: false}] | unique_by(.name)' \
      "$KEY_STATE" >"$KEY_STATE.tmp"
    mv "$KEY_STATE.tmp" "$KEY_STATE"
  fi
  case "${FAKE_POST_MODE:-success}" in
    fail-no-create | ambiguous-create) exit 22 ;;
    rejected-400)
      write_status 400 '{"error":{"code":400,"message":"quota"}}'
      exit 0
      ;;
    ambiguous-408)
      write_status 408 '{"error":{"code":408,"message":"timeout"}}'
      exit 0
      ;;
  esac
  key_data="$(jq -nc --arg id "$NEW_KEY_ID" --arg email "$service_account" '{
    type: "service_account",
    project_id: "test-project",
    private_key_id: $id,
    private_key: "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n",
    client_email: $email,
    token_uri: "https://oauth2.googleapis.com/token"
  }' | base64 | tr -d '\n')"
  body="$(printf '{"name":"%s","privateKeyData":"%s"}' "$key_name" "$key_data")"
  write_status 200 "$body"
  if [[ "${FAKE_POST_MODE:-success}" == "late-success" ]]; then
    exit 18
  fi
  exit 0
fi

if [[ "$method" == POST && "$url" == *:disable ]]; then
  key_name="${url#https://iam.googleapis.com/v1/}"
  key_name="${key_name%:disable}"
  if ! jq -e --arg name "$key_name" 'any(.[]; .name == $name)' "$KEY_STATE" >/dev/null; then
    write_status 404
    exit 0
  fi
  if [[ "${FAKE_DISABLE_FAIL:-false}" == "true" ]]; then
    write_status 500
    exit 0
  fi
  jq --arg name "$key_name" 'map(if .name == $name then .disabled = true else . end)' \
    "$KEY_STATE" >"$KEY_STATE.tmp"
  mv "$KEY_STATE.tmp" "$KEY_STATE"
  printf 'DISABLE %s\n' "$key_name" >>"${ORDER_LOG:?}"
  write_status 200
  exit 0
fi

if [[ "$method" == POST && "$url" == *:enable ]]; then
  key_name="${url#https://iam.googleapis.com/v1/}"
  key_name="${key_name%:enable}"
  if ! jq -e --arg name "$key_name" 'any(.[]; .name == $name)' "$KEY_STATE" >/dev/null; then
    write_status 404
    exit 0
  fi
  jq --arg name "$key_name" 'map(if .name == $name then .disabled = false else . end)' \
    "$KEY_STATE" >"$KEY_STATE.tmp"
  mv "$KEY_STATE.tmp" "$KEY_STATE"
  printf 'ENABLE %s\n' "$key_name" >>"${ORDER_LOG:?}"
  write_status 200
  exit 0
fi

if [[ "$method" == DELETE ]]; then
  key_name="${url#https://iam.googleapis.com/v1/}"
  if [[ "${FAKE_DELETE_FAIL:-false}" == "true" ]]; then
    write_status 500
    exit 0
  fi
  if ! jq -e --arg name "$key_name" 'any(.[]; .name == $name)' "$KEY_STATE" >/dev/null; then
    printf 'DELETE404 %s\n' "$key_name" >>"${ORDER_LOG:?}"
    write_status 404
    exit 0
  fi
  jq --arg name "$key_name" 'map(select(.name != $name))' "$KEY_STATE" >"$KEY_STATE.tmp"
  mv "$KEY_STATE.tmp" "$KEY_STATE"
  printf 'DELETE %s\n' "$key_name" >>"${ORDER_LOG:?}"
  if [[ -n "${FAKE_DELETE_FAIL_AFTER_MUTATION_ID:-}" &&
    "$key_name" == */keys/"$FAKE_DELETE_FAIL_AFTER_MUTATION_ID" ]]; then
    write_status 500
    exit 0
  fi
  write_status 200
  exit 0
fi

echo "unexpected curl call: $method $url" >&2
exit 22
EOF

chmod +x "$tmp/bin/"*

export TEST_ROOT="$tmp"
export TEST_BIN="$tmp/bin"
export ORDER_LOG="$order_log"
export POST_COUNT="$post_count"
export AUTH_COUNT="$auth_count"
export LIST_COUNT="$list_count"
export SYNC_COUNT="$sync_count"
export KEY_STATE="$key_state"
export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
export CLOUD_COMPOSE_COMPOSE_APPS_PATH="$tmp/compose-apps.sh"
export CLOUD_COMPOSE_ROTATE_KEYS_PATH="$repo_root/rootfs/home/cloud-compose/rotate-keys.sh"
export APP_CREDENTIALS_FILE="$tmp/central/GOOGLE_APPLICATION_CREDENTIALS"
export GCP_APP_SERVICE_ACCOUNT_EMAIL="app@example.invalid"
export GCP_APP_CREDENTIALS_ENABLED=true
export GCP_PROJECT="test-project"
export GCP_INSTANCE_NAME="test-instance"
export ROTATION_MIN_AGE_SECONDS=0
export ROTATION_DISABLE_GRACE_SECONDS=86400
export ROTATION_AUTH_MAX_RETRIES=3
export ROTATION_AUTH_SLEEP_SECONDS=0
export ROTATION_RECOVERY_SETTLE_SECONDS=0
export ROTATION_CREDENTIAL_OWNER=
export ROTATION_CREDENTIAL_GROUP=test-group
export ROTATION_RUNTIME_DIR="$tmp/run/key-rotation"
export GCP_APP_SERVICE_ACCOUNT_MANAGED=false
export NEW_KEY_ID="replacement-key"
export EXPECTED_CONSUMER_KEY_ID="$NEW_KEY_ID"

key_name() {
  printf 'projects/test-project/serviceAccounts/%s/keys/%s\n' "$1" "$2"
}

reset_operation_counts() {
  : >"$order_log"
  printf '0\n' >"$post_count"
  printf '0\n' >"$auth_count"
  printf '0\n' >"$list_count"
  printf '0\n' >"$sync_count"
}

reset_key_state() {
  local email="$1" old_id="$2"
  jq -n --arg name "$(key_name "$email" "$old_id")" \
    '[{name: $name, disabled: false}]' >"$key_state"
  reset_operation_counts
}

reset_key_state_many() {
  local email="$1" count="$2" index

  jq -n '[]' >"$key_state"
  for ((index = 1; index <= count; index++)); do
    jq --arg name "$(key_name "$email" "orphan-$index")" \
      '. + [{name: $name, disabled: false}]' \
      "$key_state" >"$key_state.tmp"
    mv "$key_state.tmp" "$key_state"
  done
  reset_operation_counts
}

write_credentials() {
  local file="$1" key_id="$2" email="${3:-app@example.invalid}"

  install -d "$(dirname -- "$file")"
  jq -n --arg key_id "$key_id" --arg email "$email" '{
    type: "service_account",
    project_id: "test-project",
    private_key_id: $key_id,
    private_key: "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n",
    client_email: $email,
    token_uri: "https://oauth2.googleapis.com/token"
  }' >"$file"
}

central_cleanup() {
  rm -f -- "$APP_CREDENTIALS_FILE" "${APP_CREDENTIALS_FILE}.rotation-"* \
    "${APP_CREDENTIALS_FILE}.rotation.lock" 2>/dev/null || true
  rm -rf -- "$tmp/apps/alpha/secrets" "$tmp/apps/beta/secrets"
}

# File credentials are opt-in. A clean disabled deployment is a no-op, while a
# stale credential fails closed until its remote key is explicitly retired.
central_cleanup
reset_key_state app@example.invalid old-key
GCP_APP_CREDENTIALS_ENABLED=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
[[ "$(<"$post_count")" == 0 ]] || fail "disabled app credentials created a cloud key"
write_credentials "$APP_CREDENTIALS_FILE" old-key
if GCP_APP_CREDENTIALS_ENABLED=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "disabled app credentials accepted a stale local key"
fi
if grep -Eq 'DELETE |POST' "$order_log"; then
  fail "disabled stale-credential detection mutated IAM"
fi

# JSON strings are structurally parsed by jq, while key-ID text validation is
# performed by Bash for COS compatibility. Preserve trailing control bytes
# through extraction so they cannot be normalized into an accepted key ID.
write_credentials "$APP_CREDENTIALS_FILE" $'old-key\n'
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$APP_CREDENTIALS_FILE" >/dev/null 2>&1; then
  fail "rotation normalized a trailing newline in a credential key ID"
fi
jq '.private_key_id = "old-key\u0000"' "$APP_CREDENTIALS_FILE" >"$APP_CREDENTIALS_FILE.tmp"
mv "$APP_CREDENTIALS_FILE.tmp" "$APP_CREDENTIALS_FILE"
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$APP_CREDENTIALS_FILE" >/dev/null 2>&1; then
  fail "rotation normalized a NUL in a credential key ID"
fi
if grep -Eq 'DELETE |POST' "$order_log"; then
  fail "invalid credential key-ID validation mutated IAM"
fi

invalid_state_credentials="$tmp/invalid-state/GOOGLE_APPLICATION_CREDENTIALS"
install -d "$(dirname -- "$invalid_state_credentials")"
jq -n \
  --arg credentials_file "$invalid_state_credentials" \
  --arg baseline_name "$(key_name app@example.invalid old-key)"$'\n' '{
    version: 2,
    phase: "creating",
    service_account: "app@example.invalid",
    project_id: "test-project",
    credentials_file: $credentials_file,
    current_key_id: "old-key",
    new_key_id: "",
    new_key_name: "",
    baseline_key_names: [$baseline_name],
    created_at: 1,
    ready_at: 0,
    disabled_at: 0
  }' >"${invalid_state_credentials}.rotation-pending.json"
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" status \
  app@example.invalid test-project "$invalid_state_credentials" >/dev/null 2>&1; then
  fail "rotation normalized a trailing newline in a baseline key name"
fi
jq --arg name "$(key_name app@example.invalid old-key)" \
  '.baseline_key_names = [$name, $name]' \
  "${invalid_state_credentials}.rotation-pending.json" \
  >"${invalid_state_credentials}.rotation-pending.json.tmp"
mv "${invalid_state_credentials}.rotation-pending.json.tmp" \
  "${invalid_state_credentials}.rotation-pending.json"
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" status \
  app@example.invalid test-project "$invalid_state_credentials" >/dev/null 2>&1; then
  fail "rotation accepted duplicate names in a durable reconciliation baseline"
fi
write_credentials "$APP_CREDENTIALS_FILE" old-key

# Retirement deletes the currently installed remote key before removing every
# local and per-app credential artifact.
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" retire >/dev/null
[[ ! -e "$APP_CREDENTIALS_FILE" ]] || fail "credential retirement retained the central key file"
if jq -e --arg name "$(key_name app@example.invalid old-key)" \
  'any(.[]; .name == $name)' "$key_state" >/dev/null; then
  fail "credential retirement retained the remote user-managed key"
fi

# Losing the local credential does not prove that its remote private key was
# revoked. Retirement must surface the remaining audited key IDs and fail
# closed rather than silently making the disabled state look clean.
central_cleanup
reset_key_state app@example.invalid orphaned-remote-key
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" retire \
  app@example.invalid test-project "$APP_CREDENTIALS_FILE" >"$tmp/retire.out" 2>"$tmp/retire.err"; then
  fail "credential retirement accepted an absent local file with a live remote key"
fi
grep -Fq 'orphaned-remote-key' "$tmp/retire.err" || fail "retirement did not report the audited remote key ID"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "retirement guessed which remote key to delete without a local credential"
fi
jq -n '[]' >"$key_state"
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" retire \
  app@example.invalid test-project "$APP_CREDENTIALS_FILE" >/dev/null

reset_key_state app@example.invalid old-key
central_cleanup
write_credentials "$APP_CREDENTIALS_FILE" old-key

# Every application source/path is validated before IAM is mutated.
if FAKE_SOURCE_INVALID=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "rotation accepted an invalid Compose source"
fi
[[ "$(<"$post_count")" == 0 ]] || fail "invalid Compose source triggered key creation"
if ROTATION_CREDENTIAL_GROUP='--reference=unsafe' \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "rotation accepted an option-like credential group"
fi
[[ "$(<"$post_count")" == 0 ]] || fail "invalid credential group triggered key creation"

# Authenticate before distribution, and retain authenticated state if only part
# of the app credential fan-out succeeds.
if FAKE_CHGRP_FAIL_BETA=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "rotation accepted a partial credential distribution failure"
fi
[[ "$(<"$post_count")" == 1 ]] || fail "distribution failure did not create exactly one replacement key"
[[ "$(<"$auth_count")" == 1 ]] || fail "replacement key was not authenticated before distribution"
jq -e '.phase == "authenticated" and .current_key_id == "old-key" and .new_key_id == "replacement-key"' \
  "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || fail "distribution failure did not retain authenticated state"
[[ -s "${APP_CREDENTIALS_FILE}.rotation-previous.json" ]] || fail "previous credentials were not preserved"
grep -Fq "CHOWN -- cloud-compose $tmp/apps/alpha/secrets" "$order_log" || \
  fail "application secret directory is not assigned to the cloud-compose owner"
[[ "$(stat -c %a "$tmp/apps/alpha/secrets")" == "750" ]] || \
  fail "application secret directory does not preserve private owner-write intent"
[[ "$(stat -c %a "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS")" == "440" ]] || \
  fail "application credential is not read-only and group-readable"
if grep -Eq 'RESTART |DISABLE |DELETE ' "$order_log"; then
  fail "distribution failure restarted consumers or changed the previous key"
fi
creating_sync_line="$(grep -n '^SYNC 1$' "$order_log" | cut -d: -f1)"
creating_post_line="$(grep -n '^POST$' "$order_log" | cut -d: -f1)"
[[ -n "$creating_sync_line" && -n "$creating_post_line" &&
  "$creating_sync_line" -lt "$creating_post_line" ]] ||
  fail "ordinary key creation outran its durable creating state"

# A failed reload cannot advance readiness or disable the previous key.
if FAKE_RESTART_FAIL=true FAKE_APP_ACTIVE=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "rotation accepted a failed app-container restart"
fi
jq -e '.phase == "authenticated"' "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || \
  fail "failed reload advanced rotation readiness"
if grep -Eq 'DISABLE |DELETE ' "$order_log"; then
  fail "failed reload changed the previous cloud key"
fi

# An intentionally inactive app remains inactive. Authentication and file
# distribution are sufficient for its next start; the old key is disabled but
# retained through the configured rollback grace.
: >"$order_log"
FAKE_RESTART_FAIL=false FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
if grep -Eq '^RESTART ' "$order_log"; then
  fail "rotation started or restarted an inactive application"
fi
jq -e '.phase == "grace" and .disabled_at > 0' "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || \
  fail "successful propagation did not enter rollback grace"
jq -e --arg name "$(key_name app@example.invalid old-key)" \
  'any(.[]; .name == $name and .disabled == true)' "$key_state" >/dev/null || fail "previous key was not disabled"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "previous key was deleted before rollback grace elapsed"
fi

# Re-running during grace neither creates nor deletes a key.
: >"$order_log"
chmod 0600 "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS"
ROTATION_CREDENTIAL_OWNER=100 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
[[ "$(<"$post_count")" == 1 ]] || fail "grace retry created another replacement key"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "grace retry deleted the disabled previous key too early"
fi
[[ "$(stat -c %a "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS")" == "440" ]] || \
  fail "identical application credentials did not converge their mode"
grep -Fq "CHOWN -- 100 $tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" "$order_log" || \
  fail "identical application credentials did not converge their owner"
grep -Fq "CHGRP -- test-group $tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" "$order_log" || \
  fail "identical application credentials did not converge their group"

# Rollback re-enables and authenticates the previous key, distributes it,
# reloads only the already-active service, then removes the abandoned key.
: >"$order_log"
export EXPECTED_CONSUMER_KEY_ID=old-key
# Simulate a crash after the core restored the old credential but before the
# wrapper distributed/reloaded consumers. Re-running the documented wrapper
# command must resume rather than reject the rollback phase.
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" rollback \
  app@example.invalid test-project "$APP_CREDENTIALS_FILE" >/dev/null
jq -e '.phase == "rollback"' "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || \
  fail "core rollback did not reach the resumable consumer phase"
FAKE_APP_ACTIVE=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" rollback >/dev/null
[[ ! -e "${APP_CREDENTIALS_FILE}.rotation-pending.json" ]] || fail "rollback left pending state"
jq -e '.private_key_id == "old-key"' "$APP_CREDENTIALS_FILE" >/dev/null || fail "rollback did not restore central credentials"
jq -e --arg name "$(key_name app@example.invalid old-key)" \
  'any(.[]; .name == $name and .disabled == false)' "$key_state" >/dev/null || fail "rollback did not re-enable the previous key"
if jq -e --arg name "$(key_name app@example.invalid replacement-key)" 'any(.[]; .name == $name)' "$key_state" >/dev/null; then
  fail "rollback retained the abandoned replacement key"
fi
enable_line="$(grep -n '^ENABLE ' "$order_log" | cut -d: -f1)"
restart_line="$(grep -n '^RESTART cloud-compose.service old-key$' "$order_log" | cut -d: -f1)"
delete_line="$(grep -n '/keys/replacement-key$' "$order_log" | tail -n1 | cut -d: -f1)"
[[ -n "$enable_line" && -n "$restart_line" && -n "$delete_line" ]] || fail "rollback audit sequence is incomplete"
(( enable_line < restart_line && restart_line < delete_line )) || fail "rollback key/service ordering is unsafe"

# Authentication propagation failure occurs before app credential replacement
# or reload, and the retry count is bounded.
central_cleanup
reset_key_state app@example.invalid old-key
write_credentials "$APP_CREDENTIALS_FILE" old-key
export NEW_KEY_ID=auth-failure-key EXPECTED_CONSUMER_KEY_ID=auth-failure-key
if FAKE_AUTH_FAIL_UNTIL=99 FAKE_APP_ACTIVE=true \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "rotation accepted replacement credentials that could not authenticate"
fi
[[ "$(<"$auth_count")" == "$ROTATION_AUTH_MAX_RETRIES" ]] || fail "authentication backoff was not bounded"
jq -e '.phase == "staged"' "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || \
  fail "authentication failure did not retain resumable staged state"
[[ ! -e "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" ]] || \
  fail "authentication failure distributed an unproven credential"
if grep -Eq '^RESTART ' "$order_log"; then
  fail "authentication failure restarted an app on an unproven key"
fi

# An indeterminate create is never retried automatically. Audit exposes only
# key IDs, and recovery deletes only the explicitly confirmed single delta.
ambiguous="$tmp/ambiguous/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$ambiguous" old-key
export NEW_KEY_ID=ambiguous-key
if FAKE_POST_MODE=ambiguous-create bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$ambiguous" >/dev/null 2>&1; then
  fail "rotation accepted an indeterminate key-creation response"
fi
if FAKE_POST_MODE=success bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$ambiguous" >/dev/null 2>&1; then
  fail "rotation retried an indeterminate key creation"
fi
[[ "$(<"$post_count")" == 1 ]] || fail "indeterminate creation issued another POST"
audit="$(bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" audit \
  app@example.invalid test-project "$ambiguous")"
jq -e '.phase == "creating" and .recovery_required == true and .candidate_key_ids == ["ambiguous-key"]' \
  <<<"$audit" >/dev/null || fail "ambiguous creation audit was incomplete"
if bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" recover \
  app@example.invalid test-project "$ambiguous" wrong-key >/dev/null 2>&1; then
  fail "ambiguous recovery accepted the wrong key confirmation"
fi
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" recover \
  app@example.invalid test-project "$ambiguous" ambiguous-key >/dev/null
[[ ! -e "${ambiguous}.rotation-pending.json" ]] || fail "confirmed recovery left ambiguous state"
if jq -e --arg name "$(key_name app@example.invalid ambiguous-key)" 'any(.[]; .name == $name)' "$key_state" >/dev/null; then
  fail "confirmed orphan key was not deleted"
fi

# If the API audit proves that no key was created, recovery can clear state
# without a destructive confirmation.
no_create="$tmp/no-create/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$no_create" old-key
export NEW_KEY_ID=no-create-key
if FAKE_POST_MODE=fail-no-create bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$no_create" >/dev/null 2>&1; then
  fail "rotation accepted a failed no-create request"
fi
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" recover \
  app@example.invalid test-project "$no_create" >/dev/null
[[ ! -e "${no_create}.rotation-pending.json" ]] || fail "zero-delta recovery did not clear state"

# Deletion is idempotent: a 404 after grace means the desired absent state has
# already been reached and local rollback state can be cleaned up.
idempotent="$tmp/idempotent/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$idempotent" old-key
export NEW_KEY_ID=idempotent-key ROTATION_DISABLE_GRACE_SECONDS=86400
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare app@example.invalid test-project "$idempotent" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" authenticate app@example.invalid test-project "$idempotent" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" ready app@example.invalid test-project "$idempotent" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit app@example.invalid test-project "$idempotent" >/dev/null
jq --arg name "$(key_name app@example.invalid old-key)" 'map(select(.name != $name))' "$key_state" >"$key_state.tmp"
mv "$key_state.tmp" "$key_state"
ROTATION_DISABLE_GRACE_SECONDS=0 bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit \
  app@example.invalid test-project "$idempotent" >/dev/null
[[ ! -e "${idempotent}.rotation-pending.json" ]] || fail "idempotent 404 deletion retained grace state"
grep -Fq "DELETE404 $(key_name app@example.invalid old-key)" "$order_log" || fail "404 deletion path was not exercised"

# Disable and delete failures retain the exact retry phase and both credential
# generations. Neither retry may create another replacement key.
failure_retry="$tmp/failure-retry/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$failure_retry" old-key
export NEW_KEY_ID=failure-retry-key ROTATION_DISABLE_GRACE_SECONDS=0
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare app@example.invalid test-project "$failure_retry" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" authenticate app@example.invalid test-project "$failure_retry" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" ready app@example.invalid test-project "$failure_retry" >/dev/null
if FAKE_DISABLE_FAIL=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit \
  app@example.invalid test-project "$failure_retry" >/dev/null 2>&1; then
  fail "rotation accepted a failed old-key disable"
fi
jq -e '.phase == "ready"' "${failure_retry}.rotation-pending.json" >/dev/null || \
  fail "failed disable did not retain ready state"
FAKE_DISABLE_FAIL=false bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit \
  app@example.invalid test-project "$failure_retry" >/dev/null
jq -e '.phase == "grace"' "${failure_retry}.rotation-pending.json" >/dev/null || \
  fail "successful disable did not enter grace"
if FAKE_DELETE_FAIL=true bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit \
  app@example.invalid test-project "$failure_retry" >/dev/null 2>&1; then
  fail "rotation accepted a failed old-key deletion"
fi
jq -e '.phase == "grace"' "${failure_retry}.rotation-pending.json" >/dev/null || \
  fail "failed deletion did not retain grace state"
[[ -s "${failure_retry}.rotation-previous.json" ]] || fail "failed deletion discarded rollback credentials"
FAKE_DELETE_FAIL=false bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit \
  app@example.invalid test-project "$failure_retry" >/dev/null
[[ ! -e "${failure_retry}.rotation-pending.json" ]] || fail "delete retry did not finish rotation"
[[ "$(<"$post_count")" == 1 ]] || fail "disable/delete retries created another replacement key"

# A failed state durability barrier stops before the create request. The
# renamed state may be visible in the live filesystem, but IAM remains
# untouched until a later run can durably flush it.
durability="$tmp/durability/GOOGLE_APPLICATION_CREDENTIALS"
central_cleanup
reset_key_state app@example.invalid old-key
write_credentials "$durability" old-key
export NEW_KEY_ID=durability-key
if FAKE_SYNC_FAIL_AT=1 bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$durability" >/dev/null 2>&1; then
  fail "rotation accepted a failed pre-create state durability barrier"
fi
[[ "$(<"$post_count")" == 0 ]] ||
  fail "failed state durability barrier issued a create request"
if grep -Eq '^(DELETE |DISABLE |ENABLE )' "$order_log"; then
  fail "failed state durability barrier mutated IAM"
fi

# First provisioning has no rollback key and therefore never disables/deletes
# another service-account key.
first="$tmp/first/GOOGLE_APPLICATION_CREDENTIALS"
jq -n '[]' >"$key_state"
: >"$order_log"
export NEW_KEY_ID=first-key ROTATION_DISABLE_GRACE_SECONDS=0
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare app@example.invalid test-project "$first" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" authenticate app@example.invalid test-project "$first" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" ready app@example.invalid test-project "$first" >/dev/null
bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" commit app@example.invalid test-project "$first" >/dev/null
if grep -Eq '^(DISABLE|DELETE) ' "$order_log"; then
  fail "first-time provisioning changed a key without a previous local credential"
fi

# A trusted marker on a newly formatted data filesystem authorizes the
# module-owned app identity to delete its exact orphan baseline before creating
# one replacement. Rotation itself leaves consumption to the bootstrap
# boundary immediately after every enabled identity has converged.
fresh_data_root="$tmp/fresh-data"
fresh_marker="$fresh_data_root/.cloud-compose/fresh-filesystem"
fresh_identity="v1:gcp-disk-id:987654321012345678"
mkdir -p "$(dirname -- "$fresh_marker")"
chmod 1775 "$fresh_data_root"
chmod 0700 "$(dirname -- "$fresh_marker")"
printf '%s\n' "$fresh_identity" >"$fresh_marker"
chmod 0600 "$fresh_marker"
export FAKE_FRESH_MARKER="$fresh_marker"
export CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER="$fresh_marker"
export CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY="$fresh_identity"

# A root-owned marker copied from a snapshot of another data-disk incarnation
# is not destructive authority. Reject it before even listing IAM keys.
printf 'v1:gcp-disk-id:111111111111111111\n' >"$fresh_marker"
central_cleanup
reset_key_state_many app@example.invalid 2
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh reconciliation accepted another disk incarnation"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log" ||
  [[ "$(<"$list_count")" != 0 ]]; then
  fail "mismatched disk-incarnation authority reached IAM"
fi
printf '%s\n' "$fresh_identity" >"$fresh_marker"

central_cleanup
reset_key_state_many app@example.invalid 1
export NEW_KEY_ID=fresh-durability-key EXPECTED_CONSUMER_KEY_ID=fresh-durability-key
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  FAKE_SYNC_FAIL_AT=1 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh reconciliation accepted a failed baseline durability barrier"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "fresh reconciliation mutated IAM before its baseline became durable"
fi

central_cleanup
reset_key_state_many app@example.invalid 10
export NEW_KEY_ID=fresh-key EXPECTED_CONSUMER_KEY_ID=fresh-key
GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
[[ "$(<"$post_count")" == 1 ]] || fail "fresh managed reconciliation did not create exactly one key"
[[ "$(grep -c '^DELETE ' "$order_log")" == 10 ]] || fail "fresh managed reconciliation did not delete its exact ten-key baseline"
last_delete_line="$(grep -n '^DELETE ' "$order_log" | tail -n1 | cut -d: -f1)"
post_line="$(grep -n '^POST$' "$order_log" | cut -d: -f1)"
((last_delete_line < post_line)) || fail "fresh managed reconciliation created a key before deleting its baseline"
first_delete_line="$(grep -n '^DELETE ' "$order_log" | head -n1 | cut -d: -f1)"
first_sync_line="$(grep -n '^SYNC 1$' "$order_log" | cut -d: -f1)"
second_sync_line="$(grep -n '^SYNC 2$' "$order_log" | cut -d: -f1)"
[[ -n "$first_sync_line" && -n "$second_sync_line" &&
  "$first_sync_line" -lt "$first_delete_line" &&
  "$last_delete_line" -lt "$second_sync_line" &&
  "$second_sync_line" -lt "$post_line" ]] ||
  fail "fresh reconciliation IAM mutations outran their durable state transitions"
jq -e --arg name "$(key_name app@example.invalid fresh-key)" \
  'length == 1 and .[0].name == $name' "$key_state" >/dev/null ||
  fail "fresh managed reconciliation did not converge to one replacement key"
[[ -f "$fresh_marker" ]] || fail "key rotation consumed the shared fresh-filesystem marker inside one identity wrapper"

# A delete that reaches IAM but loses its successful response retains the exact
# baseline. The retry accepts 404 and cannot create until every baseline key is
# absent.
central_cleanup
reset_key_state_many app@example.invalid 2
export NEW_KEY_ID=fresh-retry-key EXPECTED_CONSUMER_KEY_ID=fresh-retry-key
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  FAKE_DELETE_FAIL_AFTER_MUTATION_ID=orphan-1 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted an indeterminate orphan deletion"
fi
jq -e '.phase == "reconciling" and (.baseline_key_names | length) == 2' \
  "${APP_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null ||
  fail "failed orphan deletion did not retain the exact reconciliation baseline"
[[ "$(<"$post_count")" == 0 ]] || fail "failed orphan deletion created a replacement key"
GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  FAKE_DELETE_FAIL_AFTER_MUTATION_ID=orphan-1 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
[[ "$(<"$post_count")" == 1 ]] || fail "orphan deletion retry did not create exactly one replacement"
grep -Fq "DELETE404 $(key_name app@example.invalid orphan-1)" "$order_log" ||
  fail "orphan deletion retry did not accept the already-absent key"

# A key created by another actor after the durable baseline snapshot is never
# swept into the managed set, and permanently blocks creation until audited.
central_cleanup
reset_key_state_many app@example.invalid 1
export NEW_KEY_ID=blocked-fresh-key EXPECTED_CONSUMER_KEY_ID=blocked-fresh-key
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  FAKE_INJECT_KEY_ON_LIST=concurrent-key \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted a concurrent key"
fi
[[ "$(<"$post_count")" == 0 ]] || fail "concurrent key detection issued a create"
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  FAKE_INJECT_KEY_ON_LIST=concurrent-key \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation swept a concurrent key on retry"
fi
jq -e --arg name "$(key_name app@example.invalid concurrent-key)" \
  'length == 1 and .[0].name == $name' "$key_state" >/dev/null ||
  fail "fresh managed reconciliation deleted the concurrent key"
[[ "$(<"$post_count")" == 0 ]] || fail "concurrent key retry issued a create"

# Reconciliation is unavailable to supplied identities and to any service that
# is not exactly loaded and inactive.
central_cleanup
reset_key_state_many app@example.invalid 1
export NEW_KEY_ID=unmanaged-key EXPECTED_CONSUMER_KEY_ID=unmanaged-key
GCP_APP_SERVICE_ACCOUNT_MANAGED=false FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
if grep -Eq '^DELETE ' "$order_log"; then
  fail "caller-supplied app identity deleted a baseline key"
fi
jq -e 'length == 2' "$key_state" >/dev/null ||
  fail "caller-supplied app identity did not preserve its remote baseline"

# Both independent proofs are required. A managed identity without the
# root-owned fresh-filesystem marker follows ordinary provisioning and never
# treats pre-existing keys as its deletion set.
rm -f -- "$fresh_marker"
central_cleanup
reset_key_state_many app@example.invalid 1
export NEW_KEY_ID=managed-without-marker EXPECTED_CONSUMER_KEY_ID=managed-without-marker
GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
if grep -Eq '^DELETE ' "$order_log"; then
  fail "managed app identity deleted a baseline without fresh-filesystem authority"
fi
jq -e 'length == 2' "$key_state" >/dev/null ||
  fail "managed app identity without a fresh marker did not preserve its remote baseline"

# Ordinary rotation cannot exceed IAM's ten-key quota and must fail before
# persisting an ambiguous create state.
central_cleanup
reset_key_state_many app@example.invalid 10
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "ordinary provisioning accepted an already-full IAM key quota"
fi
[[ "$(<"$post_count")" == 0 ]] || fail "full ordinary key quota issued a create"
[[ ! -e "${APP_CREDENTIALS_FILE}.rotation-pending.json" ]] ||
  fail "full ordinary key quota persisted an ambiguous create state"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "full ordinary key quota deleted an existing key"
fi

# Invalid identity ownership configuration fails before any IAM request.
central_cleanup
reset_key_state_many app@example.invalid 1
if GCP_APP_SERVICE_ACCOUNT_MANAGED=unexpected \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "app wrapper accepted invalid managed-identity configuration"
fi
[[ "$(<"$post_count")" == 0 && "$(<"$list_count")" == 0 ]] ||
  fail "invalid managed-identity configuration reached IAM"

printf '%s\n' "$fresh_identity" >"$fresh_marker"
chmod 0600 "$fresh_marker"
central_cleanup
reset_key_state_many app@example.invalid 1
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=failed \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted a failed application service"
fi
[[ "$(<"$post_count")" == 0 ]] || fail "failed application service allowed key creation"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "failed application service allowed orphan deletion"
fi

# A malformed, duplicate, or over-limit IAM inventory cannot be converted into
# a deletion baseline.
central_cleanup
jq -n --arg name "$(key_name app@example.invalid duplicate-key)" \
  '[{name: $name, disabled: false}, {name: $name, disabled: false}]' >"$key_state"
reset_operation_counts
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted duplicate IAM key entries"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "duplicate IAM key inventory triggered a mutation"
fi

central_cleanup
jq -n '[{
  keyType: "USER_MANAGED",
  name: "projects/other-project/serviceAccounts/other@example.invalid/keys/foreign-key",
  disabled: false
}]' >"$key_state"
reset_operation_counts
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted a foreign IAM key name"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "foreign IAM key inventory triggered a mutation"
fi

central_cleanup
reset_key_state_many app@example.invalid 11
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true FAKE_APP_STATE=inactive FAKE_APP_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "fresh managed reconciliation accepted more than IAM's key limit"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "over-limit IAM key inventory triggered a mutation"
fi

# A missing central file is recovered only when every existing distributed copy
# is valid for the exact target and byte-identical.
central_cleanup
reset_key_state app@example.invalid supplied-victim-key
write_credentials "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" supplied-victim-key
write_credentials "$tmp/apps/beta/secrets/GOOGLE_APPLICATION_CREDENTIALS" supplied-victim-key
if GCP_APP_SERVICE_ACCOUNT_MANAGED=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "caller-supplied identity promoted distributed credentials into revocation authority"
fi
[[ ! -e "$APP_CREDENTIALS_FILE" ]] ||
  fail "caller-supplied identity restored an unproven central credential"
[[ "$(<"$post_count")" == 0 && "$(<"$list_count")" == 0 ]] ||
  fail "caller-supplied distributed credential recovery reached IAM"
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "caller-supplied distributed credential recovery mutated IAM"
fi

central_cleanup
reset_key_state app@example.invalid recovered-key
write_credentials "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" recovered-key
write_credentials "$tmp/apps/beta/secrets/GOOGLE_APPLICATION_CREDENTIALS" recovered-key
touch -d '10 minutes ago' \
  "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" \
  "$tmp/apps/beta/secrets/GOOGLE_APPLICATION_CREDENTIALS"
recovered_modified_at="$(stat -c %Y "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS")"
GCP_APP_SERVICE_ACCOUNT_MANAGED=true ROTATION_MIN_AGE_SECONDS=86400 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null
cmp -s "$APP_CREDENTIALS_FILE" "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" ||
  fail "unanimous distributed credentials were not restored centrally"
[[ "$(stat -c %Y "$APP_CREDENTIALS_FILE")" == "$recovered_modified_at" ]] ||
  fail "distributed credential recovery reset the credential rotation age"
[[ "$(<"$post_count")" == 0 ]] || fail "distributed credential recovery created a cloud key"
if grep -Eq '^DELETE ' "$order_log"; then
  fail "distributed credential recovery deleted a cloud key"
fi

central_cleanup
reset_key_state app@example.invalid recovered-key
write_credentials "$tmp/apps/alpha/secrets/GOOGLE_APPLICATION_CREDENTIALS" recovered-key
write_credentials "$tmp/apps/beta/secrets/GOOGLE_APPLICATION_CREDENTIALS" conflicting-key
if GCP_APP_SERVICE_ACCOUNT_MANAGED=true ROTATION_MIN_AGE_SECONDS=86400 \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-app.sh" >/dev/null 2>&1; then
  fail "conflicting distributed credentials were accepted"
fi
[[ ! -e "$APP_CREDENTIALS_FILE" ]] || fail "conflicting distributed credentials restored a central key"
[[ "$(<"$post_count")" == 0 ]] || fail "conflicting distributed credentials created a cloud key"

# Definite IAM rejection does not strand an ambiguous state. Request timeout
# remains ambiguous and a complete response is salvageable after a late
# transport failure.
definite="$tmp/definite/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$definite" old-key
export NEW_KEY_ID=definite-key
if FAKE_POST_MODE=rejected-400 bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$definite" >/dev/null 2>&1; then
  fail "definite IAM key rejection was accepted"
fi
[[ ! -e "${definite}.rotation-pending.json" ]] ||
  fail "definite IAM key rejection retained ambiguous state"

timeout="$tmp/timeout/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$timeout" old-key
export NEW_KEY_ID=timeout-key
if FAKE_POST_MODE=ambiguous-408 bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$timeout" >/dev/null 2>&1; then
  fail "ambiguous HTTP 408 key creation was accepted"
fi
if FAKE_POST_MODE=success bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$timeout" >/dev/null 2>&1; then
  fail "ambiguous HTTP 408 key creation was retried"
fi
[[ "$(<"$post_count")" == 1 ]] || fail "ambiguous HTTP 408 issued another POST"
jq -e '.phase == "creating"' "${timeout}.rotation-pending.json" >/dev/null ||
  fail "ambiguous HTTP 408 did not retain creating state"

late="$tmp/late/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state app@example.invalid old-key
write_credentials "$late" old-key
export NEW_KEY_ID=late-key
FAKE_POST_MODE=late-success bash "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" prepare \
  app@example.invalid test-project "$late" >/dev/null
jq -e '.phase == "staged" and .new_key_id == "late-key"' \
  "${late}.rotation-pending.json" >/dev/null ||
  fail "complete IAM response was not salvaged after a late transport failure"

# The internal-service wrapper follows the same no-start rule.
internal_email="internal-test-instance@test-project.iam.gserviceaccount.com"
export INTERNAL_CREDENTIALS_FILE="$tmp/internal/GOOGLE_APPLICATION_CREDENTIALS"
reset_key_state "$internal_email" internal-old
write_credentials "$INTERNAL_CREDENTIALS_FILE" internal-old "$internal_email"
export NEW_KEY_ID=internal-new EXPECTED_CONSUMER_KEY_ID=internal-new ROTATION_DISABLE_GRACE_SECONDS=86400
: >"$order_log"
FAKE_INTERNAL_ACTIVE=false bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-internal.sh" >/dev/null
if grep -Fq 'RESTART cloud-compose-internal-services.service' "$order_log"; then
  fail "rotation started or restarted inactive internal services"
fi
jq -e '.phase == "grace"' "${INTERNAL_CREDENTIALS_FILE}.rotation-pending.json" >/dev/null || \
  fail "inactive internal service did not complete authenticated propagation"

# The internal identity is always module-created and uses the same trusted
# fresh-filesystem reconciliation before first provisioning.
rm -f -- "$INTERNAL_CREDENTIALS_FILE" "${INTERNAL_CREDENTIALS_FILE}.rotation-"*
reset_key_state_many "$internal_email" 10
export NEW_KEY_ID=internal-fresh EXPECTED_CONSUMER_KEY_ID=internal-fresh
FAKE_INTERNAL_STATE=inactive FAKE_INTERNAL_ACTIVE=false \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-internal.sh" >/dev/null
[[ "$(<"$post_count")" == 1 ]] || fail "fresh internal reconciliation did not create exactly one key"
jq -e --arg name "$(key_name "$internal_email" internal-fresh)" \
  'length == 1 and .[0].name == $name' "$key_state" >/dev/null ||
  fail "fresh internal reconciliation did not converge to one replacement key"

# The internal identity uses the same exact inactive-service gate. Failed or
# unqueryable unit state cannot authorize deletion.
rm -f -- "$INTERNAL_CREDENTIALS_FILE" "${INTERNAL_CREDENTIALS_FILE}.rotation-"*
reset_key_state_many "$internal_email" 1
if FAKE_INTERNAL_STATE=failed \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-internal.sh" >/dev/null 2>&1; then
  fail "fresh internal reconciliation accepted a failed service"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "failed internal service allowed IAM mutation"
fi

rm -f -- "$INTERNAL_CREDENTIALS_FILE" "${INTERNAL_CREDENTIALS_FILE}.rotation-"*
reset_key_state_many "$internal_email" 1
if FAKE_SYSTEMCTL_QUERY_FAIL=true \
  bash "$repo_root/rootfs/home/cloud-compose/rotate-keys-internal.sh" >/dev/null 2>&1; then
  fail "fresh internal reconciliation accepted an unqueryable service state"
fi
if grep -Eq '^(DELETE |POST$)' "$order_log"; then
  fail "unqueryable internal service allowed IAM mutation"
fi

if find "$ROTATION_RUNTIME_DIR" -maxdepth 1 -type f -name 'iam-create-response.*' -print -quit |
  grep -q .; then
  fail "rotation retained an ephemeral IAM private-key response"
fi
if find "$tmp" -type f -name '.iam-create-response.*' -print -quit | grep -q .; then
  fail "rotation wrote an IAM private-key response to persistent credential storage"
fi
grep -Fq 'mktemp "${ROTATION_RUNTIME_DIR}/iam-create-response.XXXXXX"' \
  "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" ||
  fail "IAM private-key responses are not staged under the ephemeral runtime directory"
grep -Fq 'trap cleanup_ephemeral_create_response EXIT' \
  "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" ||
  fail "IAM private-key response cleanup is not registered for process exit"

echo "Key rotation contract passed"
