#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

mkdir -p "${DOCKER_CONFIG}/cli-plugins" /home/cloud-compose/.docker/cli-plugins /home/cloud-compose/bin /mnt/disks/data
DOCKER_CLI_PLUGIN_DIR="${DOCKER_CONFIG}/cli-plugins" \
    bash /home/cloud-compose/install-docker-plugins.sh
DOCKER_CLI_PLUGIN_DIR=/home/cloud-compose/.docker/cli-plugins \
    bash /home/cloud-compose/install-docker-plugins.sh
chown -R cloud-compose:cloud-compose "$DOCKER_CONFIG" /home/cloud-compose/.docker /home/cloud-compose/bin

if [ ! -f "/mnt/disks/data/make" ]; then
    # COS can start Docker before bridge egress is reliable; this bootstrap container does not run app code.
    # shellcheck disable=SC2016
    retry_until_success /usr/bin/docker run --rm \
        --network host \
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
chmod a+x /mnt/disks/data/make
ln -sf /mnt/disks/data/make /home/cloud-compose/bin/make
