#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
# shellcheck disable=SC1091
source /home/cloud-compose/compose-apps.sh

BACKUP_ROOT="${MARIADB_BACKUP_ROOT:-/mnt/disks/data/backups/mariadb}"
today="$(date -u +%Y%m%d)"

while read -r app; do
    if [ -z "$app" ]; then
        continue
    fi

    source_compose_app_env "$app"
    backup_dir="${BACKUP_ROOT}/${app}"
    mkdir -p "$backup_dir"

    output="${backup_dir}/${today}-${SITECTL_CONTEXT_NAME}.sql.gz"
    if [ -f "$output" ]; then
        echo "MariaDB backup already exists for ${app}: ${output}"
        continue
    fi

    echo "Running MariaDB backup for ${app}"
    sitectl mariadb backup \
        --context "$SITECTL_CONTEXT_NAME" \
        --gzip \
        --output "$output"
done < <(compose_app_names)
