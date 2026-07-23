#!/usr/bin/env bash

set -euo pipefail

if ((EUID != 0)); then
    echo "Compose application filesystem convergence must run as root" >&2
    exit 1
fi

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
    converge_compose_app_filesystem "$app"
done
