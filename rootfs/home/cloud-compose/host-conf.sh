#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

# block metadata server from docker and non-root
/sbin/iptables -I FORWARD -d 169.254.169.254/32 -i docker0 -j DROP
/sbin/iptables -A OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254/32 -p tcp --dport 80 -j DROP

# restart services we've overwritten files for
systemctl restart fluent-bit
systemctl restart docker

# wait until our data-root /etc/docker/daemon.json setting are applied
until test -d /mnt/disks/data/docker/overlay2; do
  echo "Waiting for docker overlay2 dir"
  sleep 1
done

mkdir -p /home/cloud-compose/.docker/cli-plugins /home/cloud-compose/bin

# since COS is read only FS, install host tools in the home directory
# and symlink to our data disk which can have executables.
# A custom COS image could eventually bake these in, but it is unnecessary
# for this handful of simple creation-time installs.
if [ ! -f "/home/cloud-compose/.docker/cli-plugins/docker-compose" ]; then
    retry_until_success curl -sSL \
        https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64 \
        -o /mnt/disks/data/docker-compose
    chmod o+x /mnt/disks/data/docker-compose
    ln -sf /mnt/disks/data/docker-compose /home/cloud-compose/.docker/cli-plugins/docker-compose
fi

if [ ! -f "/home/cloud-compose/.docker/cli-plugins/docker-buildx" ]; then
    retry_until_success curl -sSL \
        https://github.com/docker/buildx/releases/download/v0.30.1/buildx-v0.30.1.linux-amd64 \
        -o /mnt/disks/data/docker-buildx
    chmod o+x /mnt/disks/data/docker-buildx
    ln -sf /mnt/disks/data/docker-buildx /home/cloud-compose/.docker/cli-plugins/docker-buildx
fi

if [ ! -f "/mnt/disks/data/make" ]; then
    # shellcheck disable=SC2016
    retry_until_success /usr/bin/docker run --rm \
        -v /mnt/disks/data:/out \
        alpine:3.22 \
        /bin/sh -euxc '
            MAKE_VERSION="4.4.1"
            MAKE_SHA256="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"

            apk add --no-cache build-base curl make tar
            curl -fsSL "https://ftp.gnu.org/gnu/make/make-${MAKE_VERSION}.tar.gz" -o /tmp/make.tar.gz
            echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -
            tar -xzf /tmp/make.tar.gz -C /tmp
            cd "/tmp/make-${MAKE_VERSION}"
            LDFLAGS="-static" ./configure --disable-nls
            make -j2
            cp make /out/make
        '
fi
chmod o+x /mnt/disks/data/make
ln -sf /mnt/disks/data/make /home/cloud-compose/bin/make
