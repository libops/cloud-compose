#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup_script="$repo_root/rootfs/home/cloud-compose/offhost-backup.sh"
restore_script="$repo_root/rootfs/home/cloud-compose/restore-test.sh"
fixture_root="$repo_root/ci/testdata/disaster-recovery"
tmp="$(mktemp -d "$repo_root/.disaster-recovery-contract.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "disaster recovery contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/data/projects/alpha/files" "$tmp/data/backups/mariadb/alpha" "$tmp/drivers"
chmod 0755 "$tmp" "$tmp/bin" "$tmp/data" "$tmp/data/projects" "$tmp/data/projects/alpha" "$tmp/data/projects/alpha/files" "$tmp/drivers"

/usr/bin/install -m 0644 "$fixture_root/profile.sh" "$tmp/profile.sh"
/usr/bin/install -m 0644 "$fixture_root/compose-apps.sh" "$tmp/compose-apps.sh"
/usr/bin/install -m 0755 "$fixture_root/fake-stat.sh" "$tmp/bin/stat"
/usr/bin/install -m 0755 "$fixture_root/fake-install.sh" "$tmp/bin/install"
/usr/bin/install -m 0755 "$fixture_root/fake-docker.sh" "$tmp/bin/docker"
/usr/bin/install -m 0644 "$fixture_root/fake-compose-config.jq" "$tmp/bin/fake-compose-config.jq"
/usr/bin/install -m 0755 "$fixture_root/good-driver.sh" "$tmp/drivers/good-driver"
/usr/bin/install -m 0755 "$fixture_root/incomplete-driver.sh" "$tmp/drivers/incomplete-driver"
/usr/bin/install -m 0644 \
  "$fixture_root/good-backup-receipt.jq" \
  "$fixture_root/good-restore-proof.jq" \
  "$fixture_root/incomplete-backup-receipt.jq" \
  "$tmp/drivers/"
printf 'logical database\n' | gzip -c >"$tmp/data/backups/mariadb/alpha/$(date -u +%Y%m%d)-alpha.sql.gz"

export TEST_BIN="$tmp/bin"
export TEST_DATA_ROOT="$tmp/data"
export LOCK_LOG="$tmp/lock.log"
export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
export CLOUD_COMPOSE_COMPOSE_APPS_PATH="$tmp/compose-apps.sh"
export CLOUD_COMPOSE_DR_LIBRARY_PATH="$repo_root/rootfs/home/cloud-compose/disaster-recovery-lib.sh"
export CLOUD_COMPOSE_DR_STATE_ROOT="$tmp/data/dr"
export CLOUD_COMPOSE_JQ_PROGRAM_DIR="$repo_root/rootfs/etc/cloud-compose/jq"
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
jq -e -f "$fixture_root/assert-coverage-manifest.jq" "$manifest" >/dev/null || \
  fail "coverage manifest omitted database, application files, or volume topology"

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
jq -e -f "$fixture_root/assert-restore-proof.jq" "$proof" >/dev/null || \
  fail "restore proof omitted required recovery evidence"

rm -f -- "$tmp/data/backups/mariadb/alpha/$(date -u +%Y%m%d)-alpha.sql.gz"
calls_before="$(wc -l <"$tmp/drivers/good-driver.calls")"
if bash "$backup_script" >/dev/null 2>&1; then
  fail "required DR coverage succeeded without a database artifact"
fi
[[ "$(wc -l <"$tmp/drivers/good-driver.calls")" == "$calls_before" ]] || \
  fail "driver ran before required local coverage was validated"

CLOUD_COMPOSE_OFFHOST_BACKUP_REQUIRED=false bash "$backup_script" >/dev/null
echo "Disaster recovery contract passed"
