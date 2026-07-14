#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
compose_apps_path="${CLOUD_COMPOSE_COMPOSE_APPS_PATH:-$script_dir/compose-apps.sh}"
cd "$script_dir"
# shellcheck disable=SC1090
source "$profile_path"
# shellcheck disable=SC1090
source "$compose_apps_path"

apps=()
compose_app_names_array apps
for app in "${apps[@]}"; do
    # This phase performs source validation and checkout only. Application
    # scaffold/plugin lifecycle commands must wait for Vault readiness.
    clone_or_update_compose_app "$app"
done
