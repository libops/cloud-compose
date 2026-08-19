#!/usr/bin/env bash

set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
      --arg manifest_sha256 "${args[--manifest-sha256]}" \
      -f "$fixture_dir/good-backup-receipt.jq" >"${args[--receipt]}"
    ;;
  restore-test)
    jq -cn \
      --arg test_id "${args[--test-id]}" \
      --arg manifest_sha256 "${args[--source-manifest-sha256]}" \
      --arg receipt_sha256 "${args[--source-receipt-sha256]}" \
      -f "$fixture_dir/good-restore-proof.jq" >"${args[--proof]}"
    ;;
  *) exit 64 ;;
esac
