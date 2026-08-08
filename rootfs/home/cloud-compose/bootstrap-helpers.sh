#!/usr/bin/env bash

cloud_compose_marker_exists() {
    local marker="$1" marker_size payload

    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    if [[ "$marker" == "/var/lib/cloud-compose/bootstrap-complete" ]]; then
        [[ "$(stat -c '%u:%g:%a:%F' -- "$(dirname -- "$marker")")" == "0:0:755:directory" &&
            "$(stat -c '%u:%g:%a:%h:%F' -- "$marker")" == "0:0:644:1:regular file" ]] || return 1
        marker_size="$(stat -c '%s' -- "$marker")" || return 1
        [[ "$marker_size" == "6" ]] || return 1
        IFS= read -r payload <"$marker" || return 1
        [[ "$payload" == "ready" ]]
    fi
}

cloud_compose_should_run_app_init() {
    local durable_marker="$1"
    local boot_marker="$2"

    cloud_compose_marker_exists "$durable_marker" ||
        ! cloud_compose_marker_exists "$boot_marker"
}

cloud_compose_publish_marker() (
    local marker="$1"
    local marker_dir tmp_marker

    marker_dir="$(dirname -- "$marker")"
    if [[ ! -d "$marker_dir" || -L "$marker_dir" ]]; then
        echo "Unsafe Cloud Compose marker directory: $marker_dir" >&2
        return 1
    fi
    if [[ "$marker" == "/var/lib/cloud-compose/bootstrap-complete" &&
        ( "$EUID" != "0" ||
          "$(stat -c '%u:%g:%a:%F' -- "$marker_dir")" != "0:0:755:directory" ) ]]; then
        echo "Durable Cloud Compose readiness requires a root-owned state directory" >&2
        return 1
    fi

    umask 022
    tmp_marker="$(mktemp "${marker}.tmp.XXXXXXXXXX")" || return 1
    if ! printf 'ready\n' >"$tmp_marker" ||
        ! chmod 0644 "$tmp_marker"; then
        rm -f -- "$tmp_marker"
        return 1
    fi
    if ((EUID == 0)) && ! chown 0:0 "$tmp_marker"; then
        rm -f -- "$tmp_marker"
        return 1
    fi
    if ! mv -fT -- "$tmp_marker" "$marker"; then
        rm -f -- "$tmp_marker"
        return 1
    fi
)

cloud_compose_consume_fresh_filesystem_marker() {
    local marker="$1"
    local expected_identity="$2"
    local marker_dir marker_identity marker_dir_identity marker_payload marker_size

    case "$expected_identity" in
        fresh) ;;
        v1:gcp-disk-id:*)
            if [[ ! "$expected_identity" =~ ^v1:gcp-disk-id:[0-9]{1,32}$ ]]; then
                echo "Unsafe fresh-filesystem identity" >&2
                return 2
            fi
            ;;
        *)
            echo "Unsafe fresh-filesystem identity" >&2
            return 2
            ;;
    esac

    if [[ "$marker" != /* || "$marker" == "/" || "$marker" == *$'\n'* ||
        "$marker" == *$'\r'* || "$marker" =~ (^|/)\.\.?(/|$) ]]; then
        echo "Unsafe fresh-filesystem marker path: $marker" >&2
        return 1
    fi
    if [[ ! -e "$marker" && ! -L "$marker" ]]; then
        return 0
    fi
    marker_dir="$(dirname -- "$marker")"
    if [[ -L "$marker_dir" || ! -d "$marker_dir" || -L "$marker" || ! -f "$marker" ]]; then
        echo "Unsafe fresh-filesystem marker: $marker" >&2
        return 1
    fi
    marker_dir_identity="$(stat -c '%u:%g:%a' -- "$marker_dir")" || return 1
    marker_identity="$(stat -c '%u:%g:%a:%h' -- "$marker")" || return 1
    if [[ "$marker_dir_identity" != "0:0:700" || "$marker_identity" != "0:0:600:1" ]]; then
        echo "Unsafe fresh-filesystem marker ownership or mode: $marker" >&2
        return 1
    fi
    marker_size="$(stat -c '%s' -- "$marker")" || return 1
    marker_payload=""
    if [[ "$marker_size" != "$((${#expected_identity} + 1))" ]] ||
        ! IFS= read -r marker_payload <"$marker" ||
        [[ "$marker_payload" != "$expected_identity" ]]; then
        echo "Fresh-filesystem marker does not match this disk incarnation" >&2
        return 1
    fi
    rm -f -- "$marker"
}

cloud_compose_validate_systemd_unit() {
    case "$1" in
        cloud-compose.service | cloud-compose-bootstrap.service) return 0 ;;
        *)
            echo "Unsupported Cloud Compose systemd unit: $1" >&2
            return 2
            ;;
    esac
}

cloud_compose_start_systemd_unit() {
    local unit="$1"
    local load_state active_state

    cloud_compose_validate_systemd_unit "$unit" || return

    load_state="$(systemctl show --property=LoadState --value -- "$unit")" || return 1
    if [[ "$load_state" != "loaded" ]]; then
        echo "Cloud Compose systemd unit is not loaded: $unit ($load_state)" >&2
        return 1
    fi

    systemctl enable -- "$unit"
    active_state="$(systemctl show --property=ActiveState --value -- "$unit")" || return 1
    if [[ "$active_state" == "active" || "$active_state" == "activating" ]]; then
        return 0
    fi

    if [[ "$active_state" == "failed" ]]; then
        systemctl reset-failed -- "$unit"
    fi
    systemctl start --no-block -- "$unit"
}

cloud_compose_wait_for_oneshot() {
    local unit="$1"
    local timeout_seconds="$2"
    local poll_seconds="${CLOUD_COMPOSE_SYSTEMD_POLL_SECONDS:-2}"
    local elapsed=0 active_state load_state

    cloud_compose_validate_systemd_unit "$unit" || return
    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]{0,4}$ ]] ||
        ((10#$timeout_seconds > 43200)); then
        echo "Cloud Compose systemd wait must be from 1 through 43200 seconds" >&2
        return 2
    fi
    if [[ ! "$poll_seconds" =~ ^[1-9][0-9]{0,2}$ ]] ||
        ((10#$poll_seconds > 300)); then
        echo "CLOUD_COMPOSE_SYSTEMD_POLL_SECONDS must be from 1 through 300 seconds" >&2
        return 2
    fi

    while ((elapsed < 10#$timeout_seconds)); do
        load_state="$(systemctl show --property=LoadState --value -- "$unit")" || return 1
        if [[ "$load_state" != "loaded" ]]; then
            echo "Cloud Compose systemd unit stopped being loaded: $unit ($load_state)" >&2
            return 1
        fi

        active_state="$(systemctl show --property=ActiveState --value -- "$unit")" || return 1
        if [[ "$active_state" == "active" ]]; then
            return 0
        fi
        sleep "$poll_seconds"
        elapsed=$((elapsed + 10#$poll_seconds))
    done

    echo "Timed out waiting ${timeout_seconds}s for $unit to become active" >&2
    systemctl status --no-pager --full -- "$unit" >&2 || true
    return 1
}

cloud_compose_start_and_wait_for_oneshot() {
    local unit="$1"
    local timeout_seconds="$2"

    cloud_compose_start_systemd_unit "$unit" &&
        cloud_compose_wait_for_oneshot "$unit" "$timeout_seconds"
}
