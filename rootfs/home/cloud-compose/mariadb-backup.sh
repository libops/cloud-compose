#!/usr/bin/env bash

set -euo pipefail

_cc_mariadb_backup_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_mariadb_backup_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_mariadb_backup_source script_dir _cc_mariadb_backup_installed_home
if [[ -n "$_cc_mariadb_backup_installed_home" &&
    ( "$_cc_mariadb_backup_installed_home" == "/" ||
        "$_cc_mariadb_backup_source" == "${_cc_mariadb_backup_installed_home%/}/"* ) ]]; then
    _cc_mariadb_backup_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_mariadb_backup_checked_programs="$script_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_mariadb_backup_checked_programs
# shellcheck disable=SC1090
source "$_cc_mariadb_backup_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_mariadb_backup_source" CLOUD_COMPOSE_PROFILE_PATH \
    /home/cloud-compose/profile.sh "$script_dir/profile.sh"
cloud_compose_bind_source_program \
    "$_cc_mariadb_backup_source" CLOUD_COMPOSE_COMPOSE_APPS_PATH \
    /home/cloud-compose/compose-apps.sh "$script_dir/compose-apps.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
compose_apps_path="$CLOUD_COMPOSE_COMPOSE_APPS_PATH"
readonly profile_path compose_apps_path
# shellcheck disable=SC1090
source "$profile_path"
# Reload the fixed resolver before sourcing the Compose library.
# shellcheck disable=SC1090
source "$_cc_mariadb_backup_checked_programs"
# shellcheck disable=SC1090
source "$compose_apps_path"

BACKUP_ROOT="${MARIADB_BACKUP_ROOT:-/mnt/disks/data/backups/mariadb}"
BACKUP_RETENTION_DAYS="${MARIADB_BACKUP_RETENTION_DAYS:-14}"
today="$(date -u +%Y%m%d)"

if [[ ! "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || ((10#$BACKUP_RETENTION_DAYS < 1)); then
    echo "MARIADB_BACKUP_RETENTION_DAYS must be a positive integer" >&2
    exit 2
fi

acquire_cloud_compose_lifecycle_lock mariadb-backup

# A backup timer must not turn on an application that an operator deliberately
# stopped. Holding the lifecycle lock closes the race with a concurrent stop or
# rollout before this state check.
if ! systemctl is-active --quiet cloud-compose.service; then
    echo "Cloud Compose application service is inactive; skipping MariaDB backup"
    exit 0
fi

backup_app() (
    local app="$1"
    local backup_dir output staging_dir staging_output

    source_compose_app_env "$app"
    backup_dir="${BACKUP_ROOT}/${app}"
    if [[ -L "$BACKUP_ROOT" || ( -e "$BACKUP_ROOT" && ! -d "$BACKUP_ROOT" ) ]]; then
        echo "MariaDB backup root is unsafe: $BACKUP_ROOT" >&2
        return 1
    fi
    mkdir -p -- "$backup_dir"
    if [[ -L "$backup_dir" || ! -d "$backup_dir" ]]; then
        echo "MariaDB backup directory is unsafe: $backup_dir" >&2
        return 1
    fi

    # The app key is already constrained to a safe basename by the project
    # manifest, so it cannot change the backup destination.
    output="${backup_dir}/${today}-${app}.sql.gz"
    if [[ -e "$output" || -L "$output" ]]; then
        if [[ ! -L "$output" && -f "$output" && -s "$output" ]] && gzip -t -- "$output"; then
            echo "MariaDB backup already exists for ${app}: ${output}"
            return 0
        fi
        echo "Existing MariaDB backup is incomplete or unsafe: $output" >&2
        return 1
    fi

    staging_dir="$(mktemp -d "${backup_dir}/.${today}-${app}.staging.XXXXXX")" || return 1
    trap 'rm -rf -- "$staging_dir"' EXIT
    staging_output="${staging_dir}/backup.sql.gz"

    echo "Running MariaDB backup for ${app}"
    sitectl mariadb backup \
        --context "$SITECTL_CONTEXT_NAME" \
        --gzip \
        --output "$staging_output"
    if [[ -L "$staging_output" || ! -f "$staging_output" || ! -s "$staging_output" ]] ||
        ! gzip -t -- "$staging_output"; then
        echo "MariaDB backup did not produce a valid gzip artifact for ${app}" >&2
        return 1
    fi
    chmod 0640 "$staging_output" || return 1
    if [[ -e "$output" || -L "$output" ]]; then
        echo "MariaDB backup target appeared during staging: $output" >&2
        return 1
    fi
    mv -- "$staging_output" "$output" || return 1
    if [[ -L "$output" || ! -f "$output" || ! -s "$output" ]] || ! gzip -t -- "$output"; then
        echo "MariaDB backup was not published as a valid artifact for ${app}: ${output}" >&2
        return 1
    fi
    echo "MariaDB backup completed for ${app}: ${output}"
)

apps=()
compose_app_names_array apps
failures=0
for app in "${apps[@]}"; do
    if ! backup_app "$app"; then
        echo "MariaDB backup failed for ${app}; continuing with remaining apps" >&2
        failures=$((failures + 1))
    fi
done

# Prune only regular, non-symlink dump files beneath each validated app
# directory. This keeps a broken or high-churn app from filling the shared data
# disk and taking down its bin-packed neighbors.
for app in "${apps[@]}"; do
    backup_dir="${BACKUP_ROOT}/${app}"
    [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || continue
    find "$backup_dir" -xdev -type f -name '*.sql.gz' -mtime "+${BACKUP_RETENTION_DAYS}" -delete
done

if ((failures > 0)); then
    echo "MariaDB backup completed with ${failures} failed app(s)" >&2
    exit 1
fi
