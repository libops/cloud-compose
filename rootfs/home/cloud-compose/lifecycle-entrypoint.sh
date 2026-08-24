#!/usr/bin/env bash

set -euo pipefail

lifecycle="${0##*/}"
case "$lifecycle" in
    init | up | down | rollout) ;;
    *)
        echo "lifecycle entrypoint must be installed as init, up, down, or rollout" >&2
        exit 2
        ;;
esac

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

if [[ "$lifecycle" == "rollout" && -z "${CLOUD_COMPOSE_APP:-}" && -n "${ROLLOUT_ARG1:-}" ]]; then
    export CLOUD_COMPOSE_APP="$ROLLOUT_ARG1"
fi

exec sitectl host apps lifecycle "$lifecycle"
