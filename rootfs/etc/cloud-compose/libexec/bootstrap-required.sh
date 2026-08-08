#!/usr/bin/env bash

set -uo pipefail

# shellcheck disable=SC1091
if ! source /etc/cloud-compose/libexec/bootstrap-security.sh; then
    echo "Cloud Compose bootstrap security helper could not be loaded" >&2
    exit 255
fi

if ! cloud_compose_bootstrap_require_root; then
    exit 255
fi
if cloud_compose_bootstrap_marker_ready; then
    # ExecCondition exit 1 skips an already-complete oneshot without marking it
    # failed. Missing or invalid evidence returns zero below and must converge.
    exit 1
fi
exit 0
