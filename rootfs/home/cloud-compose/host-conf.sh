#!/usr/bin/env bash

set -eou pipefail

awk -v prepend="$(cat /home/cloud-compose/fluent-bit.conf)" '/# Collects docker.service logs/ {print prepend} 1' /etc/fluent-bit/fluent-bit.conf > /etc/fluent-bit/fluent-bit.conf.new
mv /etc/fluent-bit/fluent-bit.conf /etc/fluent-bit/fluent-bit.bak
mv /etc/fluent-bit/fluent-bit.conf.new /etc/fluent-bit/fluent-bit.conf
systemctl restart fluent-bit

mkdir -p /mnt/disks/data/docker
echo '{"data-root": "/mnt/disks/data/docker"}' | jq . > /etc/docker/daemon.json
systemctl restart --no-block docker

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
