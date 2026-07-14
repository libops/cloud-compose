#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
compose_apps_path="${CLOUD_COMPOSE_COMPOSE_APPS_PATH:-$script_dir/compose-apps.sh}"
# shellcheck disable=SC1090
source "$profile_path"
# shellcheck disable=SC1090
source "$compose_apps_path"

BACKUP_ROOT="${MARIADB_BACKUP_ROOT:-/mnt/disks/data/backups/mariadb}"
today="$(date -u +%Y%m%d)"

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
    chmod 0640 "$staging_output"
    if [[ -e "$output" || -L "$output" ]]; then
        echo "MariaDB backup target appeared during staging: $output" >&2
        return 1
    fi
    mv -- "$staging_output" "$output"
    echo "MariaDB backup completed for ${app}: ${output}"
)

apps=()
compose_app_names_array apps
for app in "${apps[@]}"; do
    backup_app "$app"
done
