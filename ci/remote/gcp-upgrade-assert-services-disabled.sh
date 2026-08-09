#!/usr/bin/env bash

set -euo pipefail

for unit in \
    internal-services.timer \
    internal-services.service \
    cloud-compose-internal-services.timer \
    cloud-compose-internal-services.service; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "Fixture-only internal service remained active: $unit" >&2
        exit 1
    fi
done
