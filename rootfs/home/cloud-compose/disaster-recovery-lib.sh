#!/usr/bin/env bash

# Shared validation for the provider-neutral disaster-recovery driver contract.
# The caller must enable `set -euo pipefail` before sourcing this file.

CLOUD_COMPOSE_DR_STATE_ROOT="${CLOUD_COMPOSE_DR_STATE_ROOT:-/mnt/disks/data/.cloud-compose-disaster-recovery}"
CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER="${CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER:-/usr/local/libexec/cloud-compose/offhost-backup-driver}"

cloud_compose_dr_is_required() {
    case "${CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED:-false}" in
        true) return 0 ;;
        false) return 1 ;;
        *)
            echo "CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED must be true or false" >&2
            return 2
            ;;
    esac
}

cloud_compose_dr_validate_safe_absolute_path() {
    local path="$1" label="$2"

    if [[ ! "$path" =~ ^/[A-Za-z0-9._/+:-]+$ || "$path" == *"//"* ||
        "$path" =~ (^|/)\.\.?(/|$) ]]; then
        echo "$label must be a safe absolute path without whitespace or dot segments" >&2
        return 1
    fi
}

cloud_compose_dr_validate_utc_timestamp() {
    local value="$1" label="$2"

    if [[ ! "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "$label must be an RFC 3339 UTC timestamp with whole-second precision" >&2
        return 1
    fi
}

cloud_compose_dr_validate_remote_id() {
    local value="$1" label="$2"

    if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,511}$ ]]; then
        echo "$label contains unsupported characters or exceeds 512 bytes" >&2
        return 1
    fi
}

cloud_compose_dr_validate_driver() {
    local driver="${1:-$CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER}"
    local current component metadata owner mode kind links resolved
    local -a components

    cloud_compose_dr_validate_safe_absolute_path "$driver" "Off-host backup driver path" || return 1
    if [[ -L "$driver" || ! -f "$driver" || ! -x "$driver" ]]; then
        echo "Off-host backup driver must be a non-symlink executable file: $driver" >&2
        return 1
    fi

    resolved="$(realpath -e -- "$driver")" || return 1
    if [[ "$resolved" != "$driver" ]]; then
        echo "Off-host backup driver path must not traverse symbolic links: $driver" >&2
        return 1
    fi

    IFS='/' read -r -a components <<<"${driver#/}"
    current="/"
    for component in "${components[@]:0:${#components[@]}-1}"; do
        current="${current%/}/${component}"
        if [[ -L "$current" || ! -d "$current" ]]; then
            echo "Off-host backup driver parent must be a real directory: $current" >&2
            return 1
        fi
        metadata="$(stat -c '%u:%a:%F' -- "$current")" || return 1
        IFS=: read -r owner mode kind <<<"$metadata"
        if [[ "$owner" != "0" || "$kind" != "directory" || ! "$mode" =~ ^[0-7]{3,4}$ ||
            $((8#$mode & 0022)) -ne 0 ]]; then
            echo "Off-host backup driver parents must be root-owned and not group/world writable: $current" >&2
            return 1
        fi
    done

    metadata="$(stat -c '%u:%a:%h:%F' -- "$driver")" || return 1
    IFS=: read -r owner mode links kind <<<"$metadata"
    if [[ "$owner" != "0" || "$links" != "1" || "$kind" != "regular file" ||
        ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
        echo "Off-host backup driver must be a single-link, root-owned executable that is not group/world writable: $driver" >&2
        return 1
    fi
}

cloud_compose_dr_validate_json_file() {
    local path="$1" label="$2" metadata owner mode links kind size

    if [[ -L "$path" || ! -f "$path" ]]; then
        echo "$label is missing or unsafe" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%a:%h:%F' -- "$path")" || return 1
    IFS=: read -r owner mode links kind <<<"$metadata"
    if [[ "$owner" != "0" || "$links" != "1" || "$kind" != "regular file" ||
        ! "$mode" =~ ^[0-7]{3,4}$ || $((8#$mode & 0022)) -ne 0 ]]; then
        echo "$label must be a single-link, root-owned regular file that is not group/world writable" >&2
        return 1
    fi
    size="$(wc -c <"$path")" || return 1
    if ((size < 2 || size > 65536)); then
        echo "$label must contain between 2 and 65536 bytes" >&2
        return 1
    fi
}

cloud_compose_dr_prepare_state_directory() {
    local path="$1" metadata owner mode kind

    cloud_compose_dr_validate_safe_absolute_path "$path" "Disaster-recovery state path" || return 1
    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        echo "Disaster-recovery state path is unsafe: $path" >&2
        return 1
    fi
    install -d -m 0700 -o root -g root -- "$path" || return 1
    metadata="$(stat -c '%u:%a:%F' -- "$path")" || return 1
    IFS=: read -r owner mode kind <<<"$metadata"
    if [[ "$owner" != "0" || "$mode" != "700" || "$kind" != "directory" || -L "$path" ]]; then
        echo "Disaster-recovery state directories must be real root-owned mode-0700 directories: $path" >&2
        return 1
    fi
}

cloud_compose_dr_validate_backup_receipt() {
    local path="$1" operation_id="$2" manifest_sha256="$3" completed_at remote_id

    cloud_compose_dr_validate_json_file "$path" "Off-host backup receipt" || return 1
    jq -e \
        --arg operation_id "$operation_id" \
        --arg manifest_sha256 "$manifest_sha256" '
        type == "object" and length == 10 and
        .schema_version == 1 and
        .kind == "cloud-compose.offhost-backup-receipt" and
        .operation_id == $operation_id and
        .manifest_sha256 == $manifest_sha256 and
        .status == "succeeded" and
        .encrypted == true and
        .off_host == true and
        (.completed_at | type == "string" and length == 20 and
          (explode | all(.[]; . >= 32 and . != 127))) and
        (.remote_id | type == "string" and length >= 1 and length <= 512 and
          (explode | all(.[]; . >= 32 and . != 127))) and
        (.coverage | type == "object" and length == 3 and
          .database == true and
          .application_files == true and
          .volume_topology == true)
    ' "$path" >/dev/null || {
        echo "Off-host backup driver returned an invalid or incomplete coverage receipt" >&2
        return 1
    }
    completed_at="$(jq -er '.completed_at' "$path")" || return 1
    remote_id="$(jq -er '.remote_id' "$path")" || return 1
    cloud_compose_dr_validate_utc_timestamp "$completed_at" "Off-host backup completion time" || return 1
    cloud_compose_dr_validate_remote_id "$remote_id" "Off-host backup remote id" || return 1
}

cloud_compose_dr_validate_restore_proof() {
    local path="$1" test_id="$2" manifest_sha256="$3" receipt_sha256="$4" completed_at recovery_id

    cloud_compose_dr_validate_json_file "$path" "Restore-test proof" || return 1
    jq -e \
        --arg test_id "$test_id" \
        --arg manifest_sha256 "$manifest_sha256" \
        --arg receipt_sha256 "$receipt_sha256" '
        type == "object" and length == 13 and
        .schema_version == 1 and
        .kind == "cloud-compose.restore-test-proof" and
        .test_id == $test_id and
        .source_manifest_sha256 == $manifest_sha256 and
        .source_receipt_sha256 == $receipt_sha256 and
        .status == "succeeded" and
        .disposable_recovery == true and
        .recovery_destroyed == true and
        .integrity_verified == true and
        (.completed_at | type == "string" and length == 20 and
          (explode | all(.[]; . >= 32 and . != 127))) and
        (.recovery_id | type == "string" and length >= 1 and length <= 512 and
          (explode | all(.[]; . >= 32 and . != 127))) and
        (.coverage | type == "object" and length == 3 and
          .database == true and
          .application_files == true and
          .volume_topology == true) and
        (.source_encrypted == true)
    ' "$path" >/dev/null || {
        echo "Off-host backup driver returned an invalid restore-test proof" >&2
        return 1
    }
    completed_at="$(jq -er '.completed_at' "$path")" || return 1
    recovery_id="$(jq -er '.recovery_id' "$path")" || return 1
    cloud_compose_dr_validate_utc_timestamp "$completed_at" "Restore-test completion time" || return 1
    cloud_compose_dr_validate_remote_id "$recovery_id" "Restore-test recovery id" || return 1
}

cloud_compose_dr_run_driver() {
    local driver="$1"
    shift

    # Driver credentials and configuration are installed and resolved by the
    # operator-owned executable. Terraform-rendered host/application variables
    # are deliberately absent, and driver output is never copied to the journal.
    if ! env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        "$driver" "$@" </dev/null >/dev/null 2>&1; then
        echo "Off-host disaster-recovery driver failed; inspect its operator-owned diagnostics" >&2
        return 1
    fi
}
