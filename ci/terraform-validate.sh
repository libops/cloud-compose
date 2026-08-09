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

validate_public_provider_graph() {
  local root="$1" data_dir="$2" rel="$3"
  local expected_sources provider_graph actual_sources

  case "$rel" in
    . | providers/gcp)
      expected_sources=$'hashicorp/cloudinit\nhashicorp/google\nhashicorp/http\nhashicorp/time'
      ;;
    providers/do)
      expected_sources=$'digitalocean/digitalocean\nhashicorp/http'
      ;;
    providers/linode)
      expected_sources=$'hashicorp/http\nlinode/linode'
      ;;
    *)
      return 0
      ;;
  esac

  if ! provider_graph="$(TF_DATA_DIR="$data_dir" terraform -chdir="$root" providers)"; then
    echo "Failed to read Terraform provider graph in ${rel}" >&2
    return 1
  fi
  actual_sources="$({
    sed -n 's/.*provider\[registry\.terraform\.io\/\([^]]*\)\].*/\1/p' <<<"$provider_graph"
  } | sort -u)"
  if [[ "$actual_sources" != "$expected_sources" ]]; then
    echo "Unexpected Terraform provider graph in ${rel}" >&2
    echo "Expected:" >&2
    printf '%s\n' "$expected_sources" >&2
    echo "Actual:" >&2
    printf '%s\n' "$actual_sources" >&2
    return 1
  fi
}

validate_root() {
  local root="$1" data_root="$2"
  local rel data_dir lockfile created_lock init_status validate_status provider_status test_status
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
    else
      init_status=$?
    fi
    if [[ "$attempt" -lt 3 ]]; then
      echo "terraform init failed in ${rel}; retrying in $((attempt * 10))s (attempt ${attempt}/3)" >&2
      sleep $((attempt * 10))
    fi
  done

  validate_status=0
  if [[ "$init_status" -eq 0 ]]; then
    TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate -no-color || validate_status=$?
  fi

  provider_status=0
  if [[ "$init_status" -eq 0 && "$validate_status" -eq 0 ]]; then
    validate_public_provider_graph "$root" "$data_dir" "$rel" || provider_status=$?
  fi

  test_status=0
  if [[ "$init_status" -eq 0 && "$validate_status" -eq 0 && "$provider_status" -eq 0 ]] && find "$root" -maxdepth 1 -name '*.tftest.hcl' -print -quit | grep -q .; then
    TF_DATA_DIR="$data_dir" terraform -chdir="$root" test -no-color || test_status=$?
  fi

  if [[ "$created_lock" == "true" ]]; then
    rm -f "$lockfile"
  fi

  if [[ "$init_status" -ne 0 ]]; then
    return "$init_status"
  fi
  if [[ "$validate_status" -ne 0 ]]; then
    return "$validate_status"
  fi
  if [[ "$provider_status" -ne 0 ]]; then
    return "$provider_status"
  fi
  return "$test_status"
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
