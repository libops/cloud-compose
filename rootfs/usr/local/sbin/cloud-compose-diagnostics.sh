#!/bin/bash

set -euo pipefail

# This program is reached through an exact sudoers command. Never resolve its
# child commands from a caller-controlled tool directory.
readonly PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

readonly bootstrap_marker="/var/lib/cloud-compose/bootstrap-complete"
readonly diagnostics_program="/usr/local/sbin/cloud-compose-diagnostics.sh"
readonly jq_program_dir="/usr/local/share/cloud-compose/jq"
readonly process_pattern='[/]home/cloud-compose/run[.]sh|[/]home/cloud-compose/[h]ost-conf[.]sh|[/]home/cloud-compose/[h]ost-init[.]sh|[/]home/cloud-compose/[a]pp-init[.]sh|[/]home/cloud-compose/[i]nstall-dependencies|[a]pt-get|[r]pm-ostree|[d]ocker run|[s]itectl|[g]it clone'

usage() {
    echo "usage: ${diagnostics_program} state|status|dump" >&2
}

require_root() {
    if ((EUID != 0)); then
        echo "Cloud Compose diagnostics must run as root" >&2
        exit 1
    fi
}

unit_value() {
    local unit="$1" property="$2" value

    value="$(systemctl show --property="$property" --value -- "$unit" 2>/dev/null || true)"
    printf '%s\n' "${value:-unknown}"
}

bootstrap_state() {
    local bootstrap_load_state bootstrap_active_state bootstrap_sub_state
    local marker_dir_metadata marker_metadata marker_size marker_payload

    if [[ -f "$bootstrap_marker" && ! -L "$bootstrap_marker" ]]; then
        marker_dir_metadata="$(stat -c '%u:%g:%a:%F' -- "$(dirname -- "$bootstrap_marker")" 2>/dev/null || true)"
        marker_metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$bootstrap_marker" 2>/dev/null || true)"
        marker_size="$(stat -c '%s' -- "$bootstrap_marker" 2>/dev/null || true)"
        marker_payload=""
        IFS= read -r marker_payload <"$bootstrap_marker" || true
        if [[ "$marker_dir_metadata" == "0:0:755:directory" &&
            "$marker_metadata" == "0:0:644:1:regular file" &&
            "$marker_size" == "6" && "$marker_payload" == "ready" ]]; then
            echo complete
            return 0
        fi
    fi

    bootstrap_load_state="$(unit_value cloud-compose-bootstrap.service LoadState)"
    if [[ "$bootstrap_load_state" == "loaded" ]]; then
        bootstrap_active_state="$(unit_value cloud-compose-bootstrap.service ActiveState)"
        bootstrap_sub_state="$(unit_value cloud-compose-bootstrap.service SubState)"
        case "${bootstrap_active_state}:${bootstrap_sub_state}" in
            active:* | activating:* | *:auto-restart)
                echo active
                return 0
                ;;
        esac
    elif [[ "$bootstrap_load_state" == "not-found" ]] &&
        systemctl is-active --quiet cloud-compose.service; then
        # Compatibility with releases that predate the retryable bootstrap
        # unit and durable readiness marker.
        echo complete
        return 0
    fi

    if systemctl is-active --quiet cloud-final.service; then
        echo active
        return 0
    fi
    if pgrep -f -- "$process_pattern" >/dev/null; then
        echo active
        return 0
    fi

    echo idle
    return 1
}

unit_heartbeat() {
    local unit main_pid

    for unit in cloud-final.service cloud-compose-bootstrap.service cloud-compose.service; do
        echo "--- ${unit} state ---"
        systemctl show --no-pager \
            --property=LoadState \
            --property=ActiveState \
            --property=SubState \
            --property=Result \
            --property=MainPID \
            --property=ExecMainStatus \
            -- "$unit" 2>&1 || true
        main_pid="$(unit_value "$unit" MainPID)"
        if [[ "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
            ps -p "$main_pid" -o pid=,ppid=,stat=,etime=,comm= 2>/dev/null || true
        fi
    done

    echo "--- active bootstrap process state ---"
    while IFS= read -r process_id; do
        [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || continue
        ps -p "$process_id" -o pid=,ppid=,stat=,etime=,comm= 2>/dev/null || true
    done < <(pgrep -f -- "$process_pattern" 2>/dev/null || true)
}

diagnostic_status() {
    local cloud_init_status=0 state

    echo "--- Cloud Compose provisioning heartbeat ---"
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    echo "--- cloud-init status ---"
    if command -v cloud-init >/dev/null 2>&1; then
        cloud-init status --long || cloud_init_status=$?
    else
        echo "cloud-init not installed"
    fi
    unit_heartbeat
    state="$(bootstrap_state 2>/dev/null || true)"
    echo "bootstrap-state: ${state:-unknown}"
    return "$cloud_init_status"
}

tail_regular_file() {
    local label="$1" path="$2" lines="$3"

    echo "--- ${label} ---"
    if [[ -f "$path" && ! -L "$path" ]]; then
        tail -n "$lines" -- "$path" 2>&1 || true
    else
        echo "${label} is not present as a regular file"
    fi
}

dump_compose_state() {
    local manifest="/home/cloud-compose/compose-projects.json"
    local docker_path encoded row app project_dir

    echo "--- docker ps ---"
    docker_path="$(command -v docker || true)"
    if [[ -z "$docker_path" ]]; then
        echo "docker is not installed"
        return 0
    fi
    "$docker_path" ps -a 2>&1 || true

    echo "--- docker compose project state ---"
    if [[ ! -f "$manifest" || -L "$manifest" ]] ||
        ! jq -e -f "$jq_program_dir/diagnostics-validate-compose-projects.jq" \
            "$manifest" >/dev/null 2>&1; then
        echo "Compose project manifest is unavailable or invalid"
        return 0
    fi

    while IFS= read -r encoded; do
        [[ -n "$encoded" ]] || continue
        row="$(printf '%s' "$encoded" | base64 -d)" || continue
        app="$(jq -er -f "$jq_program_dir/diagnostics-entry-app.jq" <<<"$row" 2>/dev/null || true)"
        project_dir="$(jq -er -f "$jq_program_dir/diagnostics-entry-project-dir.jq" <<<"$row" 2>/dev/null || true)"
        if [[ -z "$app" || -z "$project_dir" || ! -d "$project_dir" || -L "$project_dir" ]]; then
            echo "Skipping unavailable or unsafe Compose project: ${app:-unknown}"
            continue
        fi
        echo "--- docker compose ps: ${app} ---"
        runuser -u cloud-compose -- env HOME=/home/cloud-compose \
            "$docker_path" compose --project-directory "$project_dir" ps 2>&1 || true
    done < <(jq -r -f "$jq_program_dir/diagnostics-project-entries.jq" "$manifest")
}

diagnostic_dump() {
    diagnostic_status || true
    tail_regular_file "/var/log/cloud-init-output.log" "/var/log/cloud-init-output.log" 400
    tail_regular_file "/var/log/cloud-init.log" "/var/log/cloud-init.log" 400
    echo "--- cloud-init runcmd ---"
    if [[ -f /var/lib/cloud/instance/scripts/runcmd &&
        ! -L /var/lib/cloud/instance/scripts/runcmd ]]; then
        sed -n '1,240p' /var/lib/cloud/instance/scripts/runcmd 2>&1 || true
    else
        echo "cloud-init runcmd is not present as a regular file"
    fi
    echo "--- cloud-compose bootstrap unit ---"
    journalctl -u cloud-compose-bootstrap --no-pager -n 400 2>&1 || true
    tail_regular_file "legacy cloud-compose bootstrap log" "/home/cloud-compose/run.log" 400
    echo "--- cloud-compose unit ---"
    journalctl -u cloud-compose --no-pager -n 300 2>&1 || true
    echo "--- lifecycle lock permissions ---"
    stat -Lc '%A %a %U:%G %u:%g %n' \
        /run/lock/cloud-compose \
        /run/lock/cloud-compose/lifecycle.lock 2>&1 || true
    dump_compose_state
}

main() {
    require_root
    if [[ "$#" -ne 1 ]]; then
        usage
        return 2
    fi

    case "$1" in
        state) bootstrap_state ;;
        status) diagnostic_status ;;
        dump) diagnostic_dump ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
