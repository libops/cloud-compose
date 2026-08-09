#!/usr/bin/env bash

readonly CLOUD_COMPOSE_BOOTSTRAP_MARKER="/var/lib/cloud-compose/bootstrap-complete"
readonly CLOUD_COMPOSE_RUNTIME_HOME="/home/cloud-compose"

cloud_compose_bootstrap_require_root() {
    if ((EUID != 0)); then
        echo "Cloud Compose bootstrap control must run as root" >&2
        return 1
    fi
}

cloud_compose_bootstrap_marker_ready() {
    local marker="${1:-$CLOUD_COMPOSE_BOOTSTRAP_MARKER}"
    local marker_dir marker_dir_metadata marker_metadata marker_size payload

    marker_dir="$(dirname -- "$marker")"
    [[ -d "$marker_dir" && ! -L "$marker_dir" && -f "$marker" && ! -L "$marker" ]] || return 1
    marker_dir_metadata="$(stat -c '%u:%g:%a:%F' -- "$marker_dir")" || return 1
    marker_metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$marker")" || return 1
    marker_size="$(stat -c '%s' -- "$marker")" || return 1
    [[ "$marker_dir_metadata" == "0:0:755:directory" &&
        "$marker_metadata" == "0:0:644:1:regular file" &&
        "$marker_size" == "6" ]] || return 1
    IFS= read -r payload <"$marker" || return 1
    [[ "$payload" == "ready" ]]
}

cloud_compose_secure_runtime_home() {
    local home_metadata program dispatcher metadata owner_uid group_gid mode links kind
    local -a required_programs programs dispatchers control_inputs

    cloud_compose_bootstrap_require_root || return 1
    if [[ -L "$CLOUD_COMPOSE_RUNTIME_HOME" || ! -d "$CLOUD_COMPOSE_RUNTIME_HOME" ]]; then
        echo "Cloud Compose runtime home is missing or redirected" >&2
        return 1
    fi
    home_metadata="$(stat -c '%a:%F' -- "$CLOUD_COMPOSE_RUNTIME_HOME")" || return 1
    if [[ ! "$home_metadata" =~ ^[0-7]{3,4}:directory$ ]]; then
        echo "Cloud Compose runtime home is not a real directory" >&2
        return 1
    fi

    # Close the historical user-owned parent boundary before inspecting any
    # program beneath it. A replacement file retains its non-root ownership and
    # is rejected below; a now-unwritable parent prevents another replacement.
    chown 0:0 "$CLOUD_COMPOSE_RUNTIME_HOME" || return 1
    chmod 0755 "$CLOUD_COMPOSE_RUNTIME_HOME" || return 1

    required_programs=(
        "$CLOUD_COMPOSE_RUNTIME_HOME/run.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/profile.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/bootstrap-helpers.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/host-conf.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/host-init.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/converge-app-filesystems.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/default-lifecycle.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/prepare-app-sources.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/rotate-keys-daily.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/vault-agent-init.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/app-init.sh"
        "$CLOUD_COMPOSE_RUNTIME_HOME/init"
        "$CLOUD_COMPOSE_RUNTIME_HOME/up"
        "$CLOUD_COMPOSE_RUNTIME_HOME/down"
        "$CLOUD_COMPOSE_RUNTIME_HOME/rollout"
    )
    for program in "${required_programs[@]}"; do
        if [[ -L "$program" || ! -f "$program" ]]; then
            echo "Required Cloud Compose bootstrap program is missing or redirected: $program" >&2
            return 1
        fi
    done

    shopt -s nullglob
    programs=("$CLOUD_COMPOSE_RUNTIME_HOME"/*.sh)
    shopt -u nullglob
    for program in "${programs[@]}"; do
        if [[ -L "$program" || ! -f "$program" ]]; then
            echo "Cloud Compose bootstrap program is not a regular file: $program" >&2
            return 1
        fi
        metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$program")" || return 1
        IFS=: read -r owner_uid group_gid mode links kind <<<"$metadata"
        if [[ "$owner_uid" != "0" || "$group_gid" != "0" || "$links" != "1" || "$kind" != "regular file" ||
            ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
            echo "Cloud Compose bootstrap program is not root-controlled: $program" >&2
            return 1
        fi
        chown 0:0 "$program" || return 1
        chmod 0755 "$program" || return 1
    done

    control_inputs=(
        "$CLOUD_COMPOSE_RUNTIME_HOME/.env"
        "$CLOUD_COMPOSE_RUNTIME_HOME/compose-projects.json"
        "$CLOUD_COMPOSE_RUNTIME_HOME/application-env.json"
        "$CLOUD_COMPOSE_RUNTIME_HOME/managed-runtime-artifacts.tsv"
    )
    for program in "${control_inputs[@]}"; do
        if [[ -L "$program" || ! -f "$program" ]]; then
            echo "Required Cloud Compose control input is missing or redirected: $program" >&2
            return 1
        fi
        metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$program")" || return 1
        IFS=: read -r owner_uid group_gid mode links kind <<<"$metadata"
        if [[ "$owner_uid" != "0" || "$links" != "1" || "$kind" != "regular file" ||
            ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
            echo "Cloud Compose control input is not root-controlled: $program" >&2
            return 1
        fi
    done

    dispatchers=(init up down rollout)
    for dispatcher in "${dispatchers[@]}"; do
        program="$CLOUD_COMPOSE_RUNTIME_HOME/$dispatcher"
        metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$program")" || return 1
        IFS=: read -r owner_uid group_gid mode links kind <<<"$metadata"
        if [[ "$owner_uid" != "0" || "$links" != "1" || "$kind" != "regular file" ||
            ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
            echo "Cloud Compose lifecycle dispatcher is not root-controlled: $program" >&2
            return 1
        fi
    done
}
