#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

run_as_cloud_compose() (
  # Configuration-management entrypoints commonly launch run.sh from /root.
  # Enter an accessible directory before dropping privileges so child scripts
  # can safely use directory stacks and relative tool behavior.
  cd /home/cloud-compose
  if command -v runuser >/dev/null 2>&1; then
    runuser -u cloud-compose -- env HOME=/home/cloud-compose PATH="$PATH" "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u cloud-compose env HOME=/home/cloud-compose PATH="$PATH" "$@"
  elif command -v su >/dev/null 2>&1; then
    su -s /bin/bash -c "HOME=/home/cloud-compose PATH=$(printf '%q' "$PATH") $(printf '%q ' "$@")" cloud-compose
  else
    echo "No supported user-switching command found for cloud-compose app init" >&2
    return 1
  fi
)

runtime_enabled() {
  case "${1:-false}" in
    true | TRUE | 1 | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}

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
bash /home/cloud-compose/host-init.sh
# Source preparation performs no application lifecycle work. It gives key
# rotation a validated destination without allowing app/plugin initialization
# to run before an explicitly enabled Vault Agent has authenticated.
run_as_cloud_compose bash /home/cloud-compose/prepare-app-sources.sh
if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  bash /home/cloud-compose/rotate-keys-daily.sh
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
bash /home/cloud-compose/vault-agent-init.sh
run_as_cloud_compose bash /home/cloud-compose/app-init.sh

systemctl enable --now cloud-compose.service
if runtime_enabled "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}"; then
  systemctl enable --now cloud-compose-internal-services.timer
else
  systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service >/dev/null 2>&1 || true
fi
if runtime_enabled "${LIBOPS_MANAGED_RUNTIME_ENABLED:-true}"; then
  systemctl enable --now libops-managed-runtime.timer
else
  systemctl disable --now libops-managed-runtime.timer libops-managed-runtime.service >/dev/null 2>&1 || true
fi
if runtime_enabled "${CLOUD_COMPOSE_DOCKER_PRUNE_ENABLED:-false}"; then
  systemctl enable --now cloud-compose-docker-prune.timer
else
  systemctl disable --now cloud-compose-docker-prune.timer cloud-compose-docker-prune.service >/dev/null 2>&1 || true
fi
systemctl enable --now cloud-compose-mariadb-backup.timer
touch /home/cloud-compose/.cloud-compose-bootstrap-complete
chown cloud-compose:cloud-compose /home/cloud-compose/.cloud-compose-bootstrap-complete
