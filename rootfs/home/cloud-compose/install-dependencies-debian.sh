#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

export DEBIAN_FRONTEND=noninteractive

retry_until_success apt-get update -qq
packages=(
    ca-certificates
    curl
    git
    jq
    make
    openssl
)

# Ubuntu's docker.io depends on the distribution containerd package, which
# conflicts with Docker CE's containerd.io. Reused images that already provide
# a working Docker CLI must retain their existing, compatible Docker toolchain.
if ! command -v docker >/dev/null 2>&1; then
    packages+=(docker.io)
fi

retry_until_success apt-get install -y "${packages[@]}"

install -d /usr/local/lib/docker/cli-plugins
bash /home/cloud-compose/install-docker-plugins.sh

systemctl enable docker
