#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-runtime-config.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_line() {
  local file="$1"
  local value="$2"

  grep -Fq -- "$value" "$repo_root/$file" || {
    echo "$file does not implement the cloud-compose environment contract: $value" >&2
    exit 1
  }
}

require_pattern() {
  local file="$1"
  local pattern="$2"

  grep -Eq -- "$pattern" "$repo_root/$file" || {
    echo "$file does not implement the cloud-compose environment contract: $pattern" >&2
    exit 1
  }
}

quote_dotenv_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\$\$}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

write_contract_env() {
  local file="$1"
  local variable_name value

  {
    for variable_name in \
      BACKTICKS \
      BACKSLASH \
      COMMAND_SUB \
      DOLLAR_VALUE \
      DOUBLE_QUOTES \
      MULTILINE \
      SINGLE_QUOTE \
      TRAILING_SLASH \
      WHITESPACE \
      name; do
      value="${!variable_name}"
      printf '%s=' "$variable_name"
      quote_dotenv_value "$value"
      printf '\n'
    done
  } >"$file"
}

assert_runtime_values() {
  local env_file="$1"

  # The child shell receives values as positional parameters.
  # shellcheck disable=SC2016
  env -i PATH=/usr/bin:/bin \
    CLOUD_COMPOSE_ENV_FILE="$env_file" bash --noprofile --norc -c '
    source "$1"
    shift
    test "$BACKTICKS" = "$1"
    test "$BACKSLASH" = "$2"
    test "$COMMAND_SUB" = "$3"
    test "$DOLLAR_VALUE" = "$4"
    test "$DOUBLE_QUOTES" = "$5"
    test "$MULTILINE" = "$6"
    test "$SINGLE_QUOTE" = "$7"
    test "$TRAILING_SLASH" = "$8"
    test "$WHITESPACE" = "$9"
    test "$name" = "${10}"
  ' cloud-compose-env \
    "$repo_root/rootfs/home/cloud-compose/profile.sh" \
    "$BACKTICKS" \
    "$BACKSLASH" \
    "$COMMAND_SUB" \
    "$DOLLAR_VALUE" \
    "$DOUBLE_QUOTES" \
    "$MULTILINE" \
    "$SINGLE_QUOTE" \
    "$TRAILING_SLASH" \
    "$WHITESPACE" \
    "$name"
}

assert_compose_values() {
  local env_file="$1"
  local compose_file="$tmp/compose.yaml"
  local rendered="$tmp/compose-environment.txt"

  cat >"$compose_file" <<'EOF'
services:
  contract:
    image: scratch
    environment:
      BACKTICKS: ${BACKTICKS}
      BACKSLASH: ${BACKSLASH}
      COMMAND_SUB: ${COMMAND_SUB}
      DOLLAR_VALUE: ${DOLLAR_VALUE}
      DOUBLE_QUOTES: ${DOUBLE_QUOTES}
      MULTILINE: ${MULTILINE}
      SINGLE_QUOTE: ${SINGLE_QUOTE}
      TRAILING_SLASH: ${TRAILING_SLASH}
      WHITESPACE: ${WHITESPACE}
      name: ${name}
EOF

  docker compose --env-file "$env_file" -f "$compose_file" config --environment >"$rendered"
  python3 - \
    "$rendered" \
    "$BACKTICKS" \
    "$BACKSLASH" \
    "$COMMAND_SUB" \
    "$DOLLAR_VALUE" \
    "$DOUBLE_QUOTES" \
    "$MULTILINE" \
    "$SINGLE_QUOTE" \
    "$TRAILING_SLASH" \
    "$WHITESPACE" \
    "$name" <<'PY'
import sys
from pathlib import Path

rendered, *expected = sys.argv[1:]
environment = Path(rendered).read_text(encoding="utf-8")
names = ["BACKTICKS", "BACKSLASH", "COMMAND_SUB", "DOLLAR_VALUE", "DOUBLE_QUOTES", "MULTILINE", "SINGLE_QUOTE", "TRAILING_SLASH", "WHITESPACE", "name"]
for name, value in zip(names, expected, strict=True):
    rendered_value = f"{name}={value}\n"
    assert rendered_value in environment, (name, value, environment)
PY
}

require_cmd bash
require_cmd docker
require_cmd grep
require_cmd python3

require_line modules/runtime-env/main.tf "cloud-compose-env-contract"
require_line modules/runtime-env/main.tf 'escaped_dollars'
require_line modules/runtime-env/main.tf 'escaped_newlines'
require_line modules/runtime-env/main.tf 'escaped_quotes'
require_line modules/runtime-env/main.tf 'escaped_returns'
require_line modules/runtime-env/main.tf 'escaped_tabs'
require_line modules/linux-vm-runtime/main.tf 'module "runtime_env"'
require_line modules/linux-vm-runtime/main.tf 'base64gzip(module.runtime_env.content)'
require_line modules/linux-vm-runtime/main.tf 'path: "/home/cloud-compose/application-env.json"'
require_line modules/linux-vm-runtime/main.tf 'base64gzip(jsonencode(var.extra_env))'
require_line modules/linux-vm-runtime/main.tf 'SITECTL_PACKAGE_VERSIONS'
require_line modules/gcp/main.tf 'module "runtime_env"'
require_line modules/gcp/main.tf 'base64gzip(module.runtime_env.content)'
require_line modules/gcp/main.tf 'path: "/home/cloud-compose/application-env.json"'
require_line modules/gcp/main.tf 'base64gzip(jsonencode(var.extra_env))'
require_line modules/gcp/main.tf 'SITECTL_PACKAGE_VERSIONS'
require_line ansible/roles/cloud_compose/templates/env.j2 "cloud-compose-env-contract"
require_line ansible/roles/cloud_compose/templates/env.j2 'replace("\\", "\\\\")'
require_line ansible/roles/cloud_compose/templates/env.j2 'replace("$", "$$")'
require_line ansible/roles/cloud_compose/templates/env.j2 'replace("\n", "\\n")'
require_line ansible/roles/cloud_compose/templates/env.j2 'replace("\r", "\\r")'
require_line ansible/roles/cloud_compose/templates/env.j2 'replace("\t", "\\t")'
require_line ansible/roles/cloud_compose/tasks/main.yml 'SITECTL_PACKAGE_VERSIONS'
require_line ansible/roles/cloud_compose/tasks/main.yml 'application-env.json'
require_line salt/cloud-compose/files/env.jinja "cloud-compose-env-contract"
require_line salt/cloud-compose/files/env.jinja 'replace("\\", "\\\\")'
require_line salt/cloud-compose/files/env.jinja 'replace("$", "$$")'
require_line salt/cloud-compose/files/env.jinja 'replace("\n", "\\n")'
require_line salt/cloud-compose/files/env.jinja 'replace("\r", "\\r")'
require_line salt/cloud-compose/files/env.jinja 'replace("\t", "\\t")'
require_line salt/cloud-compose/init.sls 'SITECTL_PACKAGE_VERSIONS'
require_line salt/cloud-compose/init.sls 'application-env.json'
require_line modules/linux-vm-runtime/templates/cloud-init.yml "\${jsonencode(username)}"
require_line modules/linux-vm-runtime/templates/cloud-init.yml "\${jsonencode(key)}"
require_line templates/cloud-init.yml "\${jsonencode(username)}"
require_line templates/cloud-init.yml "\${jsonencode(key)}"
require_pattern main.tf 'extra_env[[:space:]]*=[[:space:]]*local\.runtime\.extra_env'
require_pattern providers/gcp/main.tf 'extra_env[[:space:]]*=[[:space:]]*local\.runtime\.extra_env'
require_line modules/gcp/variables.tf 'users names must be safe Linux usernames'
require_line modules/linux-vm-runtime/variables.tf 'ssh_users names must be safe Linux usernames'
# Match the literal expansion in the profile implementation.
# shellcheck disable=SC2016
require_line rootfs/home/cloud-compose/profile.sh 'load_runtime_env "${CLOUD_COMPOSE_ENV_FILE:-/home/cloud-compose/.env}"'
require_line rootfs/home/cloud-compose/profile.sh 'decode_runtime_env_value() {'
require_line rootfs/home/cloud-compose/lifecycle-entrypoint.sh 'exec sitectl host apps lifecycle "$lifecycle"'
require_line rootfs/home/cloud-compose/run.sh 'run_as_cloud_compose "$managed_sitectl" host apps lifecycle init'
require_line rootfs/home/cloud-compose/run.sh '"$sitectl" host configure'
require_line rootfs/etc/systemd/system/cloud-compose-mariadb-backup.service 'sitectl-host.sh backup mariadb'
require_line rootfs/etc/systemd/system/cloud-compose-rollout.service 'sitectl-host.sh rollout-serve'

if grep -Eq '},[[:space:]]*var\.extra_env\)' \
  "$repo_root/modules/gcp/main.tf" "$repo_root/modules/linux-vm-runtime/main.tf"; then
  echo "Application extra_env must not be merged into the host environment" >&2
  exit 1
fi

if grep -R -Fq 'EnvironmentFile=/home/cloud-compose/.env' "$repo_root/rootfs/etc/systemd/system"; then
  echo "Systemd units must use the non-executable runtime environment loader" >&2
  exit 1
fi

if grep -R -Eq '^set -[^[:space:]]*x|^set -o xtrace' "$repo_root/rootfs/home/cloud-compose"; then
  echo "Privileged runtime boot scripts must not enable unconditional xtrace" >&2
  exit 1
fi

BACKTICKS="\`touch $tmp/backtick-injection\`"
BACKSLASH='a\path\with\slashes'
COMMAND_SUB="\$(touch $tmp/command-injection)"
DOLLAR_VALUE="\$HOME \${HOME}"
DOUBLE_QUOTES='a "double-quoted" value'
MULTILINE=$'line one\nline two'
SINGLE_QUOTE="O'Reilly"
TRAILING_SLASH="ends\\"
WHITESPACE='  leading and trailing  '
name='literal-name-value'
env_file="$tmp/.env"
write_contract_env "$env_file"
assert_runtime_values "$env_file"
assert_compose_values "$env_file"

test ! -e "$tmp/backtick-injection"
test ! -e "$tmp/command-injection"

printf '%s\n' 'BAD-NAME="value"' >"$tmp/invalid.env"
# Source runs in the intentionally isolated child shell.
# shellcheck disable=SC2016
if env -i PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$tmp/invalid.env" \
  bash --noprofile --norc -c 'source "$1"' cloud-compose-env \
  "$repo_root/rootfs/home/cloud-compose/profile.sh" >/dev/null 2>&1; then
  echo "Runtime environment loader accepted an unsafe variable name" >&2
  exit 1
fi

for invalid_value in \
  "BAD=\"raw\$HOME\"" \
  'BAD="raw"quote"' \
  'BAD="unknown\qescape"' \
  'BAD="trailing\"'; do
  printf '%s\n' "$invalid_value" >"$tmp/invalid.env"
  # Source runs in the intentionally isolated child shell.
  # shellcheck disable=SC2016
  if env -i PATH=/usr/bin:/bin \
    CLOUD_COMPOSE_ENV_FILE="$tmp/invalid.env" \
    bash --noprofile --norc -c 'source "$1"' cloud-compose-env \
    "$repo_root/rootfs/home/cloud-compose/profile.sh" >/dev/null 2>&1; then
    echo "Runtime environment loader accepted data outside the encoding contract: $invalid_value" >&2
    exit 1
  fi
done

retry_log="$tmp/retry.log"
if env -i PATH=/usr/bin:/bin \
  CLOUD_COMPOSE_ENV_FILE="$env_file" MAX_RETRIES=1 \
  bash --noprofile --norc -c '
    source "$1"
    retry_until_success /bin/false "https://example.invalid/?token=must-not-appear"
  ' cloud-compose-retry "$repo_root/rootfs/home/cloud-compose/profile.sh" 2>"$retry_log"; then
  echo "Retry contract unexpectedly accepted a failing command" >&2
  exit 1
fi
if grep -Fq 'must-not-appear' "$retry_log"; then
  echo "Retry logging exposed command arguments" >&2
  exit 1
fi

for assignment in \
  'MAX_RETRIES=0' \
  'MAX_RETRIES=101' \
  'MAX_RETRIES=1+1' \
  'MAX_RETRIES=a[$(touch /tmp/cloud-compose-retry-injection)]' \
  'SLEEP_INCREMENT=-1' \
  'SLEEP_INCREMENT=3601' \
  'SLEEP_INCREMENT=1+1' \
  'SLEEP_INCREMENT=a[$(touch /tmp/cloud-compose-retry-injection)]'; do
  rm -f /tmp/cloud-compose-retry-injection
  if env -i PATH=/usr/bin:/bin \
    CLOUD_COMPOSE_ENV_FILE="$env_file" "$assignment" \
    bash --noprofile --norc -c '
      source "$1"
      retry_until_success /bin/true
    ' cloud-compose-retry "$repo_root/rootfs/home/cloud-compose/profile.sh" >/dev/null 2>&1; then
    echo "Retry contract accepted an unsafe bound: $assignment" >&2
    exit 1
  fi
  if [[ -e /tmp/cloud-compose-retry-injection ]]; then
    echo "Retry bound evaluation executed attacker-controlled arithmetic: $assignment" >&2
    exit 1
  fi
done
