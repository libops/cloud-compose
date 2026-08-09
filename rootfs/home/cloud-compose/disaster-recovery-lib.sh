#!/usr/bin/env bash

# Shared validation for the provider-neutral disaster-recovery driver contract.
# The caller must enable `set -euo pipefail` before sourcing this file.

_cc_dr_library_source="$(readlink -f -- "${BASH_SOURCE[0]}")" || {
    echo "Could not resolve the Cloud Compose disaster-recovery library path" >&2
    return 1 2>/dev/null || exit 1
}
_cc_dr_library_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || {
    echo "Could not resolve the Cloud Compose disaster-recovery library directory" >&2
    return 1 2>/dev/null || exit 1
}
_cc_dr_library_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_dr_library_source _cc_dr_library_dir _cc_dr_library_installed_home
if [[ -n "$_cc_dr_library_installed_home" &&
    ( "$_cc_dr_library_installed_home" == "/" ||
        "$_cc_dr_library_source" == "${_cc_dr_library_installed_home%/}/"* ) ]]; then
    _cc_dr_library_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_dr_library_checked_programs="$_cc_dr_library_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_dr_library_checked_programs
# shellcheck disable=SC1090
if ! source "$_cc_dr_library_checked_programs"; then
    echo "Could not load the checked Cloud Compose program resolver" >&2
    return 1 2>/dev/null || exit 1
fi
if ! cloud_compose_bind_program_dir \
    "$_cc_dr_library_source" \
    CLOUD_COMPOSE_JQ_PROGRAM_DIR \
    /etc/cloud-compose/jq \
    "$_cc_dr_library_dir/../../etc/cloud-compose/jq" \
    dr-validate-backup-receipt.jq \
    dr-backup-completed-at.jq \
    dr-backup-remote-id.jq \
    dr-validate-restore-proof.jq \
    dr-restore-completed-at.jq \
    dr-restore-recovery-id.jq; then
    return 1 2>/dev/null || exit 1
fi

CLOUD_COMPOSE_DR_STATE_ROOT="${CLOUD_COMPOSE_DR_STATE_ROOT:-/mnt/disks/data/.cloud-compose-disaster-recovery}"
CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER="${CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER:-/etc/cloud-compose/libexec/offhost-backup-driver}"

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

cloud_compose_dr_sha256_file() {
    local path="$1" output digest

    output="$(sha256sum -- "$path")" || return 1
    digest="${output%% *}"
    if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
        echo "sha256sum returned an invalid digest for: $path" >&2
        return 1
    fi
    printf '%s\n' "$digest"
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
        --arg manifest_sha256 "$manifest_sha256" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-validate-backup-receipt.jq" \
        "$path" >/dev/null || {
        echo "Off-host backup driver returned an invalid or incomplete coverage receipt" >&2
        return 1
    }
    completed_at="$(jq -er -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-backup-completed-at.jq" "$path")" || return 1
    remote_id="$(jq -er -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-backup-remote-id.jq" "$path")" || return 1
    cloud_compose_dr_validate_utc_timestamp "$completed_at" "Off-host backup completion time" || return 1
    cloud_compose_dr_validate_remote_id "$remote_id" "Off-host backup remote id" || return 1
}

cloud_compose_dr_validate_restore_proof() {
    local path="$1" test_id="$2" manifest_sha256="$3" receipt_sha256="$4" completed_at recovery_id

    cloud_compose_dr_validate_json_file "$path" "Restore-test proof" || return 1
    jq -e \
        --arg test_id "$test_id" \
        --arg manifest_sha256 "$manifest_sha256" \
        --arg receipt_sha256 "$receipt_sha256" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-validate-restore-proof.jq" \
        "$path" >/dev/null || {
        echo "Off-host backup driver returned an invalid restore-test proof" >&2
        return 1
    }
    completed_at="$(jq -er -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-restore-completed-at.jq" "$path")" || return 1
    recovery_id="$(jq -er -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/dr-restore-recovery-id.jq" "$path")" || return 1
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
