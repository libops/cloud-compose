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
key_state="$tmp/key-state.json"
: >"$order_log"
printf '0\n' >"$post_count"
printf '0\n' >"$auth_count"

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
  is-active)
    unit="${!#}"
    case "$unit" in
      cloud-compose.service) [[ "${FAKE_APP_ACTIVE:-true}" == "true" ]] ;;
      cloud-compose-internal-services.service) [[ "${FAKE_INTERNAL_ACTIVE:-true}" == "true" ]] ;;
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
  local status="$1" body="${2:-{}}"
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
  jq -c '{keys: [.[] | {
    keyType: "USER_MANAGED",
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
  if [[ "${FAKE_POST_MODE:-success}" != "fail-no-create" ]]; then
    jq --arg name "$key_name" '. + [{name: $name, disabled: false}] | unique_by(.name)' \
      "$KEY_STATE" >"$KEY_STATE.tmp"
    mv "$KEY_STATE.tmp" "$KEY_STATE"
  fi
  case "${FAKE_POST_MODE:-success}" in
    fail-no-create | ambiguous-create) exit 22 ;;
  esac
  key_data="$(jq -nc --arg id "$NEW_KEY_ID" --arg email "$service_account" '{
    type: "service_account",
    project_id: "test-project",
    private_key_id: $id,
    private_key: "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n",
    client_email: $email,
    token_uri: "https://oauth2.googleapis.com/token"
  }' | base64 | tr -d '\n')"
  printf '{"name":"%s","privateKeyData":"%s"}\n' "$key_name" "$key_data"
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
export NEW_KEY_ID="replacement-key"
export EXPECTED_CONSUMER_KEY_ID="$NEW_KEY_ID"

key_name() {
  printf 'projects/test-project/serviceAccounts/%s/keys/%s\n' "$1" "$2"
}

reset_key_state() {
  local email="$1" old_id="$2"
  jq -n --arg name "$(key_name "$email" "$old_id")" \
    '[{name: $name, disabled: false}]' >"$key_state"
  : >"$order_log"
  printf '0\n' >"$post_count"
  printf '0\n' >"$auth_count"
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

echo "Key rotation contract passed"
