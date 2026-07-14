#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[overlay-init] %s\n' "$*" >&2
}

usage() {
    echo "Usage: $0 VOLUME [true|false]" >&2
}

validate_root() {
    local root="$1" label="$2" canonical

    if [[ "$root" != /* || "$root" == "/" || "$root" =~ [[:space:]] ||
        "$root" == *","* || "$root" == *":"* || "$root" == *"\\"* ||
        "$root" =~ (^|/)\.\.?(/|$) ||
        -L "$root" || ! -d "$root" ]]; then
        log "$label root is missing or unsafe: $root"
        return 1
    fi
    canonical="$(readlink -f -- "$root")" || return 1
    if [[ "$canonical" != "$root" ]]; then
        log "$label root contains a symbolic-link traversal: $root"
        return 1
    fi
}

ensure_directory() {
    local path="$1" boundary="$2" canonical

    if [[ "$path" != "$boundary/"* || -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        log "Overlay directory is outside its boundary or unsafe: $path"
        return 1
    fi
    # Resolve the would-be path before creating it. `install -d` follows a
    # symbolic-link parent, so checking only the final directory would detect
    # traversal after already creating attacker-selected directories.
    canonical="$(realpath -m -- "$path")" || return 1
    if [[ "$canonical" != "$path" ]]; then
        log "Overlay directory contains a symbolic-link traversal: $path"
        return 1
    fi
    install -d -m 0755 -- "$path"
    if [[ -L "$path" || ! -d "$path" ]]; then
        log "Overlay directory changed during preparation: $path"
        return 1
    fi
    canonical="$(readlink -f -- "$path")" || return 1
    if [[ "$canonical" != "$path" ]]; then
        log "Overlay directory contains a symbolic-link traversal: $path"
        return 1
    fi
}

verify_overlay_mount() {
    local target="$1" lower="$2" upper="$3" work="$4"
    local filesystem options

    if ! mountpoint -q -- "$target"; then
        return 1
    fi
    filesystem="$(findmnt -n -o FSTYPE --target "$target")" || return 2
    options="$(findmnt -n -o OPTIONS --target "$target")" || return 2
    if [[ "$filesystem" != "overlay" ||
        ",$options," != *",lowerdir=$lower,"* ||
        ",$options," != *",upperdir=$upper,"* ||
        ",$options," != *",workdir=$work,"* ]]; then
        log "$target is mounted, but not from the expected overlay directories"
        return 2
    fi
}

clear_overlay_state() {
    local path

    for path in "$@"; do
        if [[ -L "$path" || ! -d "$path" ]]; then
            log "Refusing to clear unsafe overlay state directory: $path"
            return 1
        fi
        find "$path" -xdev -mindepth 1 -delete
        if [[ -n "$(find "$path" -xdev -mindepth 1 -print -quit)" ]]; then
            log "Overlay state directory could not be emptied: $path"
            return 1
        fi
    done
}

main() {
    local volume reset_flag perform_reset=false
    local volumes_root lower_root target lower_dir upper_dir work_dir
    local mount_status=0

    if [[ $# -lt 1 || $# -gt 2 ]]; then
        usage
        return 2
    fi
    volume="$1"
    reset_flag="${2:-false}"
    if [[ ! "$volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$ ]]; then
        log "Volume must be a safe Docker volume name"
        return 2
    fi
    case "${reset_flag,,}" in
        true | 1 | yes) perform_reset=true ;;
        false | 0 | no | "") perform_reset=false ;;
        *)
            log "Reset flag must be true or false"
            return 2
            ;;
    esac

    volumes_root="${CLOUD_COMPOSE_VOLUMES_ROOT:-/mnt/disks/volumes}"
    lower_root="${CLOUD_COMPOSE_OVERLAY_LOWER_ROOT:-/mnt/disks/prod-readonly}"
    validate_root "$volumes_root" "Volumes" || return 1
    validate_root "$lower_root" "Read-only lower" || return 1

    target="$volumes_root/$volume"
    lower_dir="$lower_root/$volume"
    upper_dir="$volumes_root/.overlay/$volume/upper"
    work_dir="$volumes_root/.overlay/$volume/work"

    ensure_directory "$target" "$volumes_root" || return 1
    ensure_directory "$upper_dir" "$volumes_root" || return 1
    ensure_directory "$work_dir" "$volumes_root" || return 1
    if [[ -L "$lower_dir" || ! -d "$lower_dir" || "$(readlink -f -- "$lower_dir")" != "$lower_dir" ]]; then
        log "Read-only lower directory is missing or unsafe: $lower_dir"
        return 1
    fi
    if [[ "$(stat -c %d -- "$upper_dir")" != "$(stat -c %d -- "$work_dir")" ]]; then
        log "Overlay upper and work directories must be on the same filesystem"
        return 1
    fi

    verify_overlay_mount "$target" "$lower_dir" "$upper_dir" "$work_dir" || mount_status=$?
    case "$mount_status" in
        0)
            if [[ "$perform_reset" != "true" ]]; then
                log "Volume $volume is already mounted from the expected overlay"
                return 0
            fi
            log "Unmounting overlay volume $volume for reset"
            umount -- "$target"
            ;;
        1)
            ;;
        *)
            return 1
            ;;
    esac

    if [[ "$perform_reset" == "true" ]]; then
        log "Clearing writable overlay state for $volume"
        clear_overlay_state "$upper_dir" "$work_dir" || return 1
    fi

    mount -t overlay overlay \
        -o "lowerdir=$lower_dir,upperdir=$upper_dir,workdir=$work_dir" \
        "$target"
    if ! verify_overlay_mount "$target" "$lower_dir" "$upper_dir" "$work_dir"; then
        umount -- "$target" >/dev/null 2>&1 || true
        log "Overlay mount verification failed for $volume"
        return 1
    fi
    log "Volume $volume is active"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
