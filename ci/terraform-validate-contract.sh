#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-terraform-validate-contract.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "terraform validate contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"

cat >"$tmp/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

operation=""
for argument in "$@"; do
  case "$argument" in
    init | validate | test)
      operation="$argument"
      break
      ;;
  esac
done

[[ -n "$operation" ]] || {
  echo "fake terraform received no recognized operation" >&2
  exit 64
}

printf '%s\n' "$operation" >>"${FAKE_TERRAFORM_LOG:?}"

if [[ "$operation" == "init" ]]; then
  exit 23
fi
EOF

cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_SLEEP_LOG:?}"
EOF

chmod +x "$tmp/bin/terraform" "$tmp/bin/sleep"

status=0
PATH="$tmp/bin:$PATH" \
  FAKE_SLEEP_LOG="$tmp/sleep.log" \
  FAKE_TERRAFORM_LOG="$tmp/terraform.log" \
  TF_VALIDATE_DATA_ROOT="$tmp/terraform-data" \
  bash "$repo_root/ci/terraform-validate.sh" >"$tmp/output.log" 2>&1 || status=$?

[[ "$status" -eq 23 ]] || fail "expected failed terraform init status 23, got $status"
[[ "$(<"$tmp/terraform.log")" == $'init\ninit\ninit' ]] || fail "expected exactly three init attempts and no validate or test calls"
[[ "$(<"$tmp/sleep.log")" == $'10\n20' ]] || fail "expected two retry delays before the final init failure"

echo "terraform validate contract passed"
