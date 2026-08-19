#!/usr/bin/env bash

set -euo pipefail

_cc_start_bootstrap_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_start_bootstrap_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_start_bootstrap_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_start_bootstrap_source _cc_start_bootstrap_dir _cc_start_bootstrap_installed_home
if [[ -n "$_cc_start_bootstrap_installed_home" &&
    ( "$_cc_start_bootstrap_installed_home" == "/" ||
        "$_cc_start_bootstrap_source" == "${_cc_start_bootstrap_installed_home%/}/"* ) ]]; then
    _cc_start_bootstrap_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_start_bootstrap_checked_programs="$_cc_start_bootstrap_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_start_bootstrap_checked_programs
# shellcheck disable=SC1090
source "$_cc_start_bootstrap_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_start_bootstrap_source" CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH \
    /home/cloud-compose/bootstrap-helpers.sh "$_cc_start_bootstrap_dir/bootstrap-helpers.sh"
bootstrap_helpers_path="$CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH"
readonly bootstrap_helpers_path

# shellcheck disable=SC1090
source "$bootstrap_helpers_path"

durable_marker="${CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER:-/var/lib/cloud-compose/bootstrap-complete}"
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
