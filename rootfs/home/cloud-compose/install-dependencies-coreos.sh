#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

install -d /etc/yum.repos.d /usr/local/lib/docker/cli-plugins
cat >/etc/yum.repos.d/sitectl.repo <<'EOF'
[sitectl]
name=sitectl
baseurl=https://packages.libops.io/sitectl/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://packages.libops.io/sitectl/sitectl-archive-keyring.asc
EOF

bash /home/cloud-compose/install-docker-plugins.sh

packages=()
for package in git jq make; do
    if ! rpm -q "$package" >/dev/null 2>&1; then
        packages+=("$package")
    fi
done

for package in ${SITECTL_PACKAGES:-sitectl}; do
    if [ -n "$package" ] && ! rpm -q "$package" >/dev/null 2>&1; then
        packages+=("$package")
    fi
done

if [ "${#packages[@]}" -gt 0 ]; then
    rpm-ostree install --apply-live "${packages[@]}"
fi
