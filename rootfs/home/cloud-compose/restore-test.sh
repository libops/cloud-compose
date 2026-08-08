#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"
dr_library_path="${CLOUD_COMPOSE_DR_LIBRARY_PATH:-$script_dir/disaster-recovery-lib.sh}"
jq_program_dir="${CLOUD_COMPOSE_JQ_PROGRAM_DIR:-/etc/cloud-compose/jq}"
# shellcheck disable=SC1090
source "$profile_path"
CLOUD_COMPOSE_JQ_PROGRAM_DIR="$jq_program_dir"
# shellcheck disable=SC1090
source "$dr_library_path"

if cloud_compose_dr_is_required; then
    :
else
    status=$?
    if ((status == 1)); then
        echo "Off-host disaster recovery is not required; skipping scheduled restore test"
        exit 0
    fi
    exit "$status"
fi

driver="$CLOUD_COMPOSE_OFFHOST_BACKUP_DRIVER"
state_root="$CLOUD_COMPOSE_DR_STATE_ROOT"
manifest_dir="$state_root/manifests"
receipt_dir="$state_root/backup-receipts"
proof_dir="$state_root/restore-proofs"
staging_root="$state_root/staging"
staging_dir=""

cleanup() {
    if [[ -n "$staging_dir" ]]; then
        rm -rf -- "$staging_dir"
    fi
}
trap cleanup EXIT

cloud_compose_dr_validate_driver "$driver"
for path in "$state_root" "$manifest_dir" "$receipt_dir" "$proof_dir" "$staging_root"; do
    cloud_compose_dr_prepare_state_directory "$path"
done

latest_receipt="$(find "$receipt_dir" -xdev -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort | tail -n 1)"
if [[ -z "$latest_receipt" ]]; then
    echo "Scheduled restore test requires a validated off-host backup receipt" >&2
    exit 1
fi
operation_id="${latest_receipt%.json}"
if [[ ! "$operation_id" =~ ^[0-9]{8}-[a-z][a-z0-9-]*$ ]]; then
    echo "Latest off-host backup receipt has an unsafe operation id" >&2
    exit 1
fi
receipt_path="$receipt_dir/$latest_receipt"
manifest_path="$manifest_dir/$latest_receipt"
if [[ -L "$manifest_path" || ! -f "$manifest_path" ]]; then
    echo "Scheduled restore test is missing the source coverage manifest" >&2
    exit 1
fi
cloud_compose_dr_validate_json_file "$manifest_path" "Off-host backup manifest"
manifest_sha256="$(sha256sum "$manifest_path" | awk '{print $1}')"
cloud_compose_dr_validate_backup_receipt "$receipt_path" "$operation_id" "$manifest_sha256"
receipt_sha256="$(sha256sum "$receipt_path" | awk '{print $1}')"

test_id="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
staging_dir="$(mktemp -d "$staging_root/.restore-${test_id}.XXXXXX")"
chmod 0700 "$staging_dir"
staged_proof="$staging_dir/proof.json"

cloud_compose_dr_run_driver "$driver" restore-test \
    --manifest "$manifest_path" \
    --backup-receipt "$receipt_path" \
    --source-manifest-sha256 "$manifest_sha256" \
    --source-receipt-sha256 "$receipt_sha256" \
    --test-id "$test_id" \
    --proof "$staged_proof"
cloud_compose_dr_validate_restore_proof \
    "$staged_proof" "$test_id" "$manifest_sha256" "$receipt_sha256"

proof_path="$proof_dir/${test_id}.json"
chmod 0640 "$staged_proof"
mv -- "$staged_proof" "$proof_path"
echo "Disposable restore test proved database, application-file, and volume-topology recovery: $proof_path"
