#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
unit_dir="$repo_root/rootfs/etc/systemd/system"
diagnostics_program="$repo_root/rootfs/usr/local/sbin/cloud-compose-diagnostics.sh"
smoke_healthcheck_program="$repo_root/rootfs/home/cloud-compose/smoke-healthcheck.sh"

fail() {
  echo "systemd contract: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" value="$2"
  grep -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

[[ ! -e "$unit_dir/cron.service" && ! -e "$unit_dir/cron.timer" ]] || \
  fail "generic cron units still shadow host cron"
[[ ! -e "$unit_dir/vault-agent.service" ]] || fail "generic Vault Agent unit still shadows the host agent"
[[ ! -e "$unit_dir/internal-services.service" && ! -e "$unit_dir/internal-services.timer" ]] || \
  fail "generic internal-services units still shadow host units"
[[ -f "$unit_dir/cloud-compose-docker-prune.service" && -f "$unit_dir/cloud-compose-docker-prune.timer" ]] || \
  fail "dedicated Docker prune units are missing"
[[ -f "$unit_dir/cloud-compose-vault-agent.service" ]] || fail "namespaced Vault Agent unit is missing"
[[ -f "$unit_dir/cloud-compose-overlay.service" ]] || fail "Docker overlay mount unit is missing"
[[ -f "$unit_dir/cloud-compose-bootstrap.service" ]] || fail "retryable bootstrap unit is missing"
[[ -x "$diagnostics_program" ]] || fail "checked-in Cloud Compose diagnostics program is missing or not executable"
[[ -x "$smoke_healthcheck_program" ]] || fail "checked-in smoke healthcheck wrapper is missing or not executable"
[[ -f "$unit_dir/cloud-compose-internal-services.service" && -f "$unit_dir/cloud-compose-internal-services.timer" ]] || \
  fail "namespaced internal-services units are missing"
[[ -f "$unit_dir/cloud-compose-offhost-backup.service" ]] || fail "off-host backup service is missing"
[[ -f "$unit_dir/cloud-compose-restore-test.service" && -f "$unit_dir/cloud-compose-restore-test.timer" ]] || \
  fail "scheduled restore-test units are missing"

assert_contains "$unit_dir/cloud-compose.service" 'Requires=docker.service cloud-compose-metadata-firewall.service'
assert_contains "$unit_dir/cloud-compose.service" 'RequiresMountsFor=/mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes'
assert_contains "$unit_dir/cloud-compose.service" 'After=network-online.target docker.service cloud-compose-metadata-firewall.service'
assert_contains "$unit_dir/cloud-compose.service" 'ExecStartPre=/bin/bash /home/cloud-compose/assert-app-initialized.sh'
assert_contains "$unit_dir/cloud-compose.service" 'Restart=on-failure'
assert_contains "$unit_dir/cloud-compose.service" 'RestartSec=30s'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'ConditionPathExists=!/home/cloud-compose/.cloud-compose-bootstrap-complete'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'ExecStart=/bin/bash /home/cloud-compose/run-bootstrap.sh'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'Restart=on-failure'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'RestartSec=30s'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'TimeoutStartSec=2h'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'UMask=0022'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'StandardOutput=journal'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'StandardError=journal'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'SyslogIdentifier=cloud-compose-bootstrap'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'SyslogLevel=info'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'SyslogLevelPrefix=no'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'LogRateLimitIntervalSec=30s'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'LogRateLimitBurst=1000'
assert_contains "$unit_dir/cloud-compose-internal-services.service" 'Requires=cloud-compose.service cloud-compose-metadata-firewall.service'
assert_contains "$unit_dir/cloud-compose.service" 'TimeoutStartSec=90min'
assert_contains "$diagnostics_program" 'usage: ${diagnostics_program} state|status|dump'
assert_contains "$diagnostics_program" 'readonly PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
assert_contains "$diagnostics_program" '--- Cloud Compose provisioning heartbeat ---'
assert_contains "$diagnostics_program" 'ps -p "$main_pid" -o pid=,ppid=,stat=,etime=,comm='
assert_contains "$smoke_healthcheck_program" 'source /home/cloud-compose/profile.sh'
assert_contains "$smoke_healthcheck_program" 'exec sitectl healthcheck --context "$context" --persist --format table'
assert_contains "$unit_dir/cloud-compose-mariadb-backup.service" 'TimeoutStartSec=12h'
assert_contains "$unit_dir/cloud-compose-mariadb-backup.service" 'User=cloud-compose'
assert_contains "$unit_dir/cloud-compose-mariadb-backup.timer" 'Unit=cloud-compose-offhost-backup.service'
assert_contains "$unit_dir/cloud-compose-offhost-backup.service" 'Requires=cloud-compose-mariadb-backup.service'
assert_contains "$unit_dir/cloud-compose-offhost-backup.service" 'After=cloud-compose-mariadb-backup.service network-online.target'
assert_contains "$unit_dir/cloud-compose-offhost-backup.service" 'User=root'
assert_contains "$unit_dir/cloud-compose-offhost-backup.service" 'UMask=0077'
assert_contains "$unit_dir/cloud-compose-offhost-backup.service" 'TimeoutStartSec=24h'
assert_contains "$unit_dir/cloud-compose-restore-test.service" 'User=root'
assert_contains "$unit_dir/cloud-compose-restore-test.service" 'UMask=0077'
assert_contains "$unit_dir/cloud-compose-restore-test.service" 'TimeoutStartSec=24h'
assert_contains "$unit_dir/cloud-compose-restore-test.timer" 'OnCalendar=Sun *-*-* 03:00:00'
assert_contains "$unit_dir/cloud-compose-restore-test.timer" 'Persistent=true'
if grep -Fq 'Wants=cloud-compose.service' "$unit_dir/cloud-compose-mariadb-backup.service"; then
  fail "backup service starts an intentionally inactive application"
fi
assert_contains "$unit_dir/libops-managed-runtime.service" 'TimeoutStartSec=1h'
assert_contains "$unit_dir/cloud-compose-key-rotation.service" 'TimeoutStartSec=1h'
assert_contains "$unit_dir/cloud-compose-key-rotation.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-vault-agent.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'User=cloud-compose'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'Group=cloud-compose'
assert_contains "$unit_dir/libops-managed-runtime.service" 'RequiresMountsFor=/mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes'

docker_mount_dropin="$unit_dir/docker.service.d/cloud-compose-mounts.conf"
[[ -f "$docker_mount_dropin" ]] || fail "Docker persistent-mount drop-in is missing"
assert_contains "$docker_mount_dropin" 'RequiresMountsFor=/mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes'
assert_contains "$docker_mount_dropin" 'Requires=cloud-compose-overlay.service'
docker_metadata_dropin="$unit_dir/docker.service.d/cloud-compose-metadata-firewall.conf"
metadata_pre_unit="$unit_dir/cloud-compose-metadata-firewall-pre.service"
[[ -f "$docker_metadata_dropin" && -f "$metadata_pre_unit" ]] || \
  fail "pre-Docker metadata firewall units are missing"
assert_contains "$docker_metadata_dropin" 'Requires=cloud-compose-metadata-firewall-pre.service'
assert_contains "$docker_metadata_dropin" 'After=cloud-compose-metadata-firewall-pre.service'
assert_contains "$metadata_pre_unit" 'Before=docker.service'
assert_contains "$metadata_pre_unit" 'WantedBy=multi-user.target'
assert_contains "$metadata_pre_unit" 'ExecStart=/bin/bash /home/cloud-compose/configure-metadata-firewall.sh pre-docker'
assert_contains "$unit_dir/cloud-compose-overlay.service" 'Before=docker.service cloud-compose.service'
assert_contains "$unit_dir/cloud-compose-overlay.service" 'ExecStart=/bin/bash /home/cloud-compose/mount-overlays.sh'
if grep -Eq '^(After|Before|BindsTo|PartOf|Requires|Requisite|Wants)=.*cloud-compose-bootstrap\\.service' \
  "$unit_dir/cloud-compose.service"; then
  fail "application service has an ordering dependency on the bootstrap service"
fi
if grep -Eq '^(After|Before|BindsTo|PartOf|Requires|Requisite|Wants)=.*cloud-compose\\.service' \
  "$unit_dir/cloud-compose-bootstrap.service"; then
  fail "bootstrap service has an ordering dependency on the application service"
fi

run_script="$repo_root/rootfs/home/cloud-compose/run.sh"
assert_contains "$run_script" 'cloud_compose_start_and_wait_for_oneshot cloud-compose.service "$app_wait_seconds"'
assert_contains "$run_script" 'systemd-tmpfiles is required to prepare the cloud-compose lifecycle lock'
assert_contains "$run_script" 'systemd-tmpfiles --create /etc/tmpfiles.d/cloud-compose.conf'
assert_contains "$run_script" 'systemctl restart cloud-compose-overlay.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-internal-services.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service'
assert_contains "$run_script" 'systemctl enable --now libops-managed-runtime.timer'
assert_contains "$run_script" 'systemctl disable --now libops-managed-runtime.timer libops-managed-runtime.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-docker-prune.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-docker-prune.timer cloud-compose-docker-prune.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-mariadb-backup.timer'
assert_contains "$run_script" 'runtime_enabled "${CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED:-false}"'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-restore-test.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-restore-test.timer cloud-compose-restore-test.service'

migration_script="$repo_root/rootfs/home/cloud-compose/migrate-legacy-systemd-units.sh"
migration_tmp="$(mktemp -d)"
trap 'rm -rf "$migration_tmp"' EXIT
mkdir -p "$migration_tmp/units" "$migration_tmp/bin"
cat >"$migration_tmp/units/internal-services.service" <<'EOF'
[Unit]
Description=Internal Services (Ping, Metrics, Power Management)
[Service]
WorkingDirectory=/mnt/disks/data/libops-internal
EOF
cat >"$migration_tmp/units/internal-services.timer" <<'EOF'
[Unit]
Description=Delay Internal Services until 20m after initial boot
[Timer]
OnBootSec=20min
Unit=internal-services.service
EOF
cat >"$migration_tmp/units/vault-agent.service" <<'EOF'
[Unit]
Description=Host-owned Vault Agent
[Service]
ExecStart=/usr/bin/vault agent -config=/etc/vault-agent.hcl
EOF
cat >"$migration_tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MIGRATION_SYSTEMCTL_LOG:?}"
EOF
chmod +x "$migration_tmp/bin/systemctl"
: >"$migration_tmp/systemctl.log"
PATH="$migration_tmp/bin:$PATH" \
  CLOUD_COMPOSE_SYSTEMD_UNIT_DIR="$migration_tmp/units" \
  MIGRATION_SYSTEMCTL_LOG="$migration_tmp/systemctl.log" \
  bash "$migration_script"
[[ ! -e "$migration_tmp/units/internal-services.service" && ! -e "$migration_tmp/units/internal-services.timer" ]] || \
  fail "legacy Cloud Compose internal-services units were not migrated"
[[ -e "$migration_tmp/units/vault-agent.service" ]] || fail "migration removed an unrelated host Vault Agent"
grep -Fq 'disable --now internal-services.service' "$migration_tmp/systemctl.log" || \
  fail "legacy internal-services service was not stopped and disabled"

if rg -n '(^|[^-])vault-agent\.service|\bcron\.(service|timer)|/cron\.sh' \
  "$repo_root/rootfs" \
  --glob '!**/migrate-legacy-systemd-units.sh' >/dev/null; then
  fail "rootfs still references a generic cron or Vault Agent unit"
fi
if rg -n '(^|[^-])internal-services\.(service|timer)' \
  "$repo_root/rootfs" \
  --glob '!**/migrate-legacy-systemd-units.sh' >/dev/null; then
  fail "rootfs still references generic internal-services units"
fi

# systemd-analyze is absent from some minimal CI images. When present, reject
# parser/ordering errors while allowing only missing host executable/dependency
# diagnostics caused by verifying an unpacked rootfs.
if command -v systemd-analyze >/dev/null 2>&1; then
  verify_output="$(mktemp)"
  if ! systemd-analyze verify "$unit_dir"/*.service "$unit_dir"/*.timer 2>"$verify_output"; then
    unexpected="$(grep -Ev \
      'Command .* is not executable|Unit .* not found|Failed to add dependency on .*: Invalid argument' \
      "$verify_output" || true)"
    if [[ -n "$unexpected" ]]; then
      cat "$verify_output" >&2
      rm -f "$verify_output"
      fail "systemd-analyze rejected the Cloud Compose units"
    fi
  fi
  rm -f "$verify_output"
fi

echo "Systemd contract passed"
