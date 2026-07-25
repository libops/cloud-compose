#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helpers="$repo_root/rootfs/home/cloud-compose/bootstrap-helpers.sh"
assert_initialized="$repo_root/rootfs/home/cloud-compose/assert-app-initialized.sh"
start_bootstrap="$repo_root/rootfs/home/cloud-compose/start-cloud-compose-bootstrap.sh"
run_script="$repo_root/rootfs/home/cloud-compose/run.sh"
app_init="$repo_root/rootfs/home/cloud-compose/app-init.sh"
run_bootstrap="$repo_root/rootfs/home/cloud-compose/run-bootstrap.sh"
bootstrap_unit="$repo_root/rootfs/etc/systemd/system/cloud-compose-bootstrap.service"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "bootstrap recovery contract: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1" value="$2"
    grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

mkdir -p "$tmp/bin" "$tmp/run"
systemctl_log="$tmp/systemctl.log"
active_calls="$tmp/active-calls"
: >"$systemctl_log"
printf '0\n' >"$active_calls"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

printf '%s\n' "$*" >>"${SYSTEMCTL_LOG:?}"
case "$1" in
    show)
        property=""
        for arg in "$@"; do
            case "$arg" in
                --property=*) property="${arg#--property=}" ;;
            esac
        done
        case "$property" in
            LoadState)
                printf 'loaded\n'
                ;;
            ActiveState)
                calls="$(<"${ACTIVE_CALLS:?}")"
                calls=$((calls + 1))
                printf '%s\n' "$calls" >"$ACTIVE_CALLS"
                case "${SYSTEMD_SCENARIO:-recover}" in
                    active) printf 'active\n' ;;
                    forced)
                        if [[ -n "${UNIT_STARTED_FILE:-}" &&
                            -f "$UNIT_STARTED_FILE" ]]; then
                            printf 'active\n'
                        elif [[ -n "${UNIT_STOPPED_FILE:-}" &&
                            -f "$UNIT_STOPPED_FILE" ]]; then
                            printf 'inactive\n'
                        else
                            printf 'active\n'
                        fi
                        ;;
                    recover)
                        if ((calls == 1)); then
                            printf 'failed\n'
                        elif ((calls < 4)); then
                            printf 'activating\n'
                        else
                            printf 'active\n'
                        fi
                        ;;
                    failed) printf 'failed\n' ;;
                    *) exit 2 ;;
                esac
                ;;
            *) exit 2 ;;
        esac
        ;;
    stop)
        if [[ -n "${UNIT_STOPPED_FILE:-}" ]]; then
            : >"$UNIT_STOPPED_FILE"
            rm -f -- "${UNIT_STARTED_FILE:-}"
        fi
        ;;
    start)
        if [[ -n "${UNIT_STARTED_FILE:-}" ]]; then
            : >"$UNIT_STARTED_FILE"
        fi
        if [[ -n "${START_MARKER:-}" ]]; then
            printf 'ready\n' >"$START_MARKER"
        fi
        ;;
    enable | reset-failed | restart | daemon-reload)
        ;;
    status)
        exit 3
        ;;
    *)
        exit 2
        ;;
esac
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/bin/systemctl" "$tmp/bin/sleep"

# shellcheck disable=SC1090
source "$helpers"
PATH="$tmp/bin:/usr/bin:/bin"
export PATH SYSTEMCTL_LOG="$systemctl_log" ACTIVE_CALLS="$active_calls"

SYSTEMD_SCENARIO=recover
export SYSTEMD_SCENARIO
cloud_compose_start_and_wait_for_oneshot cloud-compose.service 10
grep -Fxq 'enable -- cloud-compose.service' "$systemctl_log" ||
    fail "failed application unit was not enabled"
grep -Fxq 'reset-failed -- cloud-compose.service' "$systemctl_log" ||
    fail "failed application unit was not reset"
grep -Fxq 'start --no-block -- cloud-compose.service' "$systemctl_log" ||
    fail "application unit was not started nonblocking"
[[ "$(<"$active_calls")" == "4" ]] ||
    fail "wait helper did not tolerate restart transitions until active"

: >"$systemctl_log"
printf '0\n' >"$active_calls"
SYSTEMD_SCENARIO=active
cloud_compose_start_systemd_unit cloud-compose.service
if grep -Eq '^(reset-failed|start) ' "$systemctl_log"; then
    fail "already active application unit was restarted"
fi

if cloud_compose_start_systemd_unit ssh.service >/dev/null 2>&1; then
    fail "start helper accepted an unrelated systemd unit"
fi
printf '0\n' >"$active_calls"
SYSTEMD_SCENARIO=failed
if CLOUD_COMPOSE_SYSTEMD_POLL_SECONDS=1 \
    cloud_compose_wait_for_oneshot cloud-compose.service 2 >/dev/null 2>&1; then
    fail "wait helper accepted a unit that never became active"
fi

durable_marker="$tmp/bootstrap-complete"
boot_marker="$tmp/run/app-init-complete"
cloud_compose_should_run_app_init "$durable_marker" "$boot_marker" ||
    fail "first boot would skip application initialization"
original_umask="$(umask)"
cloud_compose_publish_marker "$boot_marker"
[[ "$(umask)" == "$original_umask" ]] ||
    fail "publishing a marker changed the caller's umask"
if cloud_compose_should_run_app_init "$durable_marker" "$boot_marker"; then
    fail "bootstrap retry would repeat successful application initialization"
fi
cloud_compose_publish_marker "$durable_marker"
cloud_compose_should_run_app_init "$durable_marker" "$boot_marker" ||
    fail "manual convergence with durable readiness would skip application initialization"
rm -f -- "$durable_marker" "$boot_marker"

assert_env=(
    "CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH=$helpers"
    "CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER=$durable_marker"
    "CLOUD_COMPOSE_APP_INIT_MARKER=$boot_marker"
)
if env "${assert_env[@]}" bash "$assert_initialized" >/dev/null 2>&1; then
    fail "application preflight accepted missing initialization markers"
fi
cloud_compose_publish_marker "$boot_marker"
env "${assert_env[@]}" bash "$assert_initialized"
rm -f -- "$boot_marker"
cloud_compose_publish_marker "$durable_marker"
env "${assert_env[@]}" bash "$assert_initialized"
rm -f -- "$durable_marker"
ln -s /dev/null "$durable_marker"
if env "${assert_env[@]}" bash "$assert_initialized" >/dev/null 2>&1; then
    fail "application preflight accepted a symlink marker"
fi

assert_contains "$app_init" 'acquire_cloud_compose_lifecycle_lock "init"'
assert_contains "$app_init" 'trap release_cloud_compose_lifecycle_lock EXIT'
assert_contains "$run_script" 'if cloud_compose_should_run_app_init'
assert_contains "$run_script" 'cloud_compose_publish_marker "$current_boot_app_init_marker"'
assert_contains "$run_script" 'cloud_compose_start_and_wait_for_oneshot cloud-compose.service "$app_wait_seconds"'
assert_contains "$run_script" '"$fresh_filesystem_marker" "$fresh_filesystem_identity"'
assert_contains "$run_script" 'cloud_compose_publish_marker "$durable_bootstrap_marker"'
[[ "$(grep -Fc 'cloud_compose_consume_fresh_filesystem_marker \' "$run_script")" == "1" ]] ||
    fail "bootstrap must have one fresh-filesystem authority consumption boundary"
rotation_line="$(grep -nF 'bash /home/cloud-compose/rotate-keys-daily.sh' "$run_script" | cut -d: -f1)"
fresh_marker_line="$(grep -nF 'cloud_compose_consume_fresh_filesystem_marker \' "$run_script" | cut -d: -f1)"
fresh_marker_sync_line="$(grep -nFx 'sync' "$run_script" | cut -d: -f1)"
key_timer_line="$(grep -nF 'systemctl enable --now cloud-compose-key-rotation.timer' "$run_script" | cut -d: -f1)"
vault_line="$(grep -nF 'bash /home/cloud-compose/vault-agent-init.sh' "$run_script" | cut -d: -f1)"
init_line="$(grep -nF 'run_as_cloud_compose bash /home/cloud-compose/app-init.sh' "$run_script" | cut -d: -f1)"
boot_marker_line="$(grep -nF 'cloud_compose_publish_marker "$current_boot_app_init_marker"' "$run_script" | cut -d: -f1)"
app_line="$(grep -nF 'cloud_compose_start_and_wait_for_oneshot cloud-compose.service' "$run_script" | cut -d: -f1)"
durable_marker_line="$(grep -nF 'cloud_compose_publish_marker "$durable_bootstrap_marker"' "$run_script" | cut -d: -f1)"
((rotation_line < fresh_marker_line &&
    fresh_marker_line < fresh_marker_sync_line &&
    fresh_marker_sync_line < key_timer_line &&
    key_timer_line < vault_line &&
    vault_line < init_line &&
    init_line < boot_marker_line &&
    boot_marker_line < app_line &&
    app_line < durable_marker_line)) ||
    fail "bootstrap does not consume fresh authority durably before persistent rotation, Vault, and application initialization"

assert_contains "$run_bootstrap" 'if ((EUID != 0)); then'
assert_contains "$run_bootstrap" 'exec bash /home/cloud-compose/run.sh'
if rg -n 'bootstrap\\.log|exec (>>|>)[^[:space:]]' "$run_bootstrap" >/dev/null; then
    fail "bootstrap wrapper writes an independently unbounded log file"
fi
assert_contains "$bootstrap_unit" 'StandardOutput=journal'
assert_contains "$bootstrap_unit" 'StandardError=journal'
assert_contains "$bootstrap_unit" 'SyslogIdentifier=cloud-compose-bootstrap'
assert_contains "$bootstrap_unit" 'SyslogLevel=info'
assert_contains "$bootstrap_unit" 'SyslogLevelPrefix=no'
assert_contains "$bootstrap_unit" 'LogRateLimitIntervalSec=30s'
assert_contains "$bootstrap_unit" 'LogRateLimitBurst=1000'
assert_contains "$bootstrap_unit" 'UMask=0022'

# The systemd bootstrap replaces cloud-init's direct execution and must retain
# its ordinary runtime-directory semantics. In particular, the unprivileged
# application user must be able to traverse the persistent target of the
# published sitectl symlink after a first-boot root install.
bootstrap_umask="$(sed -n 's/^UMask=//p' "$bootstrap_unit")"
[[ "$bootstrap_umask" == "0022" ]] ||
    fail "bootstrap unit does not declare exactly one compatible umask"
umask_fixture="$tmp/bootstrap-umask"
(
    umask "$bootstrap_umask"
    mkdir -p "$umask_fixture/libops-managed/bin" "$umask_fixture/published"
    printf '#!/bin/sh\nexit 0\n' >"$umask_fixture/libops-managed/bin/sitectl"
    chmod +x "$umask_fixture/libops-managed/bin/sitectl"
    ln -s "$umask_fixture/libops-managed/bin/sitectl" "$umask_fixture/published/sitectl"
)
for traversable_dir in "$umask_fixture/libops-managed" "$umask_fixture/libops-managed/bin"; do
    mode="$(stat -c '%a' "$traversable_dir")"
    ((8#$mode & 0001)) ||
        fail "bootstrap umask makes the published sitectl target untraversable: $traversable_dir"
done
[[ -x "$umask_fixture/published/sitectl" ]] ||
    fail "published sitectl is not executable after first-boot installation"

assert_contains "$start_bootstrap" 'CLOUD_COMPOSE_BOOTSTRAP_WAIT_SECONDS:-10800'
assert_contains "$start_bootstrap" 'if cloud_compose_marker_exists "$durable_marker"; then'
assert_contains "$start_bootstrap" 'systemctl daemon-reload'
assert_contains "$start_bootstrap" 'systemctl stop -- "$bootstrap_unit"'
assert_contains "$start_bootstrap" 'cloud_compose_start_and_wait_for_oneshot "$bootstrap_unit" "$wait_seconds"'
if rg -n '_SYSTEMD_UNIT=cloud-compose-bootstrap\\.service' \
    "$repo_root/rootfs/etc/fluent-bit" >/dev/null; then
    fail "raw bootstrap output was added to Fluent Bit"
fi

for cloud_init_template in \
    "$repo_root/templates/cloud-init.yml" \
    "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml"; do
    assert_contains "$cloud_init_template" 'bash /home/cloud-compose/start-cloud-compose-bootstrap.sh'
    if grep -Fq 'bash /home/cloud-compose/run.sh > /home/cloud-compose/run.log 2>&1' \
        "$cloud_init_template"; then
        fail "cloud-init bypasses the retryable bootstrap unit"
    fi
done

: >"$systemctl_log"
printf '0\n' >"$active_calls"
SYSTEMD_SCENARIO=active
cloud_compose_publish_marker "$durable_marker"
CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH="$helpers" \
CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER="$durable_marker" \
SYSTEMD_SCENARIO="$SYSTEMD_SCENARIO" \
    bash "$start_bootstrap"
[[ ! -s "$systemctl_log" ]] ||
    fail "completed bootstrap was started again"

: >"$systemctl_log"
printf '0\n' >"$active_calls"
unit_stopped="$tmp/unit-stopped"
unit_started="$tmp/unit-started"
rm -f -- "$durable_marker" "$unit_stopped" "$unit_started"
SYSTEMD_SCENARIO=forced \
UNIT_STOPPED_FILE="$unit_stopped" \
UNIT_STARTED_FILE="$unit_started" \
START_MARKER="$durable_marker" \
CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH="$helpers" \
CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER="$durable_marker" \
    bash "$start_bootstrap"
grep -Fxq 'stop -- cloud-compose-bootstrap.service' "$systemctl_log" ||
    fail "removed readiness marker did not stop a stale active bootstrap unit"
grep -Fxq 'start --no-block -- cloud-compose-bootstrap.service' "$systemctl_log" ||
    fail "removed readiness marker did not start a fresh bootstrap unit"
[[ -f "$durable_marker" ]] ||
    fail "fresh bootstrap unit did not restore durable readiness"
rm -f -- "$durable_marker"

# Execute the production run script from a relocated fixture so the contract can
# inject deterministic host commands without writing to /home or /run. The
# first application-service convergence fails after app-init succeeds. The
# fresh reconciliation authority must already be consumed before that failure;
# the second run reuses the current-boot init marker and publishes durable
# readiness after the service recovers.
integration_root="$tmp/integration"
integration_home="$integration_root/home/cloud-compose"
integration_run="$integration_root/run"
integration_bin="$integration_root/bin"
integration_log="$integration_root/systemctl.log"
app_init_count="$integration_root/app-init-count"
fresh_data_root="$integration_root/data"
fresh_marker="$fresh_data_root/.cloud-compose/fresh-filesystem"
first_output="$integration_root/first-attempt.log"
retry_output="$integration_root/retry-attempt.log"
mkdir -p "$integration_home" "$integration_run" "$integration_bin" "$(dirname -- "$fresh_marker")"
: >"$integration_log"
printf '0\n' >"$app_init_count"
printf 'fresh\n' >"$fresh_marker"

sed \
    -e "s#/home/cloud-compose#$integration_home#g" \
    -e "s#/run/cloud-compose-app-init-complete#$integration_run/app-init-complete#g" \
    "$run_script" >"$integration_home/run.sh"
cp "$helpers" "$integration_home/bootstrap-helpers.sh"
cat >"$integration_home/profile.sh" <<'EOF'
#!/usr/bin/env bash
:
EOF
cat >"$integration_home/noop.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
for script in \
    host-conf.sh \
    host-init.sh \
    converge-app-filesystems.sh \
    prepare-app-sources.sh \
    vault-agent-init.sh; do
    cp "$integration_home/noop.sh" "$integration_home/$script"
done
cat >"$integration_home/app-init.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count="$(<"${APP_INIT_COUNT_FILE:?}")"
printf '%s\n' "$((count + 1))" >"$APP_INIT_COUNT_FILE"
EOF
cat >"$integration_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($# > 0)); do
    if [[ "$1" == "--" ]]; then
        shift
        exec "$@"
    fi
    shift
done
exit 2
EOF
cat >"$integration_bin/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$integration_bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$integration_bin/sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s sync\n' "${RUN_ATTEMPT:?}" >>"${INTEGRATION_SYSTEMCTL_LOG:?}"
[[ "$RUN_ATTEMPT" != "sync-fail" ]]
EOF
cat >"$integration_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s %s\n' "${RUN_ATTEMPT:?}" "$*" >>"${INTEGRATION_SYSTEMCTL_LOG:?}"
case "$1" in
    show)
        property=""
        for arg in "$@"; do
            case "$arg" in
                --property=*) property="${arg#--property=}" ;;
            esac
        done
        case "$property" in
            LoadState) printf 'loaded\n' ;;
            ActiveState)
                if [[ "$RUN_ATTEMPT" == "fail" ]]; then
                    printf 'failed\n'
                else
                    printf 'active\n'
                fi
                ;;
            *) exit 2 ;;
        esac
        ;;
    daemon-reload | disable | enable | reset-failed | restart | start)
        ;;
    status)
        exit 3
        ;;
    *)
        exit 2
        ;;
esac
EOF
cat >"$integration_bin/stat" <<'EOF'
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
marker="${INTEGRATION_FRESH_MARKER:?}"
case "$target:$format" in
    "$(dirname -- "$marker"):%u:%g:%a")
        printf '%s\n' "${FRESH_MARKER_DIR_IDENTITY:-0:0:700}"
        ;;
    "$marker:%u:%g:%a:%h")
        printf '%s\n' "${FRESH_MARKER_IDENTITY:-0:0:600:1}"
        ;;
    *)
        exec /usr/bin/stat "$@"
        ;;
esac
EOF
chmod +x "$integration_bin"/*

integration_env=(
    "APP_INIT_COUNT_FILE=$app_init_count"
    "CLOUD_COMPOSE_APP_WAIT_SECONDS=1"
    "CLOUD_COMPOSE_SYSTEMD_POLL_SECONDS=1"
    "CLOUD_COMPOSE_PROVIDER=contract"
    "CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED=false"
    "CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER=$fresh_marker"
    "LIBOPS_INTERNAL_SERVICES_ENABLED=false"
    "LIBOPS_MANAGED_RUNTIME_ENABLED=false"
    "INTEGRATION_FRESH_MARKER=$fresh_marker"
    "INTEGRATION_SYSTEMCTL_LOG=$integration_log"
    "PATH=$integration_bin:/usr/bin:/bin"
)
if env "${integration_env[@]}" RUN_ATTEMPT=fail \
    bash "$integration_home/run.sh" >"$first_output" 2>&1; then
    fail "first full bootstrap attempt accepted a failed application service"
fi
[[ "$(<"$app_init_count")" == "1" ]] ||
    fail "first full bootstrap attempt did not complete app-init exactly once"
[[ -f "$integration_run/app-init-complete" ]] ||
    fail "failed first attempt did not retain current-boot app-init readiness"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "failed first attempt published durable bootstrap readiness"
[[ ! -e "$fresh_marker" ]] ||
    fail "failed first attempt retained fresh-filesystem authority past key convergence"

env "${integration_env[@]}" RUN_ATTEMPT=recover \
    bash "$integration_home/run.sh" >"$retry_output" 2>&1
[[ "$(<"$app_init_count")" == "1" ]] ||
    fail "bootstrap retry repeated successful app-init"
[[ -f "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "bootstrap retry did not publish durable readiness"
[[ ! -e "$fresh_marker" ]] ||
    fail "successful bootstrap retry retained fresh-filesystem reconciliation authority"
grep -Fq 'Application initialization already completed during this boot' "$retry_output" ||
    fail "bootstrap retry did not report reuse of successful app-init"
grep -Fq 'fail reset-failed -- cloud-compose.service' "$integration_log" ||
    fail "first bootstrap attempt did not exercise failed service recovery"
grep -Fq 'recover enable -- cloud-compose.service' "$integration_log" ||
    fail "bootstrap retry did not converge the application service"

# Marker removal must be flushed before durable readiness can be republished.
rm -f -- "$integration_home/.cloud-compose-bootstrap-complete"
printf 'fresh\n' >"$fresh_marker"
if env "${integration_env[@]}" RUN_ATTEMPT=sync-fail \
    bash "$integration_home/run.sh" >/dev/null 2>&1; then
    fail "bootstrap accepted a failed post-consume durability barrier"
fi
[[ ! -e "$fresh_marker" ]] ||
    fail "post-consume durability coverage did not remove the fresh marker"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "failed post-consume durability barrier published readiness"
env "${integration_env[@]}" RUN_ATTEMPT=recover \
    bash "$integration_home/run.sh" >/dev/null 2>&1
[[ -f "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "bootstrap retry did not flush an already-absent marker before readiness"

# GCP never falls back to the generic non-GCP marker identity. This check runs
# before key rotation, so missing disk identity cannot reach IAM.
rm -f -- "$integration_home/.cloud-compose-bootstrap-complete"
printf 'fresh\n' >"$fresh_marker"
if env "${integration_env[@]}" CLOUD_COMPOSE_PROVIDER=gcp RUN_ATTEMPT=recover \
    bash "$integration_home/run.sh" >/dev/null 2>&1; then
    fail "GCP bootstrap accepted the generic fresh-filesystem identity"
fi
[[ -f "$fresh_marker" ]] ||
    fail "GCP bootstrap consumed generic fresh-filesystem authority"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "GCP bootstrap with generic authority published durable readiness"

# A marker payload for another incarnation must fail before application
# initialization or durable readiness.
rm -f -- "$integration_home/.cloud-compose-bootstrap-complete"
printf 'v1:gcp-disk-id:111111111111111111\n' >"$fresh_marker"
if env "${integration_env[@]}" RUN_ATTEMPT=recover \
    bash "$integration_home/run.sh" >/dev/null 2>&1; then
    fail "bootstrap accepted a mismatched fresh-filesystem marker payload"
fi
[[ -f "$fresh_marker" ]] ||
    fail "mismatched fresh-filesystem marker payload was consumed"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "mismatched fresh-filesystem marker payload published durable readiness"

# Unsafe authority must fail closed before durable readiness. The current-boot
# app-init marker remains valid, so these attempts exercise only the early
# marker boundary rather than repeating application initialization.
rm -f -- "$integration_home/.cloud-compose-bootstrap-complete"
printf 'fresh\n' >"$fresh_marker"
if env "${integration_env[@]}" RUN_ATTEMPT=recover \
    FRESH_MARKER_IDENTITY=1000:1000:600:1 \
    bash "$integration_home/run.sh" >/dev/null 2>&1; then
    fail "bootstrap accepted a fresh-filesystem marker with unsafe ownership"
fi
[[ -f "$fresh_marker" ]] ||
    fail "unsafe fresh-filesystem marker was consumed"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "unsafe fresh-filesystem marker published durable readiness"

rm -f -- "$fresh_marker"
ln -s /dev/null "$fresh_marker"
if env "${integration_env[@]}" RUN_ATTEMPT=recover \
    bash "$integration_home/run.sh" >/dev/null 2>&1; then
    fail "bootstrap accepted a symlink fresh-filesystem marker"
fi
[[ -L "$fresh_marker" ]] ||
    fail "symlink fresh-filesystem marker was consumed"
[[ ! -e "$integration_home/.cloud-compose-bootstrap-complete" ]] ||
    fail "symlink fresh-filesystem marker published durable readiness"

echo "Bootstrap recovery contract passed"
