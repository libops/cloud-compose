#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  # block metadata server from docker and non-root
  /sbin/iptables -I FORWARD -d 169.254.169.254/32 -i docker0 -j DROP || true
  /sbin/iptables -A OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254/32 -p tcp --dport 80 -j DROP || true
fi

if systemctl list-unit-files fluent-bit.service >/dev/null 2>&1; then
  systemctl restart fluent-bit || true
fi

bash /home/cloud-compose/install-dependencies.sh

if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  # Docker build containers cannot use GCE metadata DNS after we block metadata
  # access from docker0, so give Docker explicit external resolvers.
  install -d /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "data-root": "/mnt/disks/data/docker",
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
}
EOF
fi

# restart services we've overwritten files for
systemctl restart docker

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

bash /home/cloud-compose/libops-managed-runtime.sh install-tools
systemctl daemon-reload
systemctl enable libops-managed-runtime.timer
