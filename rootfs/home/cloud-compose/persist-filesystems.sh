#!/usr/bin/env bash

set -euo pipefail

_cc_persist_filesystems_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_persist_filesystems_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_persist_filesystems_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_persist_filesystems_source _cc_persist_filesystems_dir _cc_persist_filesystems_installed_home
if [[ -n "$_cc_persist_filesystems_installed_home" &&
    ( "$_cc_persist_filesystems_installed_home" == "/" ||
        "$_cc_persist_filesystems_source" == "${_cc_persist_filesystems_installed_home%/}/"* ) ]]; then
    # shellcheck disable=SC1091
    source /etc/cloud-compose/libexec/checked-programs.bash
    cloud_compose_bind_program \
        "$_cc_persist_filesystems_source" \
        CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM \
        /etc/cloud-compose/awk/reconcile-fstab.awk \
        /etc/cloud-compose/awk/reconcile-fstab.awk
    fstab_reconcile_program="$CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM"
else
    # Early boot executes a verified root-owned copy from /run and passes its
    # separately verified awk program explicitly. Repository contracts use the
    # same override without weakening the installed /home path.
    fstab_reconcile_program="${CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM:-$_cc_persist_filesystems_dir/../../etc/cloud-compose/awk/reconcile-fstab.awk}"
fi
readonly fstab_reconcile_program

log() {
    printf '[filesystem-persist] %s\n' "$*" >&2
}

usage() {
    echo "Usage: $0 DATA_DEVICE VOLUMES_DEVICE [READ_ONLY_OVERLAY_DEVICE]" >&2
}

validate_device_path() {
    local value="$1"

    [[ "$value" =~ ^/dev/[A-Za-z0-9._/+:-]+$ ]] &&
        [[ "$value" != *$'\n'* ]] && [[ "$value" != *$'\r'* ]]
}

digitalocean_automatic_mount() {
    local device_path="$1" volume_name

    case "$device_path" in
        /dev/disk/by-id/scsi-0DO_Volume_*)
            volume_name="${device_path#/dev/disk/by-id/scsi-0DO_Volume_}"
            ;;
        *)
            return 1
            ;;
    esac
    if [[ ! "$volume_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$ ]]; then
        return 2
    fi
    printf '/mnt/%s\n' "${volume_name//-/_}"
}

remove_digitalocean_mount_unit() {
    local device_path="$1" action="${2:-remove}" provider_mount unit_name systemd_dir unit_path
    local link resolved_link
    local -a what_values where_values links

    provider_mount="$(digitalocean_automatic_mount "$device_path")" || return 0
    unit_name="mnt-${provider_mount#/mnt/}.mount"
    systemd_dir="${CLOUD_COMPOSE_SYSTEMD_DIR:-/etc/systemd/system}"
    if [[ "$systemd_dir" != /* || "$systemd_dir" == "/" || -L "$systemd_dir" ||
        "$systemd_dir" == *$'\n'* || "$systemd_dir" == *$'\r'* ]]; then
        log "Refusing unsafe systemd unit directory: $systemd_dir"
        return 1
    fi
    if [[ ! -d "$systemd_dir" ]]; then
        return 0
    fi

    unit_path="$systemd_dir/$unit_name"
    links=()
    shopt -s nullglob
    links=("$systemd_dir"/*.wants/"$unit_name")
    shopt -u nullglob

    if [[ ! -e "$unit_path" && ! -L "$unit_path" ]]; then
        if ((${#links[@]} > 0)); then
            log "DigitalOcean mount unit link exists without its expected unit: $unit_path"
            return 1
        fi
        return 0
    fi
    if [[ -L "$unit_path" || ! -f "$unit_path" ]]; then
        log "DigitalOcean mount unit is not a regular provider-owned file: $unit_path"
        return 1
    fi

    mapfile -t what_values < <(sed -n 's/^[[:space:]]*What=//p' "$unit_path")
    mapfile -t where_values < <(sed -n 's/^[[:space:]]*Where=//p' "$unit_path")
    if ((${#what_values[@]} != 1 || ${#where_values[@]} != 1)) ||
        [[ "${what_values[0]}" != "$device_path" || "${where_values[0]}" != "$provider_mount" ]]; then
        log "Refusing to remove unexpected DigitalOcean mount unit contents: $unit_path"
        return 1
    fi

    for link in "${links[@]}"; do
        if [[ -L "$(dirname -- "$link")" || ! -d "$(dirname -- "$link")" || ! -L "$link" ]]; then
            log "DigitalOcean mount unit wants entry is not a symlink: $link"
            return 1
        fi
        resolved_link="$(readlink -f -- "$link" 2>/dev/null || true)"
        if [[ "$resolved_link" != "$unit_path" ]]; then
            log "DigitalOcean mount unit wants link has an unexpected target: $link"
            return 1
        fi
    done

    if [[ "$action" == "validate" ]]; then
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl disable --now -- "$unit_name"; then
            log "Could not disable superseded DigitalOcean mount unit: $unit_name"
            return 1
        fi
    fi

    for link in "${links[@]}"; do
        rm -f -- "$link"
    done
    rm -f -- "$unit_path"
    log "Removed superseded provider mount unit $unit_name"
}

main() {
    local data_device volumes_device overlay_device fstab_path lock_path tmp status
    local data_provider_mount="" volumes_provider_mount=""
    local begin_marker="# BEGIN cloud-compose persistent mounts"
    local end_marker="# END cloud-compose persistent mounts"

    if [[ $# -lt 2 || $# -gt 3 ]]; then
        usage
        return 2
    fi

    data_device="$1"
    volumes_device="$2"
    overlay_device="${3:-}"
    if ! validate_device_path "$data_device" || ! validate_device_path "$volumes_device"; then
        log "Device paths must be safe absolute /dev paths"
        return 2
    fi
    if [[ "$data_device" == "$volumes_device" ]]; then
        log "Data and Docker-volume devices must be distinct"
        return 2
    fi
    if [[ -n "$overlay_device" ]]; then
        if ! validate_device_path "$overlay_device"; then
            log "Read-only overlay device must be a safe absolute /dev path"
            return 2
        fi
        if [[ "$overlay_device" == "$data_device" || "$overlay_device" == "$volumes_device" ]]; then
            log "Read-only overlay device must be distinct from writable devices"
            return 2
        fi
    fi
    if [[ "$data_device" == /dev/disk/by-id/scsi-0DO_Volume_* ]]; then
        data_provider_mount="$(digitalocean_automatic_mount "$data_device")" || {
            log "Invalid DigitalOcean data-volume device path: $data_device"
            return 2
        }
    fi
    if [[ "$volumes_device" == /dev/disk/by-id/scsi-0DO_Volume_* ]]; then
        volumes_provider_mount="$(digitalocean_automatic_mount "$volumes_device")" || {
            log "Invalid DigitalOcean Docker-volume device path: $volumes_device"
            return 2
        }
    fi

    fstab_path="${CLOUD_COMPOSE_FSTAB_PATH:-/etc/fstab}"
    lock_path="${CLOUD_COMPOSE_FSTAB_LOCK_PATH:-/run/cloud-compose-fstab.lock}"
    if [[ "$fstab_path" != /* || "$fstab_path" == "/" || -L "$fstab_path" ||
        "$fstab_path" == *$'\n'* || "$fstab_path" == *$'\r'* ]]; then
        log "Refusing unsafe fstab path: $fstab_path"
        return 2
    fi
    if [[ "$lock_path" != /* || "$lock_path" == "/" || "$lock_path" == *$'\n'* ||
        "$lock_path" == *$'\r'* ]]; then
        log "Refusing unsafe fstab lock path: $lock_path"
        return 2
    fi
    if [[ -e "$fstab_path" && ! -f "$fstab_path" ]]; then
        log "fstab path is not a regular file: $fstab_path"
        return 2
    fi

    install -d -m 0755 -- "$(dirname -- "$fstab_path")" "$(dirname -- "$lock_path")"
    touch "$fstab_path"
    exec 9>"$lock_path"
    if command -v flock >/dev/null 2>&1; then
        flock -x 9
    fi

    # Validate provider-owned persistence before mutating fstab. Validation is
    # repeated during removal to keep an unexpected local unit fail-closed.
    remove_digitalocean_mount_unit "$data_device" validate
    remove_digitalocean_mount_unit "$volumes_device" validate

    tmp="$(mktemp "${fstab_path}.tmp.XXXXXX")"
    trap 'rm -f -- "$tmp"' EXIT
    awk -v begin="$begin_marker" -v end="$end_marker" \
        -v data_device="$data_device" -v data_provider_mount="$data_provider_mount" \
        -v volumes_device="$volumes_device" -v volumes_provider_mount="$volumes_provider_mount" \
        -f "$fstab_reconcile_program" "$fstab_path" >"$tmp" || {
        status=$?
        if [[ "$status" -eq 42 ]]; then
            log "fstab contains an unterminated managed block or an unmanaged cloud-compose mount target"
        else
            log "Could not inspect $fstab_path"
        fi
        return 1
    }

    {
        printf '%s\n' "$begin_marker"
        printf '%s\t/mnt/disks/data\text4\tdefaults,nofail,x-systemd.device-timeout=120s\t0\t2\n' "$data_device"
        printf '%s\t/mnt/disks/volumes\text4\tdefaults,nofail,x-systemd.device-timeout=120s\t0\t2\n' "$volumes_device"
        printf '/mnt/disks/volumes\t/mnt/disks/data/docker/volumes\tnone\tbind,nofail,x-systemd.requires=/mnt/disks/volumes\t0\t0\n'
        if [[ -n "$overlay_device" ]]; then
            printf '%s\t/mnt/disks/prod-readonly\text4\tro,nofail,x-systemd.device-timeout=120s\t0\t2\n' "$overlay_device"
        fi
        printf '%s\n' "$end_marker"
    } >>"$tmp"
    # Retire the validated provider units before committing the replacement
    # fstab. If unit cleanup fails, the original provider persistence remains
    # intact and the prepared fstab is discarded by the EXIT trap.
    remove_digitalocean_mount_unit "$data_device"
    remove_digitalocean_mount_unit "$volumes_device"

    chmod --reference="$fstab_path" "$tmp"
    chown --reference="$fstab_path" "$tmp"
    mv -f -- "$tmp" "$fstab_path"
    trap - EXIT

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
    log "Persistent data, Docker-volume, and bind mounts are recorded in $fstab_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
