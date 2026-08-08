#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
compose_apps_path="${CLOUD_COMPOSE_COMPOSE_APPS_PATH:-$script_dir/compose-apps.sh}"
dr_library_path="${CLOUD_COMPOSE_DR_LIBRARY_PATH:-$script_dir/disaster-recovery-lib.sh}"
# shellcheck disable=SC1090
source "$profile_path"
# shellcheck disable=SC1090
source "$compose_apps_path"
# shellcheck disable=SC1090
source "$dr_library_path"

if cloud_compose_dr_is_required; then
    :
else
    status=$?
    if ((status == 1)); then
        echo "Off-host disaster recovery is not required; local MariaDB dumps remain same-disk recovery artifacts only"
        exit 0
    fi
    exit "$status"
fi

driver="$CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER"
backup_root="${MARIADB_BACKUP_ROOT:-/mnt/disks/data/backups/mariadb}"
data_root="${CLOUD_COMPOSE_DATA_ROOT:-/mnt/disks/data}"
volumes_root="${CLOUD_COMPOSE_VOLUMES_ROOT:-/mnt/disks/volumes}"
backup_date="$(date -u +%Y%m%d)"
operation_id="${backup_date}-${CLOUD_COMPOSE_INSTANCE_NAME:-cloud-compose}"
state_root="$CLOUD_COMPOSE_DR_STATE_ROOT"
manifest_dir="$state_root/manifests"
receipt_dir="$state_root/backup-receipts"
staging_root="$state_root/staging"
manifest_path="$manifest_dir/${operation_id}.json"
receipt_path="$receipt_dir/${operation_id}.json"
staging_dir=""

cleanup() {
    if [[ -n "$staging_dir" ]]; then
        rm -rf -- "$staging_dir"
    fi
}
trap cleanup EXIT

cloud_compose_dr_validate_driver "$driver"
acquire_cloud_compose_lifecycle_lock offhost-backup

for path in "$state_root" "$manifest_dir" "$receipt_dir" "$staging_root"; do
    cloud_compose_dr_prepare_state_directory "$path"
done

staging_dir="$(mktemp -d "$staging_root/.${operation_id}.XXXXXX")"
chmod 0700 "$staging_dir"
application_rows="$staging_dir/applications.jsonl"
: >"$application_rows"
chmod 0600 "$application_rows"

apps=()
compose_app_names_array apps
if ((${#apps[@]} == 0)); then
    echo "Off-host backup requires at least one compose application" >&2
    exit 1
fi

for app in "${apps[@]}"; do
    source_compose_app_env "$app"
    project_dir="$DOCKER_COMPOSE_DIR"
    dump_path="${backup_root}/${app}/${backup_date}-${app}.sql.gz"
    staged_dump="$staging_dir/${app}.sql.gz"
    compose_config="$staging_dir/${app}.compose-config.json"
    application_row="$staging_dir/${app}.coverage.json"

    validate_compose_project_dir "$project_dir"
    if [[ -L "$project_dir" || ! -d "$project_dir" ]]; then
        echo "Application checkout is missing or unsafe for ${app}: $project_dir" >&2
        exit 1
    fi
    if [[ -L "$dump_path" || ! -f "$dump_path" || ! -s "$dump_path" ]]; then
        echo "Required local MariaDB recovery artifact is missing or unsafe for ${app}" >&2
        exit 1
    fi
    if [[ "$(stat -c '%h:%F' -- "$dump_path")" != "1:regular file" ]]; then
        echo "Required local MariaDB recovery artifact must have one link for ${app}" >&2
        exit 1
    fi

    # Copy through an already-open descriptor into the root-only handoff. This
    # prevents the privileged driver from following a later path replacement in
    # the application-owned local-backup directory.
    exec {dump_fd}<"$dump_path"
    dump_identity="$(stat -Lc '%d:%i' -- "/proc/${BASHPID}/fd/${dump_fd}")"
    if [[ "$(stat -c '%d:%i' -- "$dump_path")" != "$dump_identity" ]]; then
        echo "Local MariaDB recovery artifact changed while opening for ${app}" >&2
        exit 1
    fi
    cat <&"$dump_fd" >"$staged_dump"
    exec {dump_fd}<&-
    chmod 0400 "$staged_dump"
    if [[ ! -s "$staged_dump" ]] || ! gzip -t -- "$staged_dump"; then
        echo "Required local MariaDB recovery artifact is invalid for ${app}" >&2
        exit 1
    fi
    dump_sha256="$(sha256sum "$staged_dump" | awk '{print $1}')"
    dump_bytes="$(wc -c <"$staged_dump")"

    (
        cd -- "$project_dir"
        umask 077
        docker compose config --format json >"$compose_config"
    )
    if ! jq -e '
        type == "object" and
        (.services | type == "object" and length > 0) and
        all(.services | to_entries[];
          ((.value.volumes // []) | type == "array") and
          all((.value.volumes // [])[];
            type == "object" and
            (.type | type == "string") and
            (.type == "volume" or .type == "bind" or .type == "tmpfs") and
            ((.source // "") | type == "string") and
            ((.target // "") | type == "string" and length > 0))) and
        ((.volumes // {}) | type == "object")
    ' "$compose_config" >/dev/null; then
        echo "Docker Compose returned unsafe or unsupported volume topology for ${app}" >&2
        exit 1
    fi
    if ! jq -e --arg data_root "$data_root" --arg volumes_root "$volumes_root" '
        all(.services[].volumes[]?;
          .type != "bind" or
          (.source | type == "string" and
            (. == $data_root or startswith($data_root + "/") or
             . == $volumes_root or startswith($volumes_root + "/")) and
            (explode | all(.[]; . >= 32 and . != 127)) and
            (contains("//") | not) and
            length > 0))
    ' "$compose_config" >/dev/null; then
        echo "Persistent bind topology escapes managed data roots for ${app}" >&2
        exit 1
    fi
    while IFS= read -r bind_source; do
        if [[ "$bind_source" =~ (^|/)\.\.?(/|$) ]]; then
            echo "Persistent bind topology contains a dot segment for ${app}" >&2
            exit 1
        fi
    done < <(jq -r '.services[].volumes[]? | select(.type == "bind") | .source' "$compose_config")

    jq -cS \
        --arg app "$app" \
        --arg project_dir "$project_dir" \
        --arg dump_path "$staged_dump" \
        --arg dump_sha256 "$dump_sha256" \
        --argjson dump_bytes "$dump_bytes" '
        {
          name: $app,
          databases: [{
            engine: "mariadb",
            format: "sql.gz",
            local_recovery_artifact: $dump_path,
            sha256: $dump_sha256,
            bytes: $dump_bytes
          }],
          application_files: {
            roots: [$project_dir],
            bind_mounts: [
              .services | to_entries[] as $service |
              ($service.value.volumes // [])[] |
              select(.type == "bind") |
              {service: $service.key, source: .source, target: .target, read_only: (.read_only // false)}
            ] | sort_by(.service, .source, .target)
          },
          volume_topology: {
            declared_named_volumes: ((.volumes // {}) | keys | sort),
            service_mounts: [
              .services | to_entries[] as $service |
              ($service.value.volumes // [])[] |
              {service: $service.key, type: .type, source: (.source // ""), target: .target, read_only: (.read_only // false)}
            ] | sort_by(.service, .type, .source, .target)
          }
        }
    ' "$compose_config" >"$application_row"
    cat "$application_row" >>"$application_rows"
    rm -f -- "$compose_config"
done

staged_manifest="$staging_dir/manifest.json"
jq -cS -s \
    --arg operation_id "$operation_id" \
    --arg backup_date "$backup_date" \
    --arg provider "${CLOUD_COMPOSE_PROVIDER:-unknown}" \
    --arg instance "${CLOUD_COMPOSE_INSTANCE_NAME:-cloud-compose}" '
    {
      schema_version: 1,
      kind: "cloud-compose.offhost-backup-manifest",
      operation_id: $operation_id,
      backup_date: $backup_date,
      provider: $provider,
      instance: $instance,
      required_coverage: ["database", "application_files", "volume_topology"],
      applications: (sort_by(.name))
    }
' "$application_rows" >"$staged_manifest"
chmod 0400 "$staged_manifest"

if ! jq -e --argjson app_count "${#apps[@]}" '
    .schema_version == 1 and
    .kind == "cloud-compose.offhost-backup-manifest" and
    (.applications | type == "array" and length == $app_count) and
    all(.applications[];
      (.name | type == "string" and length >= 1 and length <= 63 and
        (explode | all(.[]; . >= 32 and . != 127))) and
      (.databases | length == 1) and
      (.databases[0].sha256 | type == "string" and length == 64 and
        (explode | all(.[]; . >= 32 and . != 127))) and
      (.databases[0].bytes | type == "number" and . > 0) and
      (.application_files.roots | type == "array" and length > 0) and
      (.application_files.bind_mounts | type == "array") and
      (.volume_topology.declared_named_volumes | type == "array") and
      (.volume_topology.service_mounts | type == "array"))
' "$staged_manifest" >/dev/null; then
    echo "Generated off-host coverage manifest is incomplete" >&2
    exit 1
fi
while IFS=$'\t' read -r manifest_app manifest_sha; do
    if [[ ! "$manifest_app" =~ ^[a-z][a-z0-9-]*$ || ! "$manifest_sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Generated off-host coverage manifest contains an unsafe application name or digest" >&2
        exit 1
    fi
done < <(jq -r '.applications[] | [.name, .databases[0].sha256] | @tsv' "$staged_manifest")

manifest_sha256="$(sha256sum "$staged_manifest" | awk '{print $1}')"
staged_receipt="$staging_dir/receipt.json"
cloud_compose_dr_run_driver "$driver" backup \
    --manifest "$staged_manifest" \
    --manifest-sha256 "$manifest_sha256" \
    --operation-id "$operation_id" \
    --receipt "$staged_receipt"
if [[ "$(sha256sum "$staged_manifest" | awk '{print $1}')" != "$manifest_sha256" ]]; then
    echo "Off-host backup driver modified the immutable coverage manifest" >&2
    exit 1
fi
cloud_compose_dr_validate_backup_receipt "$staged_receipt" "$operation_id" "$manifest_sha256"

chmod 0640 "$staged_manifest" "$staged_receipt"
mv -f -- "$staged_manifest" "$manifest_path"
mv -f -- "$staged_receipt" "$receipt_path"
echo "Encrypted off-host disaster-recovery coverage proven for ${#apps[@]} application(s): $receipt_path"
