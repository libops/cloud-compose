#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cleanup_data_root=""

cleanup() {
  if [[ -n "${cleanup_data_root:-}" ]]; then
    rm -rf "$cleanup_data_root"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

safe_name() {
  local value="$1"
  value="${value//\//_}"
  value="${value// /_}"
  printf '%s\n' "$value"
}

validate_root() {
  local root="$1" data_root="$2"
  local rel data_dir lockfile created_lock init_status validate_status
  local -a init_args

  rel="${root#"$repo_root"/}"
  if [[ "$root" == "$repo_root" ]]; then
    rel="."
  fi

  data_dir="${data_root}/$(safe_name "$rel")"
  lockfile="${root}/.terraform.lock.hcl"
  created_lock=false
  init_args=(-backend=false -input=false)

  if [[ -f "$lockfile" ]]; then
    init_args+=(-lockfile=readonly)
  else
    created_lock=true
  fi

  echo "Validating Terraform in ${rel}"

  init_status=0
  for attempt in 1 2 3; do
    if TF_DATA_DIR="$data_dir" terraform -chdir="$root" init "${init_args[@]}" >/dev/null; then
      init_status=0
      break
    fi
    init_status=$?
    if [[ "$attempt" -lt 3 ]]; then
      echo "terraform init failed in ${rel}; retrying in $((attempt * 10))s (attempt ${attempt}/3)" >&2
      sleep $((attempt * 10))
    fi
  done

  validate_status=0
  if [[ "$init_status" -eq 0 ]]; then
    TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate -no-color || validate_status=$?
  fi

  if [[ "$created_lock" == "true" ]]; then
    rm -f "$lockfile"
  fi

  if [[ "$init_status" -ne 0 ]]; then
    return "$init_status"
  fi
  return "$validate_status"
}

main() {
  local data_root cleanup
  local -a roots

  require_cmd terraform

  if [[ -n "${TF_VALIDATE_DATA_ROOT:-}" ]]; then
    data_root="$TF_VALIDATE_DATA_ROOT"
    cleanup=false
    mkdir -p "$data_root"
  else
    data_root="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-terraform-validate.XXXXXX")"
    cleanup=true
  fi

  if [[ "$cleanup" == "true" ]]; then
    cleanup_data_root="$data_root"
    trap cleanup EXIT
  fi

  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$data_root/plugin-cache}"
  mkdir -p "$TF_PLUGIN_CACHE_DIR"

  mapfile -t roots < <(
    find "$repo_root" \
      -path "*/.terraform" -prune -o \
      -path "$repo_root/docs/site" -prune -o \
      -name "*.tf" -printf '%h\n' |
      sort -u
  )

  if [[ "${#roots[@]}" -eq 0 ]]; then
    echo "No Terraform files found"
    return 0
  fi

  for root in "${roots[@]}"; do
    validate_root "$root" "$data_root"
  done
}

main "$@"
