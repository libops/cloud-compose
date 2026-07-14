#!/usr/bin/env bash

set -euo pipefail

lifecycle="${1:-}"
if [ -z "$lifecycle" ]; then
    echo "usage: compose-dispatch.sh init|up|down|rollout" >&2
    exit 2
fi

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
# shellcheck disable=SC1091
source /home/cloud-compose/compose-apps.sh

case "$lifecycle" in
    init | up | down | rollout) ;;
    *)
        echo "unknown lifecycle: ${lifecycle}" >&2
        exit 2
        ;;
esac

acquire_cloud_compose_lifecycle_lock "$lifecycle"

apps=()
target_compose_apps_array "$lifecycle" apps
for app in "${apps[@]}"; do
    run_compose_app_lifecycle "$app" "$lifecycle"
done
