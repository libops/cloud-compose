#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_script="$repo_root/rootfs/home/cloud-compose/run.sh"
vault_unit="$repo_root/rootfs/etc/systemd/system/cloud-compose-vault-agent.service"

fail() {
  echo "vault runtime contract: $*" >&2
  exit 1
}

source_line="$(grep -nF 'run_as_cloud_compose "$managed_sitectl" host apps prepare' "$run_script" | cut -d: -f1)"
rotation_line="$(grep -nF '"$sitectl" host keys daily' "$run_script" | cut -d: -f1)"
vault_line="$(grep -nF '"$sitectl" host vault-agent init' "$run_script" | cut -d: -f1)"
init_line="$(grep -nF 'run_as_cloud_compose "$managed_sitectl" host apps lifecycle init' "$run_script" | cut -d: -f1)"
app_line="$(grep -nF 'host systemd start-wait cloud-compose.service' "$run_script" | cut -d: -f1)"
[[ -n "$source_line" && -n "$rotation_line" && -n "$vault_line" && -n "$init_line" && -n "$app_line" ]] ||
  fail "bootstrap is missing a source, rotation, Vault, init, or app-service phase"
((source_line < rotation_line && rotation_line < vault_line && vault_line < init_line && init_line < app_line)) ||
  fail "bootstrap must order source preparation -> rotation -> Vault readiness -> app lifecycle -> app service"

grep -Fq 'ExecStartPre=/etc/cloud-compose/libexec/sitectl-host.sh vault-agent assert-ready' \
  "$repo_root/rootfs/etc/systemd/system/cloud-compose.service" ||
  fail "app service lacks a Vault readiness gate"
for readiness_command in \
  'ExecStartPre=/etc/cloud-compose/libexec/sitectl-host.sh vault-readiness prepare' \
  'ExecStartPost=/etc/cloud-compose/libexec/sitectl-host.sh vault-readiness wait' \
  'ExecStopPost=/etc/cloud-compose/libexec/sitectl-host.sh vault-readiness clear'; do
  grep -Fq "$readiness_command" "$vault_unit" ||
    fail "Vault unit does not route readiness through the trusted root launcher: $readiness_command"
done
