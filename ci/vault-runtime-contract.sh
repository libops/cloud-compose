#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readiness_script="$repo_root/rootfs/home/cloud-compose/vault-agent-readiness.sh"
assert_script="$repo_root/rootfs/home/cloud-compose/assert-vault-ready.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "Vault runtime contract: $*" >&2
    exit 1
}

mkdir -p "$tmp/data" "$tmp/run" "$tmp/bin"
chmod 0775 "$tmp/data"
: >"$tmp/profile.sh"

run_readiness() {
    local action="$1" token_path="$2"

    CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    TEST_SAFE_DIR="$tmp/data/vault" \
    TEST_READY_MARKER="$tmp/run/vault.ready" \
    VAULT_AGENT_TOKEN_PATH="$token_path" \
    READINESS_SCRIPT="$readiness_script" \
        bash --noprofile --norc -c '
            set -euo pipefail
            source "$READINESS_SCRIPT"
            vault_safe_dir() { printf "%s\n" "$TEST_SAFE_DIR"; }
            READY_MARKER="$TEST_READY_MARKER"
            install() {
                local args=()
                while (($# > 0)); do
                    case "$1" in
                        -o | -g) shift 2 ;;
                        *) args+=("$1"); shift ;;
                    esac
                done
                command install "${args[@]}"
            }
            main "$1"
        ' vault-readiness "$action"
}

safe_token="$tmp/data/vault/token"
run_readiness prepare "$safe_token"
[[ -d "$tmp/data/vault" ]] || fail "dedicated Vault directory was not created"
[[ "$(stat -c %a "$tmp/data")" == "775" ]] || fail "Vault preparation chmodded a broad parent"
[[ "$(stat -c %a "$tmp/data/vault")" == "700" ]] || fail "dedicated Vault directory is not private"

printf 'vault-token\n' >"$safe_token"
VAULT_AGENT_START_TIMEOUT_SECONDS=1 run_readiness wait "$safe_token"
[[ -f "$tmp/run/vault.ready" ]] || fail "Vault readiness marker was not published"
run_readiness prepare "$safe_token"
[[ ! -e "$safe_token" ]] || fail "Vault restart preparation retained a stale token"
[[ ! -e "$tmp/run/vault.ready" ]] || fail "Vault restart preparation retained stale readiness"
if VAULT_AGENT_START_TIMEOUT_SECONDS=1 run_readiness wait "$safe_token" >/dev/null 2>&1; then
    fail "Vault restart published readiness without a fresh token"
fi
printf 'fresh-vault-token\n' >"$safe_token"
VAULT_AGENT_START_TIMEOUT_SECONDS=1 run_readiness wait "$safe_token"
run_readiness clear "$safe_token"
[[ ! -e "$tmp/run/vault.ready" ]] || fail "Vault readiness marker was not cleared"

for unsafe_token in \
    "$tmp/data/token" \
    "$tmp/data/vault/nested/token" \
    "$tmp/data/vault/../token" \
    "$tmp/data/vault/token/name"; do
    if run_readiness prepare "$unsafe_token" >/dev/null 2>&1; then
        fail "unsafe Vault token path was accepted: $unsafe_token"
    fi
done

rm -rf "$tmp/data/vault"
ln -s "$tmp/run" "$tmp/data/vault"
if run_readiness prepare "$safe_token" >/dev/null 2>&1; then
    fail "symbolic-link Vault state directory was accepted"
fi
rm -f "$tmp/data/vault"
mkdir -m 0700 "$tmp/data/vault"

cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl\n' >>"${SYSTEMCTL_LOG:?}"
[[ "${FAKE_VAULT_ACTIVE:-true}" == "true" ]]
EOF
chmod +x "$tmp/bin/systemctl"
systemctl_log="$tmp/systemctl.log"
: >"$systemctl_log"

printf 'export VAULT_AGENT_ENABLED=false\n' >"$tmp/profile.sh"
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
VAULT_AGENT_READY_MARKER="$tmp/run/vault.ready" \
SYSTEMCTL_LOG="$systemctl_log" PATH="$tmp/bin:$PATH" \
    bash "$assert_script"
[[ ! -s "$systemctl_log" ]] || fail "disabled Vault readiness contacted systemd"

printf 'export VAULT_AGENT_ENABLED=invalid\n' >"$tmp/profile.sh"
if CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    VAULT_AGENT_READY_MARKER="$tmp/run/vault.ready" \
    SYSTEMCTL_LOG="$systemctl_log" PATH="$tmp/bin:$PATH" \
    bash "$assert_script" >/dev/null 2>&1; then
    fail "invalid explicit Vault enablement was treated as disabled"
fi

printf 'export VAULT_AGENT_ENABLED=true\n' >"$tmp/profile.sh"
if CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    VAULT_AGENT_READY_MARKER="$tmp/run/vault.ready" \
    SYSTEMCTL_LOG="$systemctl_log" PATH="$tmp/bin:$PATH" \
    bash "$assert_script" >/dev/null 2>&1; then
    fail "enabled Vault accepted a missing readiness marker"
fi
: >"$tmp/run/vault.ready"
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
VAULT_AGENT_READY_MARKER="$tmp/run/vault.ready" \
SYSTEMCTL_LOG="$systemctl_log" PATH="$tmp/bin:$PATH" \
    bash "$assert_script"
if CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    VAULT_AGENT_READY_MARKER="$tmp/run/vault.ready" \
    SYSTEMCTL_LOG="$systemctl_log" FAKE_VAULT_ACTIVE=false PATH="$tmp/bin:$PATH" \
    bash "$assert_script" >/dev/null 2>&1; then
    fail "enabled Vault accepted an inactive agent service"
fi

vault_init="$repo_root/rootfs/home/cloud-compose/vault-agent-init.sh"
grep -Fq 'Vault Agent is enabled but its config is missing or unsafe' "$vault_init" || \
    fail "enabled Vault does not fail closed on a missing config"
grep -Fq 'Vault Agent is enabled but the Vault binary is not installed' "$vault_init" || \
    fail "enabled Vault does not fail closed on a missing binary"
if grep -Fq 'vault-agent-init.sh || true' "$repo_root/rootfs/home/cloud-compose/run.sh"; then
    fail "bootstrap still masks explicit Vault initialization failure"
fi
vault_line="$(grep -nF 'bash /home/cloud-compose/vault-agent-init.sh' "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
source_line="$(grep -nF 'run_as_cloud_compose bash /home/cloud-compose/prepare-app-sources.sh' "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
rotation_line="$(grep -nF 'bash /home/cloud-compose/rotate-keys-daily.sh' "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
init_line="$(grep -nF 'run_as_cloud_compose bash /home/cloud-compose/app-init.sh' "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
app_line="$(grep -nF 'cloud_compose_start_and_wait_for_oneshot cloud-compose.service' "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
[[ -n "$source_line" && -n "$rotation_line" && -n "$vault_line" && -n "$init_line" && -n "$app_line" ]] || \
    fail "bootstrap is missing a source, rotation, Vault, init, or app-service phase"
(( source_line < rotation_line && rotation_line < vault_line && vault_line < init_line && init_line < app_line )) || \
    fail "bootstrap must order source preparation -> rotation -> Vault readiness -> app lifecycle -> app service"
if rg -n 'run_compose_app_lifecycle|scaffold_compose_app_defaults|configure_sitectl_app_features' \
    "$repo_root/rootfs/home/cloud-compose/prepare-app-sources.sh" >/dev/null; then
    fail "source preparation executes application lifecycle work before Vault readiness"
fi
if grep -Fq 'clone_or_update_compose_app' "$repo_root/rootfs/home/cloud-compose/app-init.sh"; then
    fail "application lifecycle still performs source checkout after the dedicated preparation phase"
fi

source_log="$tmp/source-preparation.log"
cat >"$tmp/source-profile.sh" <<'EOF'
#!/usr/bin/env bash
:
EOF
cat >"$tmp/source-functions.sh" <<'EOF'
#!/usr/bin/env bash
compose_app_names_array() {
    local -n result="$1"
    result=(alpha beta)
}
clone_or_update_compose_app() {
    printf 'clone %s\n' "$1" >>"${SOURCE_LOG:?}"
}
run_compose_app_lifecycle() {
    printf 'lifecycle %s\n' "$*" >>"${SOURCE_LOG:?}"
    return 99
}
EOF
CLOUD_COMPOSE_PROFILE_PATH="$tmp/source-profile.sh" \
CLOUD_COMPOSE_COMPOSE_APPS_PATH="$tmp/source-functions.sh" \
SOURCE_LOG="$source_log" \
    bash "$repo_root/rootfs/home/cloud-compose/prepare-app-sources.sh"
printf 'clone alpha\nclone beta\n' >"$tmp/expected-source-preparation.log"
cmp -s "$tmp/expected-source-preparation.log" "$source_log" || \
    fail "source preparation did not clone every app without executing lifecycle work"
grep -Fq 'ExecStartPre=/bin/bash /home/cloud-compose/assert-vault-ready.sh' \
    "$repo_root/rootfs/etc/systemd/system/cloud-compose.service" || fail "app service lacks a Vault readiness gate"
grep -Fq 'ExecStartPost=/bin/bash /home/cloud-compose/vault-agent-readiness.sh wait' \
    "$repo_root/rootfs/etc/systemd/system/cloud-compose-vault-agent.service" || fail "Vault unit does not publish token readiness"

echo "Vault runtime contract passed"
