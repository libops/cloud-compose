#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

install -d /usr/local/lib/docker/cli-plugins
bash /home/cloud-compose/install-docker-plugins.sh

packages=()
for package in git jq make openssl; do
    if ! rpm -q "$package" >/dev/null 2>&1; then
        packages+=("$package")
    fi
done

if [ "${#packages[@]}" -gt 0 ]; then
    rpm-ostree install --apply-live "${packages[@]}"
fi
