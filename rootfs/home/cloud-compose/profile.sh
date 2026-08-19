#!/usr/bin/env bash

_cc_profile_source="$(readlink -f -- "${BASH_SOURCE[0]}")" || {
    echo "Could not resolve the Cloud Compose profile path" >&2
    return 1 2>/dev/null || exit 1
}
_cc_profile_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    echo "Could not resolve the Cloud Compose profile directory" >&2
    return 1 2>/dev/null || exit 1
}
_cc_profile_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_profile_source _cc_profile_dir _cc_profile_installed_home
if [[ -n "$_cc_profile_installed_home" &&
    ( "$_cc_profile_installed_home" == "/" ||
        "$_cc_profile_source" == "${_cc_profile_installed_home%/}/"* ) ]]; then
    _cc_profile_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_profile_checked_programs="$_cc_profile_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_profile_checked_programs
# shellcheck disable=SC1090
if ! source "$_cc_profile_checked_programs"; then
    echo "Could not load the checked Cloud Compose program resolver" >&2
    return 1 2>/dev/null || exit 1
fi

decode_runtime_env_value() {
    local encoded="$1"
    local output="" character next index

    for ((index = 0; index < ${#encoded}; index++)); do
        character="${encoded:index:1}"
        if [[ "$character" != "\\" ]]; then
            if [[ "$character" == '$' ]]; then
                if ((index + 1 >= ${#encoded})) || [[ "${encoded:index+1:1}" != '$' ]]; then
                    echo "Unescaped dollar in cloud-compose environment value" >&2
                    return 1
                fi
                output+='$'
                ((index += 1))
                continue
            fi
            if [[ "$character" == '"' || "$character" == $'\r' || "$character" == $'\t' ]]; then
                echo "Unescaped character in cloud-compose environment value: $character" >&2
                return 1
            fi
            output+="$character"
            continue
        fi

        if ((index + 1 >= ${#encoded})); then
            echo "Invalid trailing escape in cloud-compose environment value" >&2
            return 1
        fi
        next="${encoded:index+1:1}"
        case "$next" in
            "\\" | '"')
                output+="$next"
                ((index += 1))
                ;;
            n)
                output+=$'\n'
                ((index += 1))
                ;;
            r)
                output+=$'\r'
                ((index += 1))
                ;;
            t)
                output+=$'\t'
                ((index += 1))
                ;;
            *)
                echo "Invalid escape in cloud-compose environment value: \\$next" >&2
                return 1
                ;;
        esac
    done

    RUNTIME_ENV_DECODED="$output"
}

write_runtime_env_assignment() {
    local name="$1"
    local value="$2"

    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid cloud-compose environment variable name: $name" >&2
        return 1
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\$\$}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s="%s"\n' "$name" "$value"
}

load_runtime_env() {
    local file="$1"
    local line name encoded

    if [[ ! -f "$file" ]]; then
        echo "cloud-compose environment file not found: $file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$ ]]; then
            echo "Invalid cloud-compose environment assignment" >&2
            return 1
        fi

        name="${BASH_REMATCH[1]}"
        encoded="${BASH_REMATCH[2]}"
        decode_runtime_env_value "$encoded" || return 1
        declare -gx -- "$name=$RUNTIME_ENV_DECODED" || return 1
    done <"$file"
}

if ! load_runtime_env "${CLOUD_COMPOSE_ENV_FILE:-/home/cloud-compose/.env}"; then
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return 1
    fi
    exit 1
fi

if ! cloud_compose_bind_program_dir \
    "$_cc_profile_source" \
    CLOUD_COMPOSE_JQ_PROGRAM_DIR \
    /etc/cloud-compose/jq \
    "$_cc_profile_dir/../../etc/cloud-compose/jq" \
    application-env-validate.jq \
    object-entries-sorted-base64.jq \
    object-field-delimited.jq; then
    return 1 2>/dev/null || exit 1
fi

if ((EUID == 0)); then
    # Root-owned systemd/bootstrap paths must never resolve commands from the
    # cloud-compose-writable tool directory.
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
    export PATH="/home/cloud-compose/bin:$PATH"
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/mnt/disks/data/docker-config}"

DEFAULT_MAX_RETRIES=10
DEFAULT_SLEEP_INCREMENT=5

# helper to wrap commands that go over the network in "exponential" backoff
# e.g. docker pull and git pull
retry_until_success() {
    if (($# == 0)); then
        echo "retry_until_success requires a command." >&2
        return 2
    fi
    local command_to_run=("$@")
    local operation="${1##*/}"
    local max_retries="${MAX_RETRIES:-$DEFAULT_MAX_RETRIES}"
    local sleep_increment="${SLEEP_INCREMENT:-$DEFAULT_SLEEP_INCREMENT}"
    local retries=0
    local exit_code

    if [[ ! "$max_retries" =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$max_retries > 100)); then
        echo "MAX_RETRIES must be an integer from 1 through 100." >&2
        return 2
    fi
    if [[ ! "$sleep_increment" =~ ^[0-9]{1,4}$ ]] || ((10#$sleep_increment > 3600)); then
        echo "SLEEP_INCREMENT must be an integer from 0 through 3600 seconds." >&2
        return 2
    fi

    while true; do
        exit_code=0
        timeout 300 "${command_to_run[@]}" || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            return 0
        fi

        retries=$((retries + 1))

        if [ "$retries" -ge "$max_retries" ]; then
            echo "FAILURE: Operation '$operation' failed after $max_retries attempts (last exit code: $exit_code)." >&2
            return 1
        fi

        local sleep_seconds=$((10#$sleep_increment * retries))
        echo "Operation '$operation' failed (exit code: $exit_code). Retrying in $sleep_seconds seconds... (attempt $retries/$max_retries)" >&2
        sleep "$sleep_seconds"
    done
}

# Serialize host lifecycle operations that can move a checkout, restart a
# Compose stack, or read a live database. systemd-tmpfiles creates this shared
# root/application lock before any privileged package update or app service.
acquire_cloud_compose_lifecycle_lock() {
    local operation="${1:-operation}"
    local lock_file="/run/lock/cloud-compose/lifecycle.lock"
    local timeout_seconds="${CLOUD_COMPOSE_LIFECYCLE_LOCK_TIMEOUT_SECONDS:-900}"
    local lock_parent lock_fd_path lock_identity

    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#$timeout_seconds > 43200)); then
        echo "CLOUD_COMPOSE_LIFECYCLE_LOCK_TIMEOUT_SECONDS must be an integer from 1 through 43200" >&2
        return 2
    fi
    if ! command -v flock >/dev/null 2>&1; then
        echo "flock is required to serialize cloud-compose lifecycle operations" >&2
        return 1
    fi

    lock_parent="$(dirname -- "$lock_file")"
    if [[ "$lock_parent" != "/run/lock/cloud-compose" || ! -d "$lock_parent" ||
        -L "$lock_parent" || -L "$lock_file" || ! -f "$lock_file" ]]; then
        echo "Unsafe cloud-compose lifecycle lock target: $lock_file" >&2
        return 1
    fi
    lock_identity="$(stat -Lc '%U:%G:%a' -- "$lock_parent" "$lock_file")" || return 1
    if [[ "$lock_identity" != $'root:cloud-compose:750\nroot:cloud-compose:660' ]]; then
        echo "Unsafe cloud-compose lifecycle lock ownership or mode: $lock_file" >&2
        return 1
    fi

    if ! exec 8<>"$lock_file"; then
        echo "Could not open shared cloud-compose lifecycle lock: $lock_file" >&2
        return 1
    fi
    lock_fd_path="/proc/${BASHPID}/fd/8"
    if [[ ! -f "$lock_fd_path" ]] ||
        [[ "$(stat -Lc '%d:%i' -- "$lock_fd_path")" != "$(stat -Lc '%d:%i' -- "$lock_file")" ]]; then
        echo "Cloud-compose lifecycle lock changed while opening: $lock_file" >&2
        exec 8>&-
        return 1
    fi
    if ! flock -w "$timeout_seconds" 8; then
        echo "Timed out waiting ${timeout_seconds}s for cloud-compose lifecycle lock during $operation" >&2
        exec 8>&-
        return 1
    fi
}

release_cloud_compose_lifecycle_lock() {
    if [[ -e /proc/${BASHPID}/fd/8 ]]; then
        flock -u 8 >/dev/null 2>&1 || true
        exec 8>&-
    fi
}

# Strictly update the host-owned cloud-compose environment contract.
update_runtime_env_file() (
    local env_file="$1"
    local name="$2"
    local value="$3"
    local line existing_name tmp_file

    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid cloud-compose environment variable name: $name" >&2
        return 1
    fi
    if [[ -L "$env_file" || ( -e "$env_file" && ! -f "$env_file" ) ]]; then
        echo "Refusing unsafe cloud-compose environment path: $env_file" >&2
        return 1
    fi

    umask 027
    tmp_file=$(mktemp "${env_file}.tmp.XXXXXXXXXX") || return 1
    trap 'rm -f -- "$tmp_file"' EXIT

    if [[ -f "$env_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ -z "$line" || "$line" == \#* ]]; then
                printf '%s\n' "$line" >>"$tmp_file"
                continue
            fi
            if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$ ]]; then
                echo "Invalid cloud-compose environment assignment" >&2
                return 1
            fi
            existing_name="${BASH_REMATCH[1]}"
            decode_runtime_env_value "${BASH_REMATCH[2]}" || return 1
            if [[ "$existing_name" != "$name" ]]; then
                printf '%s\n' "$line" >>"$tmp_file"
            fi
        done <"$env_file"
    fi

    write_runtime_env_assignment "$name" "$value" >>"$tmp_file" || return 1
    chmod 0640 "$tmp_file"
    mv -f -- "$tmp_file" "$env_file"
)

update_runtime_env() {
    update_runtime_env_file .env "$@"
}

# Compose application .env files use the broader Compose dotenv grammar and
# may be owned by downstream forks. Preserve their contents as opaque data and
# maintain one final, clearly marked override instead of parsing or sourcing
# untrusted application values.
update_compose_env() (
    local name="$1"
    local value="$2"
    local env_file=".env"
    local marker line managed_line tmp_file

    if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Invalid Compose environment variable name: $name" >&2
        return 1
    fi
    if [[ -L "$env_file" || ( -e "$env_file" && ! -f "$env_file" ) ]]; then
        echo "Refusing unsafe Compose environment path: $env_file" >&2
        return 1
    fi

    marker="# cloud-compose managed: ${name}"
    umask 027
    tmp_file=$(mktemp "${env_file}.tmp.XXXXXXXXXX") || return 1
    trap 'rm -f -- "$tmp_file"' EXIT

    if [[ -f "$env_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "$marker" ]]; then
                if ! IFS= read -r managed_line; then
                    echo "Incomplete managed Compose environment assignment for $name" >&2
                    return 1
                fi
                if [[ ! "$managed_line" =~ ^${name}=\".*\"$ ]]; then
                    echo "Invalid managed Compose environment assignment for $name" >&2
                    return 1
                fi
                continue
            fi
            printf '%s\n' "$line" >>"$tmp_file"
        done <"$env_file"
    fi

    printf '%s\n' "$marker" >>"$tmp_file"
    write_runtime_env_assignment "$name" "$value" >>"$tmp_file" || return 1
    chmod 0640 "$tmp_file"
    mv -f -- "$tmp_file" "$env_file"
)

# Reconcile application-only tuning values into the current Compose project's
# dotenv file. The JSON file is parsed as data and is never exported into the
# host process environment. A distinct marker lets later runs remove values
# that were deleted from runtime.extra_env while preserving downstream dotenv
# syntax and cloud-compose's final control-plane overrides.
sync_compose_application_env() (
    local application_env_file="${1:-${CLOUD_COMPOSE_APPLICATION_ENV_FILE:-/home/cloud-compose/application-env.json}}"
    local env_file=".env"
    local entries_file tmp_file line managed_line application_name encoded entry_json name value

    if [[ -L "$application_env_file" || ! -f "$application_env_file" ]]; then
        echo "Compose application environment file is missing or unsafe: $application_env_file" >&2
        return 1
    fi
    if [[ -L "$env_file" || ( -e "$env_file" && ! -f "$env_file" ) ]]; then
        echo "Refusing unsafe Compose environment path: $env_file" >&2
        return 1
    fi
    if ! jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/application-env-validate.jq" \
        "$application_env_file" >/dev/null; then
        echo "Invalid Compose application environment data: $application_env_file" >&2
        return 1
    fi

    umask 027
    entries_file=$(mktemp "${TMPDIR:-/tmp}/cloud-compose-application-env.XXXXXXXXXX") || return 1
    tmp_file=$(mktemp "${env_file}.tmp.XXXXXXXXXX") || {
        rm -f -- "$entries_file"
        return 1
    }
    trap 'rm -f -- "$entries_file" "$tmp_file"' EXIT

    jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-entries-sorted-base64.jq" \
        "$application_env_file" >"$entries_file" || return 1

    if [[ -f "$env_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^\#\ cloud-compose\ application:\ ([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
                application_name="${BASH_REMATCH[1]}"
                if ! IFS= read -r managed_line; then
                    echo "Incomplete Compose application environment assignment for $application_name" >&2
                    return 1
                fi
                if [[ ! "$managed_line" =~ ^${application_name}=\".*\"$ ]]; then
                    echo "Invalid Compose application environment assignment for $application_name" >&2
                    return 1
                fi
                continue
            fi
            printf '%s\n' "$line" >>"$tmp_file"
        done <"$env_file"
    fi

    while IFS= read -r encoded || [[ -n "$encoded" ]]; do
        [[ -n "$encoded" ]] || continue
        entry_json="$(printf '%s' "$encoded" | base64 -d)" || return 1
        name="$(jq -jr --arg field key \
            -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-field-delimited.jq" \
            <<<"$entry_json")" || return 1
        name="${name%$'\x1f'}"
        if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Invalid Compose application environment data: $application_env_file" >&2
            return 1
        fi
        value="$(jq -jr --arg field value \
            -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-field-delimited.jq" \
            <<<"$entry_json")" || return 1
        value="${value%$'\x1f'}"
        printf '# cloud-compose application: %s\n' "$name" >>"$tmp_file"
        write_runtime_env_assignment "$name" "$value" >>"$tmp_file" || return 1
    done <"$entries_file"

    chmod 0640 "$tmp_file"
    mv -f -- "$tmp_file" "$env_file"
)

# Backward-compatible helper name used by older rootfs extensions.
update_env() {
    update_compose_env "$@"
}
