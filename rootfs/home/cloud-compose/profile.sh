#!/usr/bin/env bash

decode_runtime_env_value() {
    local encoded="$1" output="" character next index
    for ((index = 0; index < ${#encoded}; index++)); do
        character="${encoded:index:1}"
        if [[ "$character" == '$' ]]; then
            [[ "${encoded:index+1:1}" == '$' ]] || return 1
            output+='$'
            ((index += 1))
        elif [[ "$character" == "\\" ]]; then
            next="${encoded:index+1:1}"
            case "$next" in
                "\\" | '"') output+="$next" ;;
                n) output+=$'\n' ;;
                r) output+=$'\r' ;;
                t) output+=$'\t' ;;
                *) return 1 ;;
            esac
            ((index += 1))
        elif [[ "$character" == '"' || "$character" == $'\r' || "$character" == $'\t' ]]; then
            return 1
        else
            output+="$character"
        fi
    done
    RUNTIME_ENV_DECODED="$output"
}

load_runtime_env() {
    local file="${1:-/home/cloud-compose/.env}" line name encoded
    [[ -f "$file" && ! -L "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$ ]] || return 1
        name="${BASH_REMATCH[1]}"
        encoded="${BASH_REMATCH[2]}"
        if ! decode_runtime_env_value "$encoded"; then
            echo "Invalid Cloud Compose environment encoding for $name" >&2
            return 1
        fi
        declare -gx -- "$name=$RUNTIME_ENV_DECODED"
    done <"$file"
}

load_runtime_env "${CLOUD_COMPOSE_ENV_FILE:-/home/cloud-compose/.env}" || {
    echo "Invalid or missing Cloud Compose environment" >&2
    return 1 2>/dev/null || exit 1
}

if ((EUID == 0)); then
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
    export PATH="/home/cloud-compose/bin:$PATH"
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/mnt/disks/data/docker-config}"

retry_until_success() {
    (($# > 0)) || return 2
    local max="${MAX_RETRIES:-10}" increment="${SLEEP_INCREMENT:-5}" attempt status
    [[ "$max" =~ ^[1-9][0-9]{0,2}$ && "$increment" =~ ^[0-9]{1,4}$ ]] || return 2
    ((10#$max <= 100 && 10#$increment <= 3600)) || return 2
    for ((attempt = 1; attempt <= max; attempt++)); do
        timeout 300 "$@" && return 0
        status=$?
        ((attempt == max)) && return "$status"
        sleep "$((increment * attempt))"
    done
}
