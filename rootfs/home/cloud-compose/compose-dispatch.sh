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

# The provider-neutral rollout service exports its first request argument as
# ROLLOUT_ARG1. Treat it as the optional manifest app key so one authenticated
# endpoint can safely target any app on a bin-packed host. The manifest lookup
# below remains the authority; arbitrary paths or compose project names are
# never accepted.
if [[ "$lifecycle" == "rollout" && -z "${CLOUD_COMPOSE_APP:-}" && -n "${ROLLOUT_ARG1:-}" ]]; then
    export CLOUD_COMPOSE_APP="$ROLLOUT_ARG1"
fi

apps=()
target_compose_apps_array "$lifecycle" apps
for app in "${apps[@]}"; do
    run_compose_app_lifecycle "$app" "$lifecycle"
done
