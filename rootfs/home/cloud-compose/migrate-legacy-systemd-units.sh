#!/usr/bin/env bash

set -euo pipefail

unit_dir="${CLOUD_COMPOSE_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

remove_legacy_unit() {
  local unit="$1"
  shift
  local signature
  local unit_file="${unit_dir}/${unit}"

  # Never remove a host unit merely because its generic name collides. Only
  # migrate the exact unit shape previously shipped by Cloud Compose.
  if [[ -L "$unit_file" || ! -f "$unit_file" ]]; then
    return 0
  fi
  for signature in "$@"; do
    if ! grep -Fq -- "$signature" "$unit_file"; then
      return 0
    fi
  done

  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  rm -f -- "$unit_file"
}

remove_legacy_unit cron.service \
  'Description=cron' \
  'ExecStart=/bin/bash /home/cloud-compose/cron.sh'
remove_legacy_unit cron.timer \
  'Description=cron' \
  'OnBootSec=10m' \
  'OnUnitInactiveSec=24h' \
  'WakeSystem=true'
remove_legacy_unit vault-agent.service \
  'ConditionPathExists=/etc/vault-agent.d/cloud-compose.hcl' \
  'ExecStart=/usr/local/bin/vault agent -config=/etc/vault-agent.d/cloud-compose.hcl'
remove_legacy_unit internal-services.service \
  'Description=Internal Services (Ping, Metrics, Power Management)' \
  'WorkingDirectory=/mnt/disks/data/libops-internal'
remove_legacy_unit internal-services.timer \
  'Description=Delay Internal Services until 20m after initial boot' \
  'OnBootSec=20min' \
  'Unit=internal-services.service'
