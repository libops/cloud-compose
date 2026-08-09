#!/usr/bin/env bash

set -euo pipefail

validate_only=false
if [[ "${1:-}" == "--validate" ]]; then
    validate_only=true
    shift
fi

if [[ "$#" -ne 2 ]]; then
    echo "usage: run-lifecycle-program.sh [--validate] LIFECYCLE PROGRAM" >&2
    exit 2
fi

lifecycle="$1"
entry="$2"
case "$lifecycle" in
    init | up | down | rollout) ;;
    *)
        echo "Unsupported Cloud Compose lifecycle: $lifecycle" >&2
        exit 2
        ;;
esac

case "$entry" in
    true)
        exit 0
        ;;
    false)
        [[ "$validate_only" == "true" ]] && exit 0
        exit 1
        ;;
    "/home/cloud-compose/default-lifecycle.sh $lifecycle")
        program=/home/cloud-compose/default-lifecycle.sh
        program_args=("$lifecycle")
        ;;
    *)
        program_dir="${CLOUD_COMPOSE_LIFECYCLE_PROGRAM_DIR:-/etc/cloud-compose/lifecycle.d}"
        if [[ "$program_dir" != /* || "$program_dir" == "/" ||
            "$program_dir" == *$'\n'* || "$program_dir" == *$'\r'* ||
            "$program_dir" =~ (^|/)\.\.?(/|$) ]]; then
            echo "Unsafe Cloud Compose lifecycle program directory: $program_dir" >&2
            exit 2
        fi
        program_name="${entry#"$program_dir"/}"
        if [[ "$entry" != "$program_dir/"* || "$program_name" == */* ||
            ! "$program_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "Lifecycle entries must name one checked program in ${program_dir}: $entry" >&2
            exit 2
        fi
        program="$entry"
        program_args=()
        ;;
esac

executor_uid="$(stat -c '%u' -- "${BASH_SOURCE[0]}")"
program_parent="$(dirname -- "$program")"
if [[ -L "$program_parent" || ! -d "$program_parent" || -L "$program" || ! -f "$program" ]]; then
    echo "Lifecycle program is missing or redirected: $program" >&2
    exit 1
fi
parent_metadata="$(stat -c '%u:%a:%F' -- "$program_parent")"
program_metadata="$(stat -c '%u:%a:%h:%F' -- "$program")"
IFS=: read -r parent_uid parent_mode parent_kind <<<"$parent_metadata"
IFS=: read -r program_uid program_mode program_links program_kind <<<"$program_metadata"
if [[ "$parent_uid" != "$executor_uid" || "$parent_kind" != "directory" ||
    ! "$parent_mode" =~ ^[0-7]{3,4}$ || $((8#$parent_mode & 0022)) -ne 0 ]]; then
    echo "Lifecycle program directory is not controlled by the executor owner: $program_parent" >&2
    exit 1
fi
if [[ "$program_uid" != "$executor_uid" || "$program_links" != "1" ||
    "$program_kind" != "regular file" || ! "$program_mode" =~ ^[0-7]{3,4}$ ||
    $((8#$program_mode & 0122)) -ne 0100 ]]; then
    echo "Lifecycle program is not an unlinked owner-executable file controlled by the executor owner: $program" >&2
    exit 1
fi

if [[ "$validate_only" == "true" ]]; then
    exit 0
fi

exec "$program" "${program_args[@]}"
