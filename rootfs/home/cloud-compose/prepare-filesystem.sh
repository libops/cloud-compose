#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[filesystem-prep] %s\n' "$*" >&2
}

usage() {
    echo "Usage: $0 DEVICE_PATH MOUNT_PATH" >&2
}

is_block_device() {
    [[ -b "$1" ]]
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

    # DigitalOcean's automatic format-and-mount convention replaces hyphens
    # in the volume name with underscores beneath /mnt.
    printf '/mnt/%s\n' "${volume_name//-/_}"
}

settle_digitalocean_automount() {
    local device_path="$1" settle_seconds="$2"

    # DigitalOcean's legacy automatic-format path is driven by udev and a
    # generated systemd mount unit. Device-node appearance alone does not mean
    # that workflow is finished, so wait for udev before inspecting or mutating
    # the filesystem.
    if command -v udevadm >/dev/null 2>&1; then
        if ! udevadm settle --timeout="$settle_seconds"; then
            log "DigitalOcean automount udev processing did not settle for $device_path"
            return 1
        fi
    fi
}

start_digitalocean_automount() {
    local device_path="$1" provider_mount="$2"
    local systemd_dir unit_name unit_path
    local -a what_values where_values

    systemd_dir="${CLOUD_COMPOSE_SYSTEMD_DIR:-/etc/systemd/system}"
    if [[ "$systemd_dir" != /* || "$systemd_dir" == "/" || -L "$systemd_dir" ||
        "$systemd_dir" == *$'\n'* || "$systemd_dir" == *$'\r'* ]]; then
        log "Refusing unsafe systemd unit directory: $systemd_dir"
        return 1
    fi
    if [[ ! -d "$systemd_dir" ]]; then
        return 0
    fi

    unit_name="mnt-$(basename -- "$provider_mount").mount"
    unit_path="$systemd_dir/$unit_name"
    if [[ ! -e "$unit_path" && ! -L "$unit_path" ]]; then
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
        log "Refusing unexpected DigitalOcean mount unit contents: $unit_path"
        return 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log "A DigitalOcean mount unit exists but systemctl is unavailable: $unit_path"
        return 1
    fi
    systemctl daemon-reload
    # systemctl start waits for the mount job unless explicitly told not to.
    # Completing it here closes the race between udev device discovery and an
    # offline fsck or format by cloud-compose.
    if ! systemctl start -- "$unit_name"; then
        log "DigitalOcean automount unit failed: $unit_name"
        return 1
    fi
}

device_mount_targets() {
    local device="$1" status=0 output

    output="$(findmnt -rn -o TARGET --source "$device" 2>/dev/null)" || status=$?
    case "$status" in
        0 | 1) printf '%s' "$output" ;;
        *)
            log "Could not inspect existing mounts for $device"
            return 1
            ;;
    esac
}

require_device_unmounted() {
    local device="$1" operation="$2" targets

    targets="$(device_mount_targets "$device")" || return 1
    if [[ -n "$targets" ]]; then
        log "$device became mounted before $operation; refusing offline mutation: ${targets//$'\n'/ }"
        return 1
    fi
}

main() {
    local device_path mount_path device filesystem_type mounted_source resolved_mounted_source
    local already_mounted blkid_status fsck_status wait_seconds sleep_seconds settle_seconds
    local device_mounts_output provider_mount="" moved_source resolved_moved_source
    local target_contents
    local -a device_mounts

    if [[ $# -ne 2 ]]; then
        usage
        return 2
    fi

    device_path="$1"
    mount_path="$2"

    if [[ "$device_path" != /dev/* || "$device_path" == *$'\n'* || "$device_path" == *$'\r'* ]]; then
        log "Refusing unsafe device path: $device_path"
        return 2
    fi
    if [[ "$mount_path" != /* || "$mount_path" == "/" || "$mount_path" == *$'\n'* ||
        "$mount_path" == *$'\r'* || "$mount_path" =~ (^|/)\.\.?(/|$) ]]; then
        log "Refusing unsafe mount path: $mount_path"
        return 2
    fi

    wait_seconds="${FILESYSTEM_DEVICE_WAIT_SECONDS:-120}"
    if [[ ! "$wait_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$wait_seconds > 600)); then
        log "FILESYSTEM_DEVICE_WAIT_SECONDS must be an integer from 1 through 600"
        return 2
    fi
    while true; do
        device="$(readlink -f -- "$device_path" 2>/dev/null || true)"
        if [[ -n "$device" ]] && is_block_device "$device"; then
            break
        fi
        if ((10#$wait_seconds == 0)); then
            log "Block device did not appear before the wait deadline: $device_path"
            return 1
        fi
        sleep_seconds=2
        if ((10#$wait_seconds < sleep_seconds)); then
            sleep_seconds=$((10#$wait_seconds))
        fi
        log "Waiting for block device: $device_path"
        sleep "$sleep_seconds"
        wait_seconds=$((10#$wait_seconds - sleep_seconds))
    done

    settle_seconds="${FILESYSTEM_AUTOMOUNT_SETTLE_SECONDS:-60}"
    if [[ ! "$settle_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$settle_seconds > 600)); then
        log "FILESYSTEM_AUTOMOUNT_SETTLE_SECONDS must be an integer from 1 through 600"
        return 2
    fi
    if provider_mount="$(digitalocean_automatic_mount "$device_path")"; then
        settle_digitalocean_automount "$device_path" "$settle_seconds"
    else
        provider_mount=""
    fi

    already_mounted=false
    mkdir -p -- "$mount_path"
    if [[ -L "$mount_path" || ! -d "$mount_path" ]]; then
        log "Target mount path is not a safe directory: $mount_path"
        return 1
    fi
    device_mounts_output="$(device_mount_targets "$device")" || return 1
    device_mounts=()
    if [[ -n "$device_mounts_output" ]]; then
        mapfile -t device_mounts <<<"$device_mounts_output"
    fi
    # If the legacy provider unit exists but udev has not started it yet,
    # finish that job synchronously and inspect the resulting mount set before
    # any offline filesystem operation. Do not start it when another mount is
    # already present, which would create a duplicate alias.
    if ((${#device_mounts[@]} == 0)) && [[ -n "$provider_mount" ]]; then
        start_digitalocean_automount "$device_path" "$provider_mount"
        device_mounts_output="$(device_mount_targets "$device")" || return 1
        if [[ -n "$device_mounts_output" ]]; then
            mapfile -t device_mounts <<<"$device_mounts_output"
        fi
    fi
    if ((${#device_mounts[@]} > 1)); then
        log "$device is mounted at multiple targets; refusing to continue: ${device_mounts[*]}"
        return 1
    fi

    if ((${#device_mounts[@]} == 1)); then
        if [[ "${device_mounts[0]}" == "$mount_path" ]]; then
            mounted_source="$(findmnt -n -o SOURCE --target "$mount_path")" || {
                log "Could not determine the mounted source for $mount_path"
                return 1
            }
            resolved_mounted_source="$(readlink -f -- "$mounted_source" 2>/dev/null || true)"
            if [[ -z "$resolved_mounted_source" || "$resolved_mounted_source" != "$device" ]]; then
                log "$mount_path is already mounted from $mounted_source, expected $device"
                return 1
            fi
            already_mounted=true
        elif [[ -n "$provider_mount" && "${device_mounts[0]}" == "$provider_mount" &&
            ! -L "$provider_mount" && -d "$provider_mount" ]] && mountpoint -q -- "$provider_mount"; then
            mounted_source="$(findmnt -n -o SOURCE --target "$provider_mount")" || {
                log "Could not determine the mounted source for $provider_mount"
                return 1
            }
            resolved_mounted_source="$(readlink -f -- "$mounted_source" 2>/dev/null || true)"
            if [[ -z "$resolved_mounted_source" || "$resolved_mounted_source" != "$device" ]]; then
                log "$provider_mount is mounted from $mounted_source, expected $device"
                return 1
            fi
            target_contents="$(find "$mount_path" -mindepth 1 -maxdepth 1 -print -quit)" || {
                log "Could not safely inspect target mount directory: $mount_path"
                return 1
            }
            if [[ -n "$target_contents" ]]; then
                log "Target mount directory is not empty; refusing to hide its contents: $mount_path"
                return 1
            fi

            mount --move "$provider_mount" "$mount_path"
            device_mounts_output="$(device_mount_targets "$device")" || return 1
            device_mounts=()
            if [[ -n "$device_mounts_output" ]]; then
                mapfile -t device_mounts <<<"$device_mounts_output"
            fi
            if ((${#device_mounts[@]} != 1)) || [[ "${device_mounts[0]}" != "$mount_path" ]]; then
                log "Relocated mount did not become the device's only target: ${device_mounts[*]:-none}"
                mount --move "$mount_path" "$provider_mount" >/dev/null 2>&1 || true
                return 1
            fi
            moved_source="$(findmnt -n -o SOURCE --target "$mount_path")" || {
                log "Could not verify the relocated mount at $mount_path"
                mount --move "$mount_path" "$provider_mount" >/dev/null 2>&1 || true
                return 1
            }
            resolved_moved_source="$(readlink -f -- "$moved_source" 2>/dev/null || true)"
            if [[ -z "$resolved_moved_source" || "$resolved_moved_source" != "$device" ]]; then
                log "Relocated mount at $mount_path is from $moved_source, expected $device"
                mount --move "$mount_path" "$provider_mount" >/dev/null 2>&1 || true
                return 1
            fi
            rmdir -- "$provider_mount" 2>/dev/null || true
            already_mounted=true
            log "Moved provider-owned mount $provider_mount to $mount_path"
        else
            log "$device is mounted at unexpected target ${device_mounts[0]}; refusing to continue"
            return 1
        fi
    fi

    filesystem_type=""
    blkid_status=0
    filesystem_type="$(blkid -p -s TYPE -o value -- "$device" 2>/dev/null)" || blkid_status=$?

    case "$blkid_status" in
        0)
            if [[ "$filesystem_type" != "ext4" ]]; then
                log "Existing filesystem on $device is '$filesystem_type', expected ext4; refusing to format"
                return 1
            fi

            if [[ "$already_mounted" != "true" ]]; then
                require_device_unmounted "$device" "filesystem check"
                fsck_status=0
                # resize2fs can require a complete offline check even when the
                # ext4 clean bit lets a normal preen return immediately. Force
                # that check while the device is still proven unmounted so a
                # preserved disk can be grown safely during a VM replacement.
                fsck.ext4 -f -p -- "$device" || fsck_status=$?
                case "$fsck_status" in
                    0 | 1)
                        ;;
                    2 | 3)
                        log "Filesystem check for $device requires a reboot; refusing to mount or format"
                        return 2
                        ;;
                    *)
                        log "Filesystem check for $device failed with status $fsck_status; refusing to format"
                        return 1
                        ;;
                esac
            fi
            if ! resize2fs -- "$device"; then
                log "Could not grow the ext4 filesystem on $device"
                return 1
            fi
            ;;
        2)
            if [[ "$already_mounted" == "true" ]]; then
                log "Mounted device $device has no detectable filesystem signature"
                return 1
            fi
            log "No filesystem signature found on $device; creating ext4"
            require_device_unmounted "$device" "filesystem creation"
            mkfs.ext4 -m 0 -E lazy_itable_init=1,lazy_journal_init=1,nodiscard -- "$device"
            ;;
        *)
            log "Could not safely inspect filesystem signatures on $device (blkid status $blkid_status)"
            return 1
            ;;
    esac

    if [[ "$already_mounted" != "true" ]]; then
        require_device_unmounted "$device" "cloud-compose mount"
        mount -o defaults -- "$device" "$mount_path"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
