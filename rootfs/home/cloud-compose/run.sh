#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

sitectl=/home/cloud-compose/bin/sitectl
[[ -x "$sitectl" && ! -L "$sitectl" ]] || sitectl=/etc/cloud-compose/bin/bootstrap-sitectl

run_as_cloud_compose() (
  # Configuration-management entrypoints commonly launch run.sh from /root.
  # Enter an accessible directory before dropping privileges so child scripts
  # can safely use directory stacks and relative tool behavior.
  cd /home/cloud-compose
  if command -v runuser >/dev/null 2>&1; then
    runuser -u cloud-compose -- env HOME=/home/cloud-compose PATH="/home/cloud-compose/bin:$PATH" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u cloud-compose env HOME=/home/cloud-compose PATH="/home/cloud-compose/bin:$PATH" "$@"
  else
    echo "Neither runuser nor sudo is available for cloud-compose app init" >&2
    return 1
  fi
)

runtime_enabled() {
  case "${1:-false}" in
    true | TRUE | 1 | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

durable_bootstrap_marker="/var/lib/cloud-compose/bootstrap-complete"
current_boot_app_init_marker="/run/cloud-compose-app-init-complete"
fresh_filesystem_marker="${CLOUD_COMPOSE_FRESH_FILESYSTEM_MARKER:-/mnt/disks/data/.cloud-compose/fresh-filesystem}"
fresh_filesystem_identity="${CLOUD_COMPOSE_FRESH_FILESYSTEM_IDENTITY:-fresh}"
app_wait_seconds="${CLOUD_COMPOSE_APP_WAIT_SECONDS:-4500}"

# The shared lifecycle lock must exist before the root-owned managed-runtime
# installer and the unprivileged application service can contend for it. This
# explicit creation covers first boot; systemd-tmpfiles recreates it thereafter.
command -v systemd-tmpfiles >/dev/null 2>&1 || {
  echo "systemd-tmpfiles is required to prepare the cloud-compose lifecycle lock" >&2
  exit 1
}
systemd-tmpfiles --create /etc/tmpfiles.d/cloud-compose.conf

# Overlay mounts must exist before Docker inspects its volume data root. The
# unit is a no-op when no GCP overlay volumes are configured, but remains a
# hard Docker dependency on later boots so a missing source fails closed.
systemctl daemon-reload
systemctl enable cloud-compose-overlay.service
systemctl restart cloud-compose-overlay.service

bash /home/cloud-compose/host-conf.sh
"$sitectl" host configure
managed_sitectl=/home/cloud-compose/bin/sitectl
[[ -x "$managed_sitectl" ]] || {
  echo "Managed sitectl runtime was not installed" >&2
  exit 1
}
# Persistent ignored files can retain metadata from an older VM generation.
# Repair only the exact manifest project directory and its existing .env before
# any unprivileged source or application lifecycle needs to write there.
"$sitectl" host apps converge-filesystems
# Source preparation performs no application lifecycle work. It gives key
# rotation a validated destination without allowing app/plugin initialization
# to run before an explicitly enabled Vault Agent has authenticated.
run_as_cloud_compose "$managed_sitectl" host apps prepare
if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  if [[ ! "$fresh_filesystem_identity" =~ ^v1:gcp-disk-id:[0-9]{1,32}$ ]]; then
    echo "GCP fresh-filesystem identity is missing or unsafe" >&2
    exit 1
  fi
  "$sitectl" host keys daily
fi
"$sitectl" host marker consume-fresh \
  "$fresh_filesystem_marker" "$fresh_filesystem_identity"
sync
if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  if runtime_enabled "${GCP_APP_CREDENTIALS_ENABLED:-false}" ||
    runtime_enabled "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}"; then
    systemctl enable --now cloud-compose-key-rotation.timer
  else
    systemctl disable --now cloud-compose-key-rotation.timer cloud-compose-key-rotation.service >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now cloud-compose-key-rotation.timer cloud-compose-key-rotation.service >/dev/null 2>&1 || true
fi
# An explicitly enabled Vault Agent is a startup dependency. Its systemd unit
# also publishes a readiness marker before the application service may start.
"$sitectl" host vault-agent init
if [[ "$("$sitectl" host marker app-status \
    "$durable_bootstrap_marker" "$current_boot_app_init_marker")" == initialize ]]; then
  rm -f -- "$current_boot_app_init_marker"
  run_as_cloud_compose "$managed_sitectl" host apps lifecycle init
  "$sitectl" host marker publish "$current_boot_app_init_marker"
else
  echo "Application initialization already completed during this boot; resuming service convergence"
fi

"$sitectl" host systemd start-wait cloud-compose.service --timeout "${app_wait_seconds}s"
if runtime_enabled "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}"; then
  systemctl enable --now cloud-compose-internal-services.timer
else
  systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service >/dev/null 2>&1 || true
fi
if runtime_enabled "${CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED:-false}"; then
  systemctl enable --now cloud-compose-docker-prune.timer
else
  systemctl disable --now cloud-compose-docker-prune.timer cloud-compose-docker-prune.service >/dev/null 2>&1 || true
fi
systemctl enable --now cloud-compose-mariadb-backup.timer
if runtime_enabled "${CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED:-false}"; then
  systemctl enable --now cloud-compose-restore-test.timer
else
  systemctl disable --now cloud-compose-restore-test.timer cloud-compose-restore-test.service >/dev/null 2>&1 || true
fi
"$sitectl" host marker publish "$durable_bootstrap_marker"
