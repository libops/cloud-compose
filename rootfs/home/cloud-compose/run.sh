#!/usr/bin/env bash

set -eou pipefail
set -x

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

run_as_cloud_compose() {
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
}

bash /home/cloud-compose/host-conf.sh
bash /home/cloud-compose/host-init.sh
run_as_cloud_compose bash /home/cloud-compose/app-init.sh
if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  bash /home/cloud-compose/rotate-keys-app.sh || true
  bash /home/cloud-compose/rotate-keys-internal.sh || true
fi
bash /home/cloud-compose/vault-agent-init.sh || true

systemctl start cloud-compose
if [ "${LIBOPS_INTERNAL_SERVICES_ENABLED:-true}" = "true" ]; then
  systemctl start internal-services.timer
fi
systemctl start libops-managed-runtime.timer
systemctl start cron.timer
systemctl start cloud-compose-mariadb-backup.timer
touch /home/cloud-compose/.cloud-compose-bootstrap-complete
chown cloud-compose:cloud-compose /home/cloud-compose/.cloud-compose-bootstrap-complete
