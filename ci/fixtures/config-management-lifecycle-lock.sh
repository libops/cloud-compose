#!/usr/bin/env bash

set -euo pipefail

action="${1:-}"
profile="${2:-}"

if [[ "$profile" != "/home/cloud-compose/profile.sh" || ! -f "$profile" || -L "$profile" ]]; then
    echo "config-management lifecycle-lock fixture requires the checked runtime profile" >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$profile"

case "$action" in
    hold)
        ready="${3:-}"
        [[ "$#" -eq 3 && "$ready" == /tmp/cloud-compose-lifecycle-lock-ready ]] || {
            echo "usage: config-management-lifecycle-lock.sh hold PROFILE READY" >&2
            exit 2
        }
        acquire_cloud_compose_lifecycle_lock root-first-contract
        touch -- "$ready"
        sleep 3
        release_cloud_compose_lifecycle_lock
        ;;
    contend)
        [[ "$#" -eq 2 ]] || {
            echo "usage: config-management-lifecycle-lock.sh contend PROFILE" >&2
            exit 2
        }
        acquire_cloud_compose_lifecycle_lock contention-contract
        ;;
    subshell)
        [[ "$#" -eq 2 ]] || {
            echo "usage: config-management-lifecycle-lock.sh subshell PROFILE" >&2
            exit 2
        }
        (
            acquire_cloud_compose_lifecycle_lock subshell-contract
            release_cloud_compose_lifecycle_lock
        )
        ;;
    reject-symlink)
        [[ "$#" -eq 2 ]] || {
            echo "usage: config-management-lifecycle-lock.sh reject-symlink PROFILE" >&2
            exit 2
        }
        acquire_cloud_compose_lifecycle_lock symlink-contract
        ;;
    *)
        echo "usage: config-management-lifecycle-lock.sh hold|contend|subshell|reject-symlink ..." >&2
        exit 2
        ;;
esac
