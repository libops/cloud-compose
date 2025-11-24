#!/usr/bin/env bash

set -eou pipefail

# restart services we've overwritten files for
systemctl restart fluent-bit
systemctl restart --no-block docker

# since COS is read only FS, install docker compose/buildx in home directory
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
