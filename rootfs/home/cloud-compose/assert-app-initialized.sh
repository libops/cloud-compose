#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1090
source "${CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH:-/home/cloud-compose/bootstrap-helpers.sh}"

durable_marker="${CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER:-/var/lib/cloud-compose/bootstrap-complete}"
boot_marker="${CLOUD_COMPOSE_APP_INIT_MARKER:-/run/cloud-compose-app-init-complete}"

if cloud_compose_marker_exists "$durable_marker" ||
    cloud_compose_marker_exists "$boot_marker"; then
    exit 0
fi

echo "Cloud Compose application initialization has not completed for this boot" >&2
exit 1
