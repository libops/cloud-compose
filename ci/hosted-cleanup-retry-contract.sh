#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-hosted-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "hosted cleanup retry contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/state"

cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_API_LOG"
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'curl' >>"$FAKE_API_LOG"
printf ' %q' "$@" >>"$FAKE_API_LOG"
printf '\n' >>"$FAKE_API_LOG"

method=""
url=""
connect_timeout=""
max_time=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -sS)
      shift
      ;;
    --connect-timeout)
      connect_timeout="${2:-}"
      shift 2
      ;;
    --max-time)
      max_time="${2:-}"
      shift 2
      ;;
    -X)
      method="${2:-}"
      shift 2
      ;;
    -H | -w)
      shift 2
      ;;
    https://*)
      url="$1"
      shift
      ;;
    *)
      echo "unexpected fake curl argument: $1" >&2
      exit 64
      ;;
  esac
done

[[ "$connect_timeout" == "10" ]] || {
  echo "cleanup request omitted the 10-second connect timeout" >&2
  exit 64
}
[[ "$max_time" == "45" ]] || {
  echo "cleanup request omitted the 45-second total timeout" >&2
  exit 64
}

state_count() {
  local key="$1"

  if [[ -f "$FAKE_API_STATE/$key.count" ]]; then
    cat "$FAKE_API_STATE/$key.count"
  else
    printf '0\n'
  fi
}

increment_count() {
  local key="$1" count

  count="$(state_count "$key")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAKE_API_STATE/$key.count"
  printf '%s\n' "$count"
}

respond() {
  local body="$1" code="$2"

  printf '%s\n%s\n' "$body" "$code"
}

mark_deleted() {
  printf '%s\n' "$url" >>"$FAKE_API_STATE/deleted.log"
}

resource_visible() {
  local delete_url="$1" primary_count

  case "$FAKE_API_MODE" in
    residual-persistent)
      return 0
      ;;
    residual-delayed)
      primary_count="$(state_count primary)"
      if [[ "$primary_count" -le 3 ]]; then
        return 0
      fi
      return 1
      ;;
  esac

  if [[ -f "$FAKE_API_STATE/deleted.log" ]] && grep -Fxq "$delete_url" "$FAKE_API_STATE/deleted.log"; then
    return 1
  fi
  return 0
}

normal_get_body() {
  local single=false

  if [[ "$FAKE_API_MODE" == delete-* ]]; then
    single=true
  fi

  case "$FAKE_API_DRIVER:$url" in
    app-linode:*api.linode.com*/networking/firewalls\?*)
      if resource_visible 'https://api.linode.com/v4/networking/firewalls/101'; then
        printf '%s' '{"data":[{"id":101,"tags":["cloud-compose-smoke","linode-wp","gha-run-123456789"]},{"id":901,"tags":["cloud-compose-smoke","linode-wp","gha-run-foreign"]},{"id":902,"tags":["cloud-compose-smoke","linode-isle","gha-run-123456789"]}]}'
      else
        printf '%s' '{"data":[{"id":901,"tags":["cloud-compose-smoke","linode-wp","gha-run-foreign"]},{"id":902,"tags":["cloud-compose-smoke","linode-isle","gha-run-123456789"]}]}'
      fi
      ;;
    app-linode:*api.linode.com*/linode/instances\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"data":[]}'
      elif resource_visible 'https://api.linode.com/v4/linode/instances/102'; then
        printf '%s' '{"data":[{"id":102,"tags":["cloud-compose-smoke","linode-wp","gha-run-123456789"]},{"id":903,"tags":["cloud-compose-smoke","linode-wp","gha-run-foreign"]}]}'
      else
        printf '%s' '{"data":[{"id":903,"tags":["cloud-compose-smoke","linode-wp","gha-run-foreign"]}]}'
      fi
      ;;
    app-linode:*api.linode.com*/volumes\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"data":[]}'
      elif resource_visible 'https://api.linode.com/v4/volumes/103'; then
        printf '%s' '{"data":[{"id":103,"tags":["cloud-compose-smoke","linode-wp","gha-run-123456789"]},{"id":904,"tags":["cloud-compose-smoke","linode-isle","gha-run-123456789"]}]}'
      else
        printf '%s' '{"data":[{"id":904,"tags":["cloud-compose-smoke","linode-isle","gha-run-123456789"]}]}'
      fi
      ;;
    config-management:*api.linode.com*/networking/firewalls\?*)
      if resource_visible 'https://api.linode.com/v4/networking/firewalls/201'; then
        printf '%s' '{"data":[{"id":201,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-123456789"]},{"id":911,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-foreign"]},{"id":912,"tags":["cloud-compose-smoke","config-management-smoke","config-management-salt-drupal","gha-run-123456789"]}]}'
      else
        printf '%s' '{"data":[{"id":911,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-foreign"]},{"id":912,"tags":["cloud-compose-smoke","config-management-smoke","config-management-salt-drupal","gha-run-123456789"]}]}'
      fi
      ;;
    config-management:*api.linode.com*/linode/instances\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"data":[]}'
      elif resource_visible 'https://api.linode.com/v4/linode/instances/202'; then
        printf '%s' '{"data":[{"id":202,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-123456789"]},{"id":913,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-foreign"]}]}'
      else
        printf '%s' '{"data":[{"id":913,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-foreign"]}]}'
      fi
      ;;
    config-management:*api.linode.com*/volumes\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"data":[]}'
      elif resource_visible 'https://api.linode.com/v4/volumes/203'; then
        printf '%s' '{"data":[{"id":203,"tags":["cloud-compose-smoke","config-management-smoke","config-management-ansible-drupal","gha-run-123456789"]},{"id":914,"tags":["cloud-compose-smoke","config-management-smoke","config-management-salt-drupal","gha-run-123456789"]}]}'
      else
        printf '%s' '{"data":[{"id":914,"tags":["cloud-compose-smoke","config-management-smoke","config-management-salt-drupal","gha-run-123456789"]}]}'
      fi
      ;;
    app-digitalocean:*api.digitalocean.com*/firewalls\?*)
      if resource_visible 'https://api.digitalocean.com/v2/firewalls/do-firewall'; then
        printf '%s' '{"firewalls":[{"id":"do-firewall","name":"cc-do-isle-123456789-abcdef-cloud-compose"},{"id":"foreign-firewall-run","name":"cc-do-isle-987654321-abcdef-cloud-compose"},{"id":"foreign-firewall-target","name":"cc-do-wp-123456789-abcdef-cloud-compose"}]}'
      else
        printf '%s' '{"firewalls":[{"id":"foreign-firewall-run","name":"cc-do-isle-987654321-abcdef-cloud-compose"},{"id":"foreign-firewall-target","name":"cc-do-wp-123456789-abcdef-cloud-compose"}]}'
      fi
      ;;
    app-digitalocean:*api.digitalocean.com*/droplets\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"droplets":[]}'
      elif resource_visible 'https://api.digitalocean.com/v2/droplets/301'; then
        printf '%s' '{"droplets":[{"id":301,"tags":["cloud-compose-smoke","digitalocean-isle","gha-run-123456789"]},{"id":931,"tags":["cloud-compose-smoke","digitalocean-isle","gha-run-foreign"]}]}'
      else
        printf '%s' '{"droplets":[{"id":931,"tags":["cloud-compose-smoke","digitalocean-isle","gha-run-foreign"]}]}'
      fi
      ;;
    app-digitalocean:*api.digitalocean.com*/volumes\?*)
      if [[ "$single" == "true" ]]; then
        printf '%s' '{"volumes":[]}'
      elif resource_visible 'https://api.digitalocean.com/v2/volumes/do-volume'; then
        printf '%s' '{"volumes":[{"id":"do-volume","tags":["cloud-compose-smoke","digitalocean-isle","gha-run-123456789"]},{"id":"foreign-volume","tags":["cloud-compose-smoke","digitalocean-wp","gha-run-123456789"]}]}'
      else
        printf '%s' '{"volumes":[{"id":"foreign-volume","tags":["cloud-compose-smoke","digitalocean-wp","gha-run-123456789"]}]}'
      fi
      ;;
    *)
      echo "unexpected fake API URL for $FAKE_API_DRIVER: $url" >&2
      exit 64
      ;;
  esac
}

if [[ "$method" == "DELETE" ]]; then
  printf '%s\n' "$url" >>"$FAKE_API_STATE/deletes.log"
  count="$(increment_count delete)"
  case "$FAKE_API_MODE:$count" in
    delete-transient:1)
      exit 7
      ;;
    delete-transient:2)
      respond '{"error":"request timeout"}' 408
      ;;
    delete-transient:3)
      respond '{"error":"too early"}' 425
      ;;
    delete-transient:4)
      respond '{"error":"rate limited"}' 429
      ;;
    delete-transient:5)
      respond '{"error":"server error"}' 500
      ;;
    delete-transient:6)
      mark_deleted
      respond '' 204
      ;;
    delete-persistent:*)
      respond '{"error":"unavailable"}' 503
      ;;
    delete-auth:*)
      respond '{"error":"unauthorized"}' 401
      ;;
    delete-forbidden:*)
      respond '{"error":"forbidden"}' 403
      ;;
    delete-permanent:*)
      respond '{"error":"bad request"}' 400
      ;;
    delete-conflict:1)
      respond '{"error":"conflict"}' 409
      ;;
    delete-conflict:2)
      respond '{"error":"locked"}' 423
      ;;
    delete-conflict:3)
      mark_deleted
      respond '' 204
      ;;
    delete-absent-404:*)
      mark_deleted
      respond '{"error":"not found"}' 404
      ;;
    delete-absent-410:*)
      mark_deleted
      respond '{"error":"gone"}' 410
      ;;
    *)
      mark_deleted
      respond '' 204
      ;;
  esac
  exit 0
fi

[[ "$method" == "GET" ]] || {
  echo "unexpected fake curl method: $method" >&2
  exit 64
}

case "$url" in
  *api.linode.com*/networking/firewalls\?* | *api.digitalocean.com*/firewalls\?*) primary=true ;;
  *) primary=false ;;
esac

if [[ "$primary" == "true" ]]; then
  count="$(increment_count primary)"
  case "$FAKE_API_MODE:$count" in
    get-transient:1)
      exit 7
      ;;
    get-transient:2)
      respond '{"error":"request timeout"}' 408
      exit 0
      ;;
    get-transient:3)
      respond '{"error":"too early"}' 425
      exit 0
      ;;
    get-transient:4)
      respond '{"error":"rate limited"}' 429
      exit 0
      ;;
    get-transient:5)
      respond '{"error":"server error"}' 500
      exit 0
      ;;
    get-persistent:*)
      respond '{"error":"unavailable"}' 503
      exit 0
      ;;
    get-unauthorized:*)
      respond '{"error":"unauthorized"}' 401
      exit 0
      ;;
    get-forbidden:*)
      respond '{"error":"forbidden"}' 403
      exit 0
      ;;
    get-client-error:*)
      respond '{"error":"bad request"}' 400
      exit 0
      ;;
    get-not-found:*)
      respond '{"error":"not found"}' 404
      exit 0
      ;;
    get-gone:*)
      respond '{"error":"gone"}' 410
      exit 0
      ;;
    get-conflict:*)
      respond '{"error":"conflict"}' 409
      exit 0
      ;;
    get-locked:*)
      respond '{"error":"locked"}' 423
      exit 0
      ;;
  esac
fi

if [[ "$FAKE_API_MODE" == "malformed" ]]; then
  respond '{}' 200
else
  respond "$(normal_get_body)" 200
fi
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'terraform' >>"$FAKE_TERRAFORM_LOG"
printf ' %q' "$@" >>"$FAKE_TERRAFORM_LOG"
printf '\n' >>"$FAKE_TERRAFORM_LOG"

command_name=""
for argument in "$@"; do
  case "$argument" in
    init | validate | apply | output | destroy)
      command_name="$argument"
      break
      ;;
  esac
done

case "$command_name" in
  init | validate)
    exit 0
    ;;
  apply)
    if [[ -n "${FAKE_BODY_SIGNAL:-}" ]]; then
      kill -s "$FAKE_BODY_SIGNAL" "$PPID"
      exit 0
    fi
    exit "${FAKE_BODY_STATUS:-0}"
    ;;
  output)
    case "$FAKE_API_DRIVER" in
      app-linode)
        printf '%s\n' '{"host":"127.0.0.1","ssh_port":22,"ssh_user":"tester","project_dir":"/home/cloud-compose/app","context_name":"smoke","plugin":"wordpress","environment":"test","site":"smoke","project_name":"smoke","compose_project_name":"smoke","provider":"linode"}'
        ;;
      config-management)
        printf '%s\n' '{"host":"127.0.0.1","method":"ansible","cloud_compose_name":"smoke","app":"drupal","environment":"test","project_dir":"/home/cloud-compose/app"}'
        ;;
      *)
        echo "unexpected terraform output driver: $FAKE_API_DRIVER" >&2
        exit 64
        ;;
    esac
    ;;
  destroy)
    if [[ "${FAKE_DESTROY_MODE:-success}" == "failure" ]]; then
      exit 42
    fi
    ;;
  *)
    echo "unexpected fake terraform invocation: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$tmp/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

path=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-f" ]]; then
    path="${2:-}"
    break
  fi
  shift
done
[[ -n "$path" ]] || exit 64
printf '%s\n' 'fake-private-key' >"$path"
printf '%s\n' 'ssh-ed25519 fake-public-key cloud-compose-smoke' >"${path}.pub"
EOF

cat >"$tmp/bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '127.0.0.1 ssh-ed25519 fake-host-key'
EOF

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *cloud-compose-bootstrap-complete*) printf 'complete\n' ;;
  *cloud-init\ status*) printf 'cloud-init not installed\n' ;;
esac
EOF

cat >"$tmp/bin/sitectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
EOF

cat >"$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake archive'
EOF

chmod +x "$tmp/bin/"*

driver_command() {
  local driver="$1" operation="$2"

  case "$operation:$driver" in
    sweep:app-linode) printf '%s\0%s\0%s\0' bash "$repo_root/ci/cloud-smoke.sh" sweep-linode-wp ;;
    sweep:app-digitalocean) printf '%s\0%s\0%s\0' bash "$repo_root/ci/cloud-smoke.sh" sweep-digitalocean-isle ;;
    sweep:config-management) printf '%s\0%s\0%s\0' bash "$repo_root/ci/config-management-cloud-smoke.sh" sweep-ansible-drupal ;;
    flow:app-linode) printf '%s\0%s\0%s\0' bash "$repo_root/ci/cloud-smoke.sh" linode-wp ;;
    flow:config-management) printf '%s\0%s\0%s\0' bash "$repo_root/ci/config-management-cloud-smoke.sh" ansible-drupal ;;
    destroy:app-linode) printf '%s\0%s\0%s\0' bash "$repo_root/ci/cloud-smoke.sh" destroy-linode-wp ;;
    destroy:config-management) printf '%s\0%s\0%s\0' bash "$repo_root/ci/config-management-cloud-smoke.sh" destroy-ansible-drupal ;;
    *) fail "unknown driver operation ${operation}:${driver}" ;;
  esac
}

run_case() {
  local operation="$1" driver="$2" mode="$3"
  local destroy_mode="${4:-success}" body_signal="${5:-}" body_status="${6:-0}"
  local output state status
  local -a command

  state="$tmp/state/${operation}-${driver}-${mode}-${destroy_mode}-${body_signal:-none}-${body_status}"
  mkdir -p "$state"
  case "$operation:$driver" in
    destroy:app-linode) mkdir -p "$state/work/linode-wp/.terraform" ;;
    destroy:config-management) mkdir -p "$state/work/config-management-linode-ansible-drupal/.terraform" ;;
  esac
  output="$state/output.log"
  mapfile -d '' -t command < <(driver_command "$driver" "$operation")

  if PATH="$tmp/bin:$PATH" \
    CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true \
    CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=10 \
    CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=10 \
    CLOUD_COMPOSE_SMOKE_RUN_ID=123456789 \
    CLOUD_COMPOSE_SMOKE_WORKDIR="$state/work" \
    DIGITALOCEAN_TOKEN=test-token \
    FAKE_API_DRIVER="$driver" \
    FAKE_API_LOG="$state/api.log" \
    FAKE_API_MODE="$mode" \
    FAKE_API_STATE="$state" \
    FAKE_BODY_SIGNAL="$body_signal" \
    FAKE_BODY_STATUS="$body_status" \
    FAKE_DESTROY_MODE="$destroy_mode" \
    FAKE_TERRAFORM_LOG="$state/terraform.log" \
    GITHUB_ACTIONS=true \
    LINODE_TOKEN=test-token \
    "${command[@]}" >"$output" 2>&1; then
    status=0
  else
    status=$?
  fi
  printf '%s\n' "$status" >"$state/status"
  printf '%s\n' "$state"
}

assert_status() {
  local state="$1" want="$2" got

  got="$(<"$state/status")"
  if [[ "$want" == "success" && "$got" -ne 0 ]]; then
    cat "$state/output.log" >&2
    fail "$(basename "$state") failed with status $got"
  fi
  if [[ "$want" == "failure" && "$got" -eq 0 ]]; then
    cat "$state/output.log" >&2
    fail "$(basename "$state") unexpectedly succeeded"
  fi
  if [[ "$want" =~ ^[0-9]+$ && "$got" -ne "$want" ]]; then
    cat "$state/output.log" >&2
    fail "$(basename "$state") returned $got, want $want"
  fi
}

count_file() {
  local state="$1" key="$2"

  if [[ -f "$state/$key.count" ]]; then
    cat "$state/$key.count"
  else
    printf '0\n'
  fi
}

owned_delete_urls() {
  case "$1" in
    app-linode)
      printf '%s\n' \
        'https://api.linode.com/v4/networking/firewalls/101' \
        'https://api.linode.com/v4/linode/instances/102' \
        'https://api.linode.com/v4/volumes/103'
      ;;
    config-management)
      printf '%s\n' \
        'https://api.linode.com/v4/networking/firewalls/201' \
        'https://api.linode.com/v4/linode/instances/202' \
        'https://api.linode.com/v4/volumes/203'
      ;;
    app-digitalocean)
      printf '%s\n' \
        'https://api.digitalocean.com/v2/firewalls/do-firewall' \
        'https://api.digitalocean.com/v2/droplets/301' \
        'https://api.digitalocean.com/v2/volumes/do-volume'
      ;;
  esac
}

assert_owned_only() {
  local state="$1" driver="$2"
  local actual expected

  expected="$(owned_delete_urls "$driver")"
  if [[ -f "$state/deletes.log" ]]; then
    actual="$(<"$state/deletes.log")"
  else
    actual=""
  fi
  [[ "$actual" == "$expected" ]] || {
    printf 'expected deletes:\n%s\nactual deletes:\n%s\n' "$expected" "$actual" >&2
    fail "$driver did not delete exactly its run-owned resources"
  }
  if grep -Eq 'foreign|/9[0-9][0-9]$' "$state/deletes.log"; then
    fail "$driver selected a foreign resource"
  fi
}

assert_all_linode_queries() {
  local state="$1"

  for path in networking/firewalls linode/instances volumes; do
    grep -Fq "$path" "$state/api.log" || fail "$(basename "$state") skipped the $path cleanup pipeline"
  done
}

sleep_count() {
  local state="$1" seconds="$2" count

  count="$(grep -c "^sleep ${seconds}$" "$state/api.log" 2>/dev/null || true)"
  printf '%s\n' "$count"
}

for driver in app-linode config-management; do
  state="$(run_case sweep "$driver" get-transient)"
  assert_status "$state" success
  [[ "$(count_file "$state" primary)" == "7" ]] || fail "$driver did not recover on GET attempt six and verify cleanup"
  assert_owned_only "$state" "$driver"
  mapfile -t delays < <(awk '$1 == "sleep" {print $2}' "$state/api.log" | sed -n '1,5p')
  [[ "${delays[*]}" == "2 4 8 16 30" ]] || fail "$driver used unexpected GET backoff: ${delays[*]}"

  state="$(run_case sweep "$driver" get-persistent)"
  assert_status "$state" failure
  [[ "$(count_file "$state" primary)" == "6" ]] || fail "$driver did not stop after six GET attempts"

  for mode in get-unauthorized get-forbidden get-client-error get-not-found get-gone get-conflict get-locked; do
    state="$(run_case sweep "$driver" "$mode")"
    assert_status "$state" failure
    [[ "$(count_file "$state" primary)" == "1" ]] || fail "$driver retried fail-fast GET mode $mode"
  done

  state="$(run_case sweep "$driver" malformed)"
  assert_status "$state" failure
  assert_all_linode_queries "$state"
  [[ "$(count_file "$state" delete)" == "0" ]] || fail "$driver deleted resources from malformed API data"
done

state="$(run_case sweep app-digitalocean get-transient)"
assert_status "$state" success
assert_owned_only "$state" app-digitalocean
state="$(run_case sweep app-digitalocean malformed)"
assert_status "$state" failure

for driver in app-linode config-management app-digitalocean; do
  state="$(run_case sweep "$driver" residual-delayed)"
  assert_status "$state" success
  assert_owned_only "$state" "$driver"
  [[ "$(count_file "$state" primary)" == "4" ]] || fail "$driver did not wait for delayed residual visibility to clear"
  [[ "$(sleep_count "$state" 10)" == "3" ]] || fail "$driver used unexpected delayed-residual backoff"

  state="$(run_case sweep "$driver" residual-persistent)"
  assert_status "$state" failure
  assert_owned_only "$state" "$driver"
  [[ "$(count_file "$state" primary)" == "7" ]] || fail "$driver did not bound persistent residual verification at six attempts"
  [[ "$(sleep_count "$state" 10)" == "6" ]] || fail "$driver used unexpected persistent-residual backoff"
done

for driver in app-linode config-management; do
  while read -r mode want_status want_attempts retry_sleeps; do
    state="$(run_case sweep "$driver" "$mode")"
    assert_status "$state" "$want_status"
    [[ "$(count_file "$state" delete)" == "$want_attempts" ]] || \
      fail "$driver $mode used $(count_file "$state" delete) DELETE attempts, want $want_attempts"
    # Each Linode sweep has one dependency-order pause between instances and volumes.
    [[ "$(sleep_count "$state" 10)" == "$((retry_sleeps + 1))" ]] || \
      fail "$driver $mode used $(sleep_count "$state" 10) ten-second sleeps, want $((retry_sleeps + 1))"
    assert_all_linode_queries "$state"
  done <<'EOF'
delete-transient success 6 5
delete-persistent failure 12 11
delete-auth failure 1 0
delete-forbidden failure 1 0
delete-permanent failure 1 0
delete-conflict success 3 2
delete-absent-404 success 1 0
delete-absent-410 success 1 0
EOF
done

for driver in app-linode config-management; do
  state="$(run_case flow "$driver" owned failure)"
  assert_status "$state" success
  assert_owned_only "$state" "$driver"
  grep -Fq ' destroy ' "$state/terraform.log" || fail "$driver EXIT cleanup did not run Terraform destroy"

  state="$(run_case flow "$driver" delete-persistent failure)"
  assert_status "$state" 42
  [[ "$(count_file "$state" delete)" == "12" ]] || fail "$driver EXIT fallback did not exhaust DELETE retries"

  state="$(run_case flow "$driver" delete-persistent failure '' 37)"
  assert_status "$state" 37

  while read -r signal want_status; do
    state="$(run_case flow "$driver" owned success "$signal")"
    assert_status "$state" "$want_status"
    grep -Fq ' destroy ' "$state/terraform.log" || fail "$driver $signal path skipped EXIT destroy"
  done <<'EOF'
HUP 129
INT 130
TERM 143
EOF
done

for driver in app-linode config-management; do
  state="$(run_case destroy "$driver" owned failure)"
  assert_status "$state" success
  assert_owned_only "$state" "$driver"

  state="$(run_case destroy "$driver" residual-persistent failure)"
  assert_status "$state" 42
done

echo "Hosted cleanup retry contracts passed"
