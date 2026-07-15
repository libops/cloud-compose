#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-hosted-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "hosted cleanup lifecycle contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/work"

cat >"$tmp/bin/cloud-compose-ci" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${1:-}" >>"$FAKE_RUNNER_LOG"
shift || true
printf ' %s' "$@" >>"$FAKE_RUNNER_LOG"
printf '\n' >>"$FAKE_RUNNER_LOG"
exit "${FAKE_RUNNER_STATUS:-0}"
EOF

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform %s\n' "$*" >>"$FAKE_TERRAFORM_LOG"
exit "${FAKE_TERRAFORM_STATUS:-0}"
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
printf 'fake-private-key\n' >"$path"
printf 'ssh-ed25519 fake-public-key cloud-compose-smoke\n' >"${path}.pub"
EOF

# Any curl execution is a contract failure: provider HTTP behavior belongs to
# the Go httptest suite, and these wrappers must invoke only the fake runner.
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "unexpected network client invocation: curl $*" >&2
exit 97
EOF

chmod +x "$tmp/bin/"*

run_wrapper() {
  local name="$1" driver="$2" operation="$3"
  local terraform_status="${4:-0}" runner_status="${5:-0}"
  local state="$tmp/work/$name"

  mkdir -p "$state"
  : >"$state/runner.log"
  : >"$state/terraform.log"
  if PATH="$tmp/bin:$PATH" \
    CLOUD_COMPOSE_CI_BIN="$tmp/bin/cloud-compose-ci" \
    CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true \
    CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=10 \
    CLOUD_COMPOSE_SMOKE_RUN_ID=123456789 \
    CLOUD_COMPOSE_SMOKE_WORKDIR="$state/smoke" \
    CLOUD_COMPOSE_SOURCE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
    DIGITALOCEAN_TOKEN=do-wrapper-secret \
    FAKE_RUNNER_LOG="$state/runner.log" \
    FAKE_RUNNER_STATUS="$runner_status" \
    FAKE_TERRAFORM_LOG="$state/terraform.log" \
    FAKE_TERRAFORM_STATUS="$terraform_status" \
    GITHUB_ACTIONS=true \
    LINODE_TOKEN=linode-wrapper-secret \
    bash "$repo_root/$driver" "$operation" >"$state/output.log" 2>&1; then
    printf '0\n' >"$state/status"
  else
    printf '%s\n' "$?" >"$state/status"
  fi
  printf '%s\n' "$state"
}

assert_status() {
  local state="$1" want="$2" got

  got="$(<"$state/status")"
  if [[ "$got" -ne "$want" ]]; then
    cat "$state/output.log" >&2
    fail "$(basename "$state") returned $got, want $want"
  fi
}

assert_runner_call() {
  local state="$1" want="$2" got

  got="$(<"$state/runner.log")"
  [[ "$got" == "$want" ]] || {
    printf 'runner call:\n%s\nwant:\n%s\n' "$got" "$want" >&2
    fail "$(basename "$state") did not preserve the compiled-runner boundary"
  }
  if grep -Fq 'wrapper-secret' "$state/runner.log"; then
    fail "$(basename "$state") passed a provider token as a process argument"
  fi
}

state="$(run_wrapper sweep-linode ci/cloud-smoke.sh sweep-linode-wp)"
assert_status "$state" 0
assert_runner_call "$state" 'linode sweep --scope application --target linode-wp --run-id 123456789'

state="$(run_wrapper sweep-digitalocean ci/cloud-smoke.sh sweep-digitalocean-isle)"
assert_status "$state" 0
assert_runner_call "$state" 'digitalocean sweep --scope application --target digitalocean-isle --run-id 123456789'

state="$(run_wrapper sweep-config-management ci/config-management-cloud-smoke.sh sweep-ansible-drupal)"
assert_status "$state" 0
assert_runner_call "$state" 'linode sweep --scope config-management --target ansible-drupal --run-id 123456789'

mkdir -p "$tmp/work/destroy-linode/smoke/linode-wp/.terraform"
state="$(run_wrapper destroy-linode ci/cloud-smoke.sh destroy-linode-wp 42 0)"
assert_status "$state" 0
assert_runner_call "$state" 'linode sweep --scope application --target linode-wp --run-id 123456789'
grep -Fq ' destroy ' "$state/terraform.log" || fail "destroy-linode skipped Terraform destroy"

mkdir -p "$tmp/work/destroy-config/smoke/config-management-linode-ansible-drupal/.terraform"
state="$(run_wrapper destroy-config ci/config-management-cloud-smoke.sh destroy-ansible-drupal 0 43)"
assert_status "$state" 43
assert_runner_call "$state" 'linode sweep --scope config-management --target ansible-drupal --run-id 123456789'
grep -Fq ' destroy ' "$state/terraform.log" || fail "destroy-config skipped Terraform destroy"

echo "Hosted cleanup lifecycle contracts passed"
