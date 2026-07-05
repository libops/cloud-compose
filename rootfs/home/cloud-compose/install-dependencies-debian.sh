#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

export DEBIAN_FRONTEND=noninteractive

retry_until_success apt-get update -qq
retry_until_success apt-get install -y \
    ca-certificates \
    curl \
    docker.io \
    git \
    jq \
    make

install -d /usr/local/lib/docker/cli-plugins
bash /home/cloud-compose/install-docker-plugins.sh

systemctl enable docker
