#!/usr/bin/env bash

set -euo pipefail

if ((EUID != 0)); then
    echo "Cloud Compose bootstrap must run as root" >&2
    exit 1
fi

exec bash /home/cloud-compose/run.sh
