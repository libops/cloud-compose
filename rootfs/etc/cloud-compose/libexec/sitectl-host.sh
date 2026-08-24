#!/usr/bin/env bash

set -euo pipefail

# The installed profile is root-owned before any service uses this launcher.
# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

sitectl=/home/cloud-compose/bin/sitectl
if ((EUID == 0)) && [[ -x /etc/cloud-compose/bin/bootstrap-sitectl && ! -L /etc/cloud-compose/bin/bootstrap-sitectl ]]; then
    sitectl=/etc/cloud-compose/bin/bootstrap-sitectl
fi
[[ -x "$sitectl" ]] || {
    echo "Verified sitectl is not installed" >&2
    exit 1
}

exec "$sitectl" host "$@"
