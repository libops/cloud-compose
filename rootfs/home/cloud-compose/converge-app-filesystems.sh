#!/usr/bin/env bash

set -euo pipefail

_cc_converge_app_filesystems_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_converge_app_filesystems_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_converge_app_filesystems_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_converge_app_filesystems_source _cc_converge_app_filesystems_dir _cc_converge_app_filesystems_installed_home
if [[ -n "$_cc_converge_app_filesystems_installed_home" &&
    ( "$_cc_converge_app_filesystems_installed_home" == "/" ||
        "$_cc_converge_app_filesystems_source" == "${_cc_converge_app_filesystems_installed_home%/}/"* ) ]]; then
    _cc_converge_app_filesystems_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_converge_app_filesystems_checked_programs="$_cc_converge_app_filesystems_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_converge_app_filesystems_checked_programs
# shellcheck disable=SC1090
source "$_cc_converge_app_filesystems_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_converge_app_filesystems_source" \
    CLOUD_COMPOSE_PROFILE_PATH \
    /home/cloud-compose/profile.sh \
    "$_cc_converge_app_filesystems_dir/profile.sh"
cloud_compose_bind_source_program \
    "$_cc_converge_app_filesystems_source" \
    CLOUD_COMPOSE_COMPOSE_APPS_PATH \
    /home/cloud-compose/compose-apps.sh \
    "$_cc_converge_app_filesystems_dir/compose-apps.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
compose_apps_path="$CLOUD_COMPOSE_COMPOSE_APPS_PATH"
readonly profile_path compose_apps_path

if ((EUID != 0)); then
    echo "Compose application filesystem convergence must run as root" >&2
    exit 1
fi

cd "$_cc_converge_app_filesystems_dir"
# shellcheck disable=SC1090
source "$profile_path"
# shellcheck disable=SC1090
source "$compose_apps_path"

apps=()
compose_app_names_array apps
for app in "${apps[@]}"; do
    converge_compose_app_filesystem "$app"
done
