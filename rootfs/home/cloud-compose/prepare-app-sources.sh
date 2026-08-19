#!/usr/bin/env bash

set -euo pipefail

_cc_prepare_sources_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_prepare_sources_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_prepare_sources_source script_dir _cc_prepare_sources_installed_home
if [[ -n "$_cc_prepare_sources_installed_home" &&
    ( "$_cc_prepare_sources_installed_home" == "/" ||
        "$_cc_prepare_sources_source" == "${_cc_prepare_sources_installed_home%/}/"* ) ]]; then
    _cc_prepare_sources_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_prepare_sources_checked_programs="$script_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_prepare_sources_checked_programs
# shellcheck disable=SC1090
source "$_cc_prepare_sources_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_prepare_sources_source" CLOUD_COMPOSE_PROFILE_PATH \
    /home/cloud-compose/profile.sh "$script_dir/profile.sh"
cloud_compose_bind_source_program \
    "$_cc_prepare_sources_source" CLOUD_COMPOSE_COMPOSE_APPS_PATH \
    /home/cloud-compose/compose-apps.sh "$script_dir/compose-apps.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
compose_apps_path="$CLOUD_COMPOSE_COMPOSE_APPS_PATH"
readonly profile_path compose_apps_path
cd "$script_dir"
# shellcheck disable=SC1090
source "$profile_path"
# Reload the fixed resolver before sourcing the Compose library.
# shellcheck disable=SC1090
source "$_cc_prepare_sources_checked_programs"
# shellcheck disable=SC1090
source "$compose_apps_path"

apps=()
compose_app_names_array apps
for app in "${apps[@]}"; do
    # This phase performs source validation and checkout only. Application
    # scaffold/plugin lifecycle commands must wait for Vault readiness.
    clone_or_update_compose_app "$app"
done
