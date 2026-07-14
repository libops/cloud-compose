#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_script="$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "managed artifact contract: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/downloads" "$tmp/target" "$tmp/state/tmp" "$tmp/state/artifacts"
: >"$tmp/profile.sh"
curl_log="$tmp/curl.log"
systemctl_log="$tmp/systemctl.log"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($# > 0)); do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'curl\n' >>"${CURL_LOG:?}"
cp -- "${ARTIFACT_PAYLOAD:?}" "$output"
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
[[ "${SYSTEMCTL_FAIL:-false}" != "true" ]]
EOF
chmod +x "$tmp/bin/"*

payload="$tmp/downloads/tool"
printf 'new-artifact\n' >"$payload"
sha="$(sha256sum "$payload")"
sha="${sha%% *}"
manifest="$tmp/manifest.tsv"
target="$tmp/target/tool"
artifact_owner="$(id -un)"
artifact_group="$(id -gn)"
printf 'tool\thttps://example.invalid/tool\t%s\t%s\t0755\t%s\t%s\tcloud-compose.service\n' \
    "$sha" "$target" "$artifact_owner" "$artifact_group" >"$manifest"

run_install() {
    CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    TEST_STATE="$tmp/state" \
    TEST_MANIFEST="$manifest" \
    ARTIFACT_PAYLOAD="$payload" \
    CURL_LOG="$curl_log" \
    SYSTEMCTL_LOG="$systemctl_log" \
    PATH="$tmp/bin:/usr/bin:/bin" \
        bash --noprofile --norc -c '
            set -euo pipefail
            source "$1"
            STATE_DIR="$TEST_STATE"
            TMP_DIR="$STATE_DIR/tmp"
            ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
            ARTIFACT_MANIFEST="$TEST_MANIFEST"
            retry_until_success() { "$@"; }
            install_managed_artifacts
        ' managed-artifact "$runtime_script"
}

run_install
cmp -s "$payload" "$target" || fail "verified artifact was not installed"
[[ "$(<"$tmp/state/artifacts/tool.sha256")" == "$sha" ]] || fail "successful artifact state was not recorded"
grep -Fxq 'try-restart -- cloud-compose.service' "$systemctl_log" || fail "artifact service was not restarted"

# A complete matching spec is the only fast path. Checksum state cannot mask
# mode, owner, or group drift.
: >"$curl_log"
run_install
[[ ! -s "$curl_log" ]] || fail "fully matching artifact spec was downloaded again"
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" bash --noprofile --norc -c '
  source "$1"
  managed_artifact_metadata_matches "$2" 0755 "$3" "$4"
  ! managed_artifact_metadata_matches "$2" 0755 wrong-owner "$4"
  ! managed_artifact_metadata_matches "$2" 0755 "$3" wrong-group
' managed-artifact-metadata "$runtime_script" "$target" "$artifact_owner" "$artifact_group" || \
  fail "owner/group metadata does not participate in the installed-spec gate"
chmod 0644 "$target"
: >"$curl_log"
run_install
[[ "$(stat -c %a "$target")" == "755" ]] || fail "artifact mode drift was not reconciled"
[[ "$(wc -l <"$curl_log")" == 1 ]] || fail "mode drift did not leave the checksum fast path"

# State alone is not trusted: a modified target must be re-downloaded and healed.
printf 'tampered\n' >"$target"
: >"$curl_log"
run_install
cmp -s "$payload" "$target" || fail "tampered artifact target was trusted from stale state"
[[ "$(wc -l <"$curl_log")" == 1 ]] || fail "tampered target was not downloaded exactly once"

# Restart failure restores the exact prior target and records failure instead
# of claiming that the new artifact is installed.
printf 'prior-artifact\n' >"$target"
rm -f "$tmp/state/artifacts/tool.sha256"
prior_sha="$(sha256sum "$target")"
if SYSTEMCTL_FAIL=true run_install >/dev/null 2>&1; then
    fail "artifact update accepted a failed service restart"
fi
[[ "$(sha256sum "$target")" == "$prior_sha" ]] || fail "restart failure did not restore the previous target"
[[ ! -e "$tmp/state/artifacts/tool.sha256" ]] || fail "restart failure recorded successful artifact state"
[[ -s "$tmp/state/artifacts/tool.failed" ]] || fail "restart failure did not record an audit state"

SYSTEMCTL_FAIL=false run_install
cmp -s "$payload" "$target" || fail "artifact did not recover after restart failure"
[[ ! -e "$tmp/state/artifacts/tool.failed" ]] || fail "successful recovery retained stale failure state"

# Invalid rows fail before any download or target mutation.
assert_rejected() {
    local row="$1"
    printf '%s\n' "$row" >"$manifest"
    : >"$curl_log"
    if run_install >/dev/null 2>&1; then
        fail "invalid manifest row was accepted: $row"
    fi
    [[ ! -s "$curl_log" ]] || fail "invalid manifest row reached the network: $row"
}

assert_rejected $'../escape\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\t0\t0\t'
assert_rejected $'tool\thttp://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\t0\t0\t'
assert_rejected $'tool\thttps://example.invalid/tool\tnot-a-sha\t'"$target"$'\t0755\t0\t0\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t../escape\t0755\t0\t0\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t/tmp//tool\t0755\troot\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t/tmp/tool/\t0755\troot\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t/tmp/control\x7ftool\t0755\troot\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t4755\troot\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\t0\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\tRoot\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot.user\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot;id\troot\t'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot\troot\t-unit.service'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot\troot\tunit;id.service'
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot\troot'
long_name="$(printf 'a%.0s' {1..129})"
assert_rejected "$long_name"$'\thttps://example.invalid/tool\t'"$sha"$'\t'"$target"$'\t0755\troot\troot\t'

# A later invalid row and duplicate names/paths are rejected by the complete
# preflight before the first valid row can download or mutate its target.
preflight_target="$tmp/target/preflight"
valid_preflight=$'first\thttps://example.invalid/first\t'"$sha"$'\t'"$preflight_target"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
assert_manifest_preflight_rejected() {
    local second_row="$1"

    printf '%s\n%s\n' "$valid_preflight" "$second_row" >"$manifest"
    rm -f -- "$preflight_target"
    : >"$curl_log"
    if run_install >/dev/null 2>&1; then
        fail "invalid multi-row manifest was accepted"
    fi
    [[ ! -s "$curl_log" ]] || fail "invalid later row allowed an earlier download"
    [[ ! -e "$preflight_target" ]] || fail "invalid later row allowed an earlier target mutation"
}

assert_manifest_preflight_rejected $'bad\thttp://example.invalid/bad\t'"$sha"$'\t'"$tmp/target/bad"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
assert_manifest_preflight_rejected $'first\thttps://example.invalid/two\t'"$sha"$'\t'"$tmp/target/two"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
assert_manifest_preflight_rejected $'second\thttps://example.invalid/two\t'"$sha"$'\t'"$preflight_target"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
assert_manifest_preflight_rejected $'second\thttps://example.invalid/two\t'"$sha"$'\t'"$tmp/missing/second"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
assert_manifest_preflight_rejected $'second\thttps://example.invalid/two\t'"$sha"$'\t'"$tmp/target/second"$'\t0755\tnonexistent-cloud-compose-owner\t'"$artifact_group"$'\t'

# A root-run updater must not follow a symlinked or attacker-writable target
# directory chain, even when the final artifact path is lexically normalized.
ln -s -- "$tmp/target" "$tmp/target-link"
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$tmp/target-link/tool"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'
mkdir -m 0777 "$tmp/writable-target"
assert_rejected $'tool\thttps://example.invalid/tool\t'"$sha"$'\t'"$tmp/writable-target/tool"$'\t0755\t'"$artifact_owner"$'\t'"$artifact_group"$'\t'

CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" bash --noprofile --norc -c '
  source "$1"
  validate_managed_artifact valid https://example.invalid/a "$2" /tmp/a 0755 root root "cloud-compose@tenant:worker.service"
' managed-artifact-colon "$runtime_script" "$sha" || fail "runtime rejected the centrally allowed colon restart unit"

echo "Managed artifact contract passed"
