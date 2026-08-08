#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /etc/cloud-compose/libexec/bootstrap-security.sh

cloud_compose_bootstrap_require_root
if ! cloud_compose_bootstrap_marker_ready; then
    echo "Cloud Compose bootstrap readiness evidence is missing or invalid" >&2
    exit 1
fi
