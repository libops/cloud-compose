#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1090
source "${CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH:-/home/cloud-compose/bootstrap-helpers.sh}"

durable_marker="${CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER:-/home/cloud-compose/.cloud-compose-bootstrap-complete}"
wait_seconds="${CLOUD_COMPOSE_BOOTSTRAP_WAIT_SECONDS:-10800}"
bootstrap_unit="cloud-compose-bootstrap.service"

if cloud_compose_marker_exists "$durable_marker"; then
    exit 0
fi

systemctl daemon-reload
active_state="$(systemctl show --property=ActiveState --value -- "$bootstrap_unit")"
if [[ "$active_state" == "active" ]] &&
    ! cloud_compose_marker_exists "$durable_marker"; then
    # RemainAfterExit keeps a completed oneshot active. Configuration
    # management deliberately removes the durable marker when reviewed inputs
    # change, so restart that stale active instance rather than treating it as
    # an in-flight bootstrap.
    systemctl stop -- "$bootstrap_unit"
fi
cloud_compose_start_and_wait_for_oneshot "$bootstrap_unit" "$wait_seconds"
if ! cloud_compose_marker_exists "$durable_marker"; then
    echo "Cloud Compose bootstrap service became active without publishing readiness" >&2
    exit 1
fi
