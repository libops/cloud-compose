#!/usr/bin/env bash

set -euo pipefail

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
fi

os_id="${ID:-unknown}"
os_id_like="${ID_LIKE:-}"
variant_id="${VARIANT_ID:-}"

case "$os_id:$variant_id:$os_id_like" in
    cos:*:*)
        exec bash /home/cloud-compose/install-dependencies-cos.sh
        ;;
    *:coreos:* | fedora:*:*)
        if command -v rpm-ostree >/dev/null 2>&1; then
            exec bash /home/cloud-compose/install-dependencies-coreos.sh
        fi
        ;;
    debian:*:* | ubuntu:*:* | *:*:*debian*)
        exec bash /home/cloud-compose/install-dependencies-debian.sh
        ;;
esac

echo "Unsupported OS for cloud-compose dependency installation: ID=${os_id} VARIANT_ID=${variant_id} ID_LIKE=${os_id_like}" >&2
exit 1
