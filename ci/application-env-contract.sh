#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-application-env.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd bash
require_cmd base64
require_cmd jq

profile="$repo_root/rootfs/home/cloud-compose/profile.sh"
rollout_service="$repo_root/rootfs/home/cloud-compose/run-rollout-service.sh"
host_env="$tmp/host.env"
application_env="$tmp/application-env.json"
bash_env_payload="$tmp/untrusted-bash-env.sh"
bash_env_marker="$tmp/bash-env-executed"

cat >"$host_env" <<'EOF'
HOME="/home/cloud-compose"
ROLLOUT_PORT="8081"
ROLLOUT_JWKS_URI="https://trusted.example/.well-known/jwks.json"
ROLLOUT_JWT_AUD="trusted-controller"
ROLLOUT_CUSTOM_CLAIMS="{\"role\":\"deployer\"}"
EOF

cat >"$bash_env_payload" <<EOF
touch "$bash_env_marker"
EOF

# The dollar expressions belong to jq or to literal application data.
# shellcheck disable=SC2016
jq -n \
  --arg bash_env "$bash_env_payload" \
  --arg ld_preload "$tmp/untrusted-preload.so" \
  --arg port "9999" \
  --arg jwks "https://attacker.invalid/jwks.json" \
  --arg aud "attacker" \
  --arg claims '{"admin":true}' \
  --arg literal $'quotes " and dollars $HOME $(touch /tmp/never)\nline two\n' \
  '{
    BASH_ENV: $bash_env,
    LD_PRELOAD: $ld_preload,
    PORT: $port,
    JWKS_URI: $jwks,
    JWT_AUD: $aud,
    CUSTOM_CLAIMS: $claims,
    APPLICATION_LITERAL: $literal
  }' >"$application_env"

for app in alpha beta; do
  mkdir -p "$tmp/$app"
  cat >"$tmp/$app/.env" <<'EOF'
# Downstream syntax is opaque and must survive reconciliation.
DOMAIN=example.org
EXPANDED=${DOMAIN}/path
EOF
done

# The child shell receives file paths as positional parameters.
# shellcheck disable=SC2016
env -i \
  PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$host_env" \
  CLOUD_COMPOSE_APPLICATION_ENV_FILE="$application_env" \
  bash --noprofile --norc -c '
    set -euo pipefail
    source "$1"
    shift
    for project_dir in "$@"; do
      cd "$project_dir"
      sync_compose_application_env
      update_compose_env COMPOSE_PROJECT_NAME "managed-${project_dir##*/}"
      update_compose_env SITE_NAME "site-${project_dir##*/}"
      update_compose_env COMPOSE_BIND_PORT "8080"
    done
    test -z "${BASH_ENV+x}"
    test -z "${LD_PRELOAD+x}"
    bash --noprofile --norc -c true
  ' application-env "$profile" "$tmp/alpha" "$tmp/beta"

test ! -e "$bash_env_marker"

assert_compose_value() {
  local env_file="$1" name="$2" expected="$3" assignment encoded decoded

  # The dollar expression belongs to awk.
  # shellcheck disable=SC2016
  assignment="$(awk -v marker="# cloud-compose application: $name" '
    found { print; exit }
    $0 == marker { found = 1 }
  ' "$env_file")"
  [[ "$assignment" == "$name="* ]] || {
    echo "$name was not reconciled into $env_file" >&2
    exit 1
  }
  encoded="${assignment#*=\"}"
  encoded="${encoded%\"}"
  # The child shell receives values as positional parameters.
  # shellcheck disable=SC2016
  decoded="$(
    CLOUD_COMPOSE_ENV_FILE="$host_env" bash --noprofile --norc -c '
      source "$1"
      decode_runtime_env_value "$2"
      printf "%s\037" "$RUNTIME_ENV_DECODED"
    ' application-env "$profile" "$encoded"
  )"
  decoded="${decoded%$'\x1f'}"
  [[ "$decoded" == "$expected" ]] || {
    echo "$name changed while being written to $env_file" >&2
    exit 1
  }
}

for app in alpha beta; do
  assert_compose_value "$tmp/$app/.env" BASH_ENV "$bash_env_payload"
  assert_compose_value "$tmp/$app/.env" LD_PRELOAD "$tmp/untrusted-preload.so"
  assert_compose_value "$tmp/$app/.env" PORT "9999"
  assert_compose_value "$tmp/$app/.env" JWKS_URI "https://attacker.invalid/jwks.json"
  assert_compose_value "$tmp/$app/.env" JWT_AUD "attacker"
  assert_compose_value "$tmp/$app/.env" CUSTOM_CLAIMS '{"admin":true}'
  assert_compose_value "$tmp/$app/.env" APPLICATION_LITERAL $'quotes " and dollars $HOME $(touch /tmp/never)\nline two\n'
  grep -Fq 'EXPANDED=${DOMAIN}/path' "$tmp/$app/.env"
  test "$(grep -Fc '# cloud-compose managed: COMPOSE_PROJECT_NAME' "$tmp/$app/.env")" = 1
  test "$(tail -n 1 "$tmp/$app/.env")" = 'COMPOSE_BIND_PORT="8080"'
done

mkdir -p "$tmp/invalid"
for invalid_application_data in \
  '{"SAFE\n":"value"}' \
  '{"SAFE\u0000":"value"}'; do
  printf '%s' "$invalid_application_data" >"$tmp/application-env.invalid.json"
  if env -i PATH=/usr/bin:/bin CLOUD_COMPOSE_ENV_FILE="$host_env" \
    CLOUD_COMPOSE_APPLICATION_ENV_FILE="$tmp/application-env.invalid.json" \
    bash --noprofile --norc -c '
      source "$1"
      cd "$2"
      sync_compose_application_env
    ' application-env "$profile" "$tmp/invalid" >/dev/null 2>&1; then
    echo "Application environment accepted a control-character name" >&2
    exit 1
  fi
  test ! -e "$tmp/invalid/.env"
done

# Removing a key from desired state removes only its marked application entry.
jq 'del(.APPLICATION_LITERAL)' "$application_env" >"$tmp/application-env.next.json"
# The child shell receives file paths as positional parameters.
# shellcheck disable=SC2016
env -i PATH=/usr/bin:/bin CLOUD_COMPOSE_ENV_FILE="$host_env" \
  CLOUD_COMPOSE_APPLICATION_ENV_FILE="$tmp/application-env.next.json" \
  bash --noprofile --norc -c '
    source "$1"
    cd "$2"
    sync_compose_application_env
  ' application-env "$profile" "$tmp/alpha"
! grep -Fq '# cloud-compose application: APPLICATION_LITERAL' "$tmp/alpha/.env"
grep -Fq '# cloud-compose managed: COMPOSE_BIND_PORT' "$tmp/alpha/.env"

fake_rollout="$tmp/fake-rollout"
rollout_result="$tmp/rollout-result"
cat >"$fake_rollout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -z "${BASH_ENV+x}"
test -z "${LD_PRELOAD+x}"
jq -n \
  --arg port "$PORT" \
  --arg jwks "$JWKS_URI" \
  --arg aud "$JWT_AUD" \
  --arg claims "$CUSTOM_CLAIMS" \
  '{port: $port, jwks: $jwks, aud: $aud, claims: $claims}' >"$ROLLOUT_RESULT"
EOF
chmod +x "$fake_rollout"

env -i \
  PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$host_env" \
  CLOUD_COMPOSE_PROFILE_PATH="$profile" \
  CLOUD_COMPOSE_ROLLOUT_BIN="$fake_rollout" \
  ROLLOUT_RESULT="$rollout_result" \
  bash --noprofile --norc "$rollout_service"

jq -e '
  .port == "8081" and
  .jwks == "https://trusted.example/.well-known/jwks.json" and
  .aud == "trusted-controller" and
  .claims == "{\"role\":\"deployer\"}"
' "$rollout_result" >/dev/null
test ! -e "$bash_env_marker"

insecure_rollout_env="$tmp/host-insecure-rollout.env"
invalid_claims_env="$tmp/host-invalid-claims.env"
sed 's#^ROLLOUT_JWKS_URI=.*#ROLLOUT_JWKS_URI="http://insecure.invalid/jwks.json"#' \
  "$host_env" >"$insecure_rollout_env"
sed 's#^ROLLOUT_CUSTOM_CLAIMS=.*#ROLLOUT_CUSTOM_CLAIMS="[\\"not-an-object\\"]"#' \
  "$host_env" >"$invalid_claims_env"

if env -i \
  PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$insecure_rollout_env" \
  CLOUD_COMPOSE_PROFILE_PATH="$profile" \
  CLOUD_COMPOSE_ROLLOUT_BIN="$fake_rollout" \
  ROLLOUT_RESULT="$rollout_result" \
  bash --noprofile --norc "$rollout_service" >/dev/null 2>&1; then
  echo "Rollout runtime accepted an insecure JWKS URL" >&2
  exit 1
fi

if env -i \
  PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$invalid_claims_env" \
  CLOUD_COMPOSE_PROFILE_PATH="$profile" \
  CLOUD_COMPOSE_ROLLOUT_BIN="$fake_rollout" \
  ROLLOUT_RESULT="$rollout_result" \
  bash --noprofile --norc "$rollout_service" >/dev/null 2>&1; then
  echo "Rollout runtime accepted non-object custom claims" >&2
  exit 1
fi

if grep -Eq '(^|[,[:space:]])var\.extra_env\)?$' \
  "$repo_root/modules/gcp/main.tf" "$repo_root/modules/linux-vm-runtime/main.tf"; then
  echo "Application extra_env is still merged into a host environment map" >&2
  exit 1
fi

echo "Application environment trust-boundary contract passed"
