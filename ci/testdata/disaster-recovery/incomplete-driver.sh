#!/usr/bin/env bash

set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
  --arg manifest_sha256 "${args[--manifest-sha256]}" \
  -f "$fixture_dir/incomplete-backup-receipt.jq" >"${args[--receipt]}"
