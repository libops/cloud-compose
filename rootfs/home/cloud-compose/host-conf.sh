#!/usr/bin/env bash

set -eou pipefail

# block metadata server from docker and non-root
/sbin/iptables -I FORWARD -d 169.254.169.254/32 -i docker0 -j DROP
/sbin/iptables -A OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254/32 -p tcp --dport 80 -j DROP

# restart services we've overwritten files for
systemctl restart fluent-bit
systemctl restart docker

# wait until our data-root /etc/docker/daemon.json setting are applied
until test -d /mnt/disks/data/docker/volumes; do
  echo "Waiting for docker volumes dir"
  sleep 1
done

# move volumes from docker's data root to our volumes disk
rm -rf /mnt/disks/data/docker/volumes
ln -s /mnt/disks/volumes /mnt/disks/data/docker/volumes

# since COS is read only FS, install docker compose/buildx in home directory
# and symlink to our data disk which can have executables
if [ ! -f "/home/cloud-compose/.docker/cli-plugins/docker-compose" ]; then
    curl -sSL \
        https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64 \
        -o /mnt/disks/data/docker-compose
    chmod o+x /mnt/disks/data/docker-compose
    mkdir -p /home/cloud-compose/.docker/cli-plugins
    ln -sf /mnt/disks/data/docker-compose /home/cloud-compose/.docker/cli-plugins/docker-compose
fi

if [ ! -f "/home/cloud-compose/.docker/cli-plugins/docker-buildx" ]; then
    curl -sSL \
        https://github.com/docker/buildx/releases/download/v0.30.1/buildx-v0.30.1.linux-amd64 \
        -o /mnt/disks/data/docker-buildx
    chmod o+x /mnt/disks/data/docker-buildx
    ln -sf /mnt/disks/data/docker-buildx /home/cloud-compose/.docker/cli-plugins/docker-buildx
fi
