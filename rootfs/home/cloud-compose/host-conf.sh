#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
sitectl=/home/cloud-compose/bin/sitectl
[[ -x "$sitectl" && ! -L "$sitectl" ]] || sitectl=/etc/cloud-compose/bin/bootstrap-sitectl

if [ -z "${CLOUD_COMPOSE_PROVIDER:-}" ]; then
  echo "CLOUD_COMPOSE_PROVIDER is required" >&2
  exit 1
fi

if systemctl list-unit-files fluent-bit.service >/dev/null 2>&1; then
  systemctl restart fluent-bit || true
fi

# COS already has a running Docker daemon. Install the metadata deny policy
# before any bootstrap container is allowed to execute third-party image or
# package content. Debian-family images install Docker below and receive the
# same policy immediately after that daemon is restarted.
if [ "$CLOUD_COMPOSE_PROVIDER" = "gcp" ] && command -v docker >/dev/null 2>&1; then
  "$sitectl" host metadata-firewall
fi

bash /home/cloud-compose/install-dependencies.sh

for required_command in curl flock gzip jq openssl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required cloud-compose host dependency is missing: $required_command" >&2
    exit 1
  fi
done

# restart services we've overwritten files for
systemctl restart docker
if [ "$CLOUD_COMPOSE_PROVIDER" = "gcp" ]; then
  # Docker may reprogram its chains during restart. Reassert the deny policy
  # before any persistent application container is allowed to proceed.
  "$sitectl" host metadata-firewall
fi

# wait until our data-root /etc/docker/daemon.json setting is applied
deadline=$((SECONDS + 120))
while [ "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)" != "/mnt/disks/data/docker" ]; do
  if (( SECONDS >= deadline )); then
    echo "Docker did not switch to /mnt/disks/data/docker" >&2
    docker info || true
    systemctl status docker --no-pager || true
    cat /etc/docker/daemon.json || true
    findmnt /mnt/disks/data || true
    exit 1
  fi
  echo "Waiting for docker data-root"
  sleep 2
done

"$sitectl" host systemd migrate-legacy
systemctl daemon-reload
if [ "$CLOUD_COMPOSE_PROVIDER" = "gcp" ]; then
  # Gate later Docker starts behind the early guard on stateful hosts, and make
  # the dependency available after each COS cloud-init reconstruction. Reapply
  # the Docker-specific layer after the daemon creates DOCKER-USER.
  systemctl enable --now cloud-compose-metadata-firewall-pre.service
  systemctl enable --now cloud-compose-metadata-firewall.service
else
  systemctl disable --now \
    cloud-compose-metadata-firewall-pre.service \
    cloud-compose-metadata-firewall.service >/dev/null 2>&1 || true
fi

"$sitectl" host runtime install
