#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
unit_dir="$repo_root/rootfs/etc/systemd/system"
diagnostics_program="$repo_root/rootfs/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"
smoke_healthcheck_program="$repo_root/rootfs/home/cloud-compose/smoke-healthcheck.sh"
host_launcher="$repo_root/rootfs/etc/cloud-compose/libexec/sitectl-host.sh"

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
[[ -x "$host_launcher" ]] || fail "root-owned sitectl launcher is missing"
[[ -x "$smoke_healthcheck_program" ]] || fail "checked-in smoke healthcheck wrapper is missing or not executable"
[[ -f "$unit_dir/cloud-compose-internal-services.service" && -f "$unit_dir/cloud-compose-internal-services.timer" ]] || \
  fail "namespaced internal-services units are missing"
[[ -f "$unit_dir/cloud-compose-offhost-backup.service" ]] || fail "off-host backup service is missing"
[[ -f "$unit_dir/cloud-compose-restore-test.service" && -f "$unit_dir/cloud-compose-restore-test.timer" ]] || \
  fail "scheduled restore-test units are missing"

assert_contains "$unit_dir/cloud-compose.service" 'Requires=docker.service cloud-compose-metadata-firewall.service'
assert_contains "$unit_dir/cloud-compose.service" 'RequiresMountsFor=/mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes'
assert_contains "$unit_dir/cloud-compose.service" 'After=network-online.target docker.service cloud-compose-metadata-firewall.service'
assert_contains "$unit_dir/cloud-compose.service" 'ExecStartPre=/etc/cloud-compose/libexec/sitectl-host.sh marker require-initialized'
assert_contains "$unit_dir/cloud-compose.service" 'Restart=on-failure'
assert_contains "$unit_dir/cloud-compose.service" 'RestartSec=30s'
assert_contains "$unit_dir/cloud-compose.service" 'StartLimitIntervalSec=6h'
assert_contains "$unit_dir/cloud-compose.service" 'StartLimitBurst=3'
if grep -Fq 'ConditionPathExists=' "$unit_dir/cloud-compose-bootstrap.service"; then
  fail "bootstrap still trusts an unvalidated marker path condition"
fi
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'ExecCondition=/bin/bash /etc/cloud-compose/libexec/bootstrap-required.sh'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'ExecStart=/bin/bash /home/cloud-compose/run.sh'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'Restart=on-failure'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'RestartSec=30s'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'StartLimitIntervalSec=8h'
assert_contains "$unit_dir/cloud-compose-bootstrap.service" 'StartLimitBurst=3'
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
assert_contains "$diagnostics_program" 'exec /etc/cloud-compose/libexec/sitectl-host.sh diagnostics "$@"'
assert_contains "$host_launcher" 'exec "$sitectl" host "$@"'
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
assert_contains "$unit_dir/cloud-compose-key-rotation.service" 'TimeoutStartSec=1h'
assert_contains "$unit_dir/cloud-compose-key-rotation.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-vault-agent.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'RequiresMountsFor=/mnt/disks/data'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'User=cloud-compose'
assert_contains "$unit_dir/cloud-compose-rollout.service" 'Group=cloud-compose'

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
assert_contains "$metadata_pre_unit" 'ExecStart=/etc/cloud-compose/libexec/sitectl-host.sh metadata-firewall pre-docker'
assert_contains "$unit_dir/cloud-compose-overlay.service" 'Before=docker.service cloud-compose.service'
assert_contains "$unit_dir/cloud-compose-overlay.service" 'ExecStart=/etc/cloud-compose/libexec/sitectl-host.sh overlays'
for root_home_unit in \
  cloud-compose-docker-prune.service \
  cloud-compose-key-rotation.service \
  cloud-compose-metadata-firewall-pre.service \
  cloud-compose-metadata-firewall.service \
  cloud-compose-offhost-backup.service \
  cloud-compose-overlay.service \
  cloud-compose-restore-test.service \
  cloud-compose-vault-agent.service; do
  assert_contains "$unit_dir/$root_home_unit" '/etc/cloud-compose/libexec/sitectl-host.sh'
done
if grep -Eq '^(After|Before|BindsTo|PartOf|Requires|Requisite|Wants)=.*cloud-compose-bootstrap\\.service' \
  "$unit_dir/cloud-compose.service"; then
  fail "application service has an ordering dependency on the bootstrap service"
fi
if grep -Eq '^(After|Before|BindsTo|PartOf|Requires|Requisite|Wants)=.*cloud-compose\\.service' \
  "$unit_dir/cloud-compose-bootstrap.service"; then
  fail "bootstrap service has an ordering dependency on the application service"
fi

run_script="$repo_root/rootfs/home/cloud-compose/run.sh"
assert_contains "$run_script" 'host systemd start-wait cloud-compose.service --timeout "${app_wait_seconds}s"'
assert_contains "$run_script" 'systemd-tmpfiles is required to prepare the cloud-compose lifecycle lock'
assert_contains "$run_script" 'systemd-tmpfiles --create /etc/tmpfiles.d/cloud-compose.conf'
assert_contains "$run_script" 'systemctl restart cloud-compose-overlay.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-internal-services.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-docker-prune.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-docker-prune.timer cloud-compose-docker-prune.service'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-mariadb-backup.timer'
assert_contains "$run_script" 'runtime_enabled "${CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED:-false}"'
assert_contains "$run_script" 'systemctl enable --now cloud-compose-restore-test.timer'
assert_contains "$run_script" 'systemctl disable --now cloud-compose-restore-test.timer cloud-compose-restore-test.service'

assert_contains "$repo_root/rootfs/home/cloud-compose/host-conf.sh" 'host systemd migrate-legacy'

if rg -n '(^|[^-])vault-agent\.service|\bcron\.(service|timer)|/cron\.sh' \
  "$repo_root/rootfs" \
  >/dev/null; then
  fail "rootfs still references a generic cron or Vault Agent unit"
fi
if rg -n '(^|[^-])internal-services\.(service|timer)' \
  "$repo_root/rootfs" \
  >/dev/null; then
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
