#!/usr/bin/env bash

set -euo pipefail

_cc_assert_initialized_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_assert_initialized_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_assert_initialized_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_assert_initialized_source _cc_assert_initialized_dir _cc_assert_initialized_installed_home
if [[ -n "$_cc_assert_initialized_installed_home" &&
    ( "$_cc_assert_initialized_installed_home" == "/" ||
        "$_cc_assert_initialized_source" == "${_cc_assert_initialized_installed_home%/}/"* ) ]]; then
    _cc_assert_initialized_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_assert_initialized_checked_programs="$_cc_assert_initialized_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_assert_initialized_checked_programs
# shellcheck disable=SC1090
source "$_cc_assert_initialized_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_assert_initialized_source" CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH \
    /home/cloud-compose/bootstrap-helpers.sh "$_cc_assert_initialized_dir/bootstrap-helpers.sh"
bootstrap_helpers_path="$CLOUD_COMPOSE_BOOTSTRAP_HELPERS_PATH"
readonly bootstrap_helpers_path

# shellcheck disable=SC1090
source "$bootstrap_helpers_path"

durable_marker="${CLOUD_COMPOSE_BOOTSTRAP_COMPLETE_MARKER:-/var/lib/cloud-compose/bootstrap-complete}"
boot_marker="${CLOUD_COMPOSE_APP_INIT_MARKER:-/run/cloud-compose-app-init-complete}"

if cloud_compose_marker_exists "$durable_marker" ||
    cloud_compose_marker_exists "$boot_marker"; then
    exit 0
fi

echo "Cloud Compose application initialization has not completed for this boot" >&2
exit 1
