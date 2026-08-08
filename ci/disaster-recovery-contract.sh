#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup_script="$repo_root/rootfs/home/cloud-compose/offhost-backup.sh"
restore_script="$repo_root/rootfs/home/cloud-compose/restore-test.sh"
tmp="$(mktemp -d "$repo_root/.disaster-recovery-contract.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "disaster recovery contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/data/projects/alpha/files" "$tmp/data/backups/mariadb/alpha" "$tmp/drivers"
chmod 0755 "$tmp" "$tmp/bin" "$tmp/data" "$tmp/data/projects" "$tmp/data/projects/alpha" "$tmp/data/projects/alpha/files" "$tmp/drivers"

cat >"$tmp/profile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="${TEST_BIN:?}:/usr/bin:/bin"
acquire_cloud_compose_lifecycle_lock() {
  printf '%s\n' "$1" >>"${LOCK_LOG:?}"
}
EOF

cat >"$tmp/compose-apps.sh" <<'EOF'
#!/usr/bin/env bash
compose_app_names_array() {
  local -n result="$1"
  result=(alpha)
}
source_compose_app_env() {
  DOCKER_COMPOSE_DIR="${TEST_DATA_ROOT:?}/projects/$1"
  export DOCKER_COMPOSE_DIR
}
validate_compose_project_dir() {
  [[ "$1" == "${TEST_DATA_ROOT:?}/projects/"* ]]
}
EOF

cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output="$(/usr/bin/stat "$@")"
if [[ "$*" == *"%u:"* ]]; then
  printf '0:%s\n' "${output#*:}"
else
  printf '%s\n' "$output"
fi
EOF

cat >"$tmp/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while (($# > 0)); do
  case "$1" in
    -o|-g)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "compose config --format json" ]]
jq -cn --arg root "${TEST_DATA_ROOT:?}" '{
  services: {
    web: {
      volumes: [
        {type: "bind", source: ($root + "/projects/alpha/files"), target: "/srv/files", read_only: false},
        {type: "volume", source: "alpha_data", target: "/var/lib/app", read_only: false},
        {type: "tmpfs", source: "", target: "/run/app", read_only: false}
      ]
    }
  },
  volumes: {alpha_data: {name: "alpha_data"}}
}'
EOF

cat >"$tmp/drivers/good-driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${SHOULD_NOT_REACH_DRIVER+x}" ]] || exit 90
printf '%s\n' "$1" >>"${0}.calls"
operation="$1"
shift
declare -A args=()
while (($# > 0)); do
  args["$1"]="$2"
  shift 2
done
case "$operation" in
  backup)
    jq -cn \
      --arg operation_id "${args[--operation-id]}" \
      --arg manifest_sha256 "${args[--manifest-sha256]}" '{
        schema_version: 1,
        kind: "cloud-compose.offhost-backup-receipt",
        operation_id: $operation_id,
        completed_at: "2026-08-07T12:00:00Z",
        manifest_sha256: $manifest_sha256,
        encrypted: true,
        off_host: true,
        status: "succeeded",
        remote_id: "contract/backup-1",
        coverage: {database: true, application_files: true, volume_topology: true}
      }' >"${args[--receipt]}"
    ;;
  restore-test)
    jq -cn \
      --arg test_id "${args[--test-id]}" \
      --arg manifest_sha256 "${args[--source-manifest-sha256]}" \
      --arg receipt_sha256 "${args[--source-receipt-sha256]}" '{
        schema_version: 1,
        kind: "cloud-compose.restore-test-proof",
        test_id: $test_id,
        completed_at: "2026-08-07T13:00:00Z",
        source_manifest_sha256: $manifest_sha256,
        source_receipt_sha256: $receipt_sha256,
        source_encrypted: true,
        status: "succeeded",
        recovery_id: "contract/recovery-1",
        disposable_recovery: true,
        recovery_destroyed: true,
        integrity_verified: true,
        coverage: {database: true, application_files: true, volume_topology: true}
      }' >"${args[--proof]}"
    ;;
  *) exit 64 ;;
esac
EOF

cat >"$tmp/drivers/incomplete-driver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
operation="$1"
shift
declare -A args=()
while (($# > 0)); do
  args["$1"]="$2"
  shift 2
done
[[ "$operation" == "backup" ]]
jq -cn \
  --arg operation_id "${args[--operation-id]}" \
  --arg manifest_sha256 "${args[--manifest-sha256]}" '{
    schema_version: 1,
    kind: "cloud-compose.offhost-backup-receipt",
    operation_id: $operation_id,
    completed_at: "2026-08-07T12:00:00Z",
    manifest_sha256: $manifest_sha256,
    encrypted: true,
    off_host: true,
    status: "succeeded",
    remote_id: "contract/incomplete",
    coverage: {database: true, application_files: true, volume_topology: false}
  }' >"${args[--receipt]}"
EOF

chmod 0755 "$tmp/bin/stat" "$tmp/bin/install" "$tmp/bin/docker" "$tmp/drivers/good-driver" "$tmp/drivers/incomplete-driver"
printf 'logical database\n' | gzip -c >"$tmp/data/backups/mariadb/alpha/$(date -u +%Y%m%d)-alpha.sql.gz"

export TEST_BIN="$tmp/bin"
export TEST_DATA_ROOT="$tmp/data"
export LOCK_LOG="$tmp/lock.log"
export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
export CLOUD_COMPOSE_COMPOSE_APPS_PATH="$tmp/compose-apps.sh"
export CLOUD_COMPOSE_DR_LIBRARY_PATH="$repo_root/rootfs/home/cloud-compose/disaster-recovery-lib.sh"
export CLOUD_COMPOSE_DR_STATE_ROOT="$tmp/data/dr"
export CLOUD_COMPOSE_DATA_ROOT="$tmp/data"
export CLOUD_COMPOSE_VOLUMES_ROOT="$tmp/data/volumes"
export MARIADB_BACKUP_ROOT="$tmp/data/backups/mariadb"
export CLOUD_COMPOSE_INSTANCE_NAME="contract-site"
export CLOUD_COMPOSE_PROVIDER="contract"
export CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED="true"
export CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER="$tmp/drivers/good-driver"
export SHOULD_NOT_REACH_DRIVER="terraform-secret"
: >"$LOCK_LOG"

bash "$backup_script"
receipt="$(find "$CLOUD_COMPOSE_DR_STATE_ROOT/backup-receipts" -maxdepth 1 -type f -name '*.json' -print -quit)"
manifest="$(find "$CLOUD_COMPOSE_DR_STATE_ROOT/manifests" -maxdepth 1 -type f -name '*.json' -print -quit)"
[[ -n "$receipt" && -n "$manifest" ]] || fail "successful driver did not publish its atomic manifest and receipt"
jq -e '
  .required_coverage == ["database", "application_files", "volume_topology"] and
  (.applications | length == 1) and
  (.applications[0].databases | length == 1) and
  .applications[0].application_files.roots == [env.TEST_DATA_ROOT + "/projects/alpha"] and
  .applications[0].volume_topology.declared_named_volumes == ["alpha_data"] and
  (.applications[0].volume_topology.service_mounts | length == 3)
' "$manifest" >/dev/null || fail "coverage manifest omitted database, application files, or volume topology"

# A second attempt sees the same already-existing daily dump but must still
# invoke off-host transfer, allowing a failed first handoff to be retried.
bash "$backup_script"
[[ "$(grep -c '^backup$' "$tmp/drivers/good-driver.calls")" == "2" ]] || \
  fail "nightly flow skipped off-host transfer when the daily dump already existed"

published_receipt_sha="$(sha256sum "$receipt" | awk '{print $1}')"
export CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER="$tmp/drivers/incomplete-driver"
if bash "$backup_script" >/dev/null 2>&1; then
  fail "driver receipt without complete volume coverage was accepted"
fi
[[ "$(sha256sum "$receipt" | awk '{print $1}')" == "$published_receipt_sha" ]] || \
  fail "invalid driver output replaced the last validated receipt"

export CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER="$tmp/drivers/good-driver"
bash "$restore_script"
proof="$(find "$CLOUD_COMPOSE_DR_STATE_ROOT/restore-proofs" -maxdepth 1 -type f -name '*.json' -print -quit)"
[[ -n "$proof" ]] || fail "scheduled disposable restore test did not publish proof"
jq -e '
  .disposable_recovery == true and
  .recovery_destroyed == true and
  .integrity_verified == true and
  .coverage == {database: true, application_files: true, volume_topology: true}
' "$proof" >/dev/null || fail "restore proof omitted required recovery evidence"

rm -f -- "$tmp/data/backups/mariadb/alpha/$(date -u +%Y%m%d)-alpha.sql.gz"
calls_before="$(wc -l <"$tmp/drivers/good-driver.calls")"
if bash "$backup_script" >/dev/null 2>&1; then
  fail "required DR coverage succeeded without a database artifact"
fi
[[ "$(wc -l <"$tmp/drivers/good-driver.calls")" == "$calls_before" ]] || \
  fail "driver ran before required local coverage was validated"

CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED=false bash "$backup_script" >/dev/null
echo "Disaster recovery contract passed"
