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
exec bash /home/cloud-compose/compose-dispatch.sh "$lifecycle"
