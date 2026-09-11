#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# renovate: datasource=docker depName=python packageName=python versioning=docker
CONFIG_MANAGEMENT_IMAGE_DEFAULT="python:3.14-slim@sha256:cad9a2c871761c413caa6fdd6441c783451e740a48aaeba60ae62a8b53525ef6"

usage() {
  cat <<EOF
Usage:
  ci/config-management-cloud-smoke.sh all
  ci/config-management-cloud-smoke.sh ansible-drupal
  ci/config-management-cloud-smoke.sh salt-drupal
  ci/config-management-cloud-smoke.sh destroy-ansible-drupal
  ci/config-management-cloud-smoke.sh destroy-salt-drupal
  ci/config-management-cloud-smoke.sh sweep
  ci/config-management-cloud-smoke.sh sweep-ansible-drupal
  ci/config-management-cloud-smoke.sh sweep-salt-drupal

Required environment:
  LINODE_TOKEN
  CLOUD_COMPOSE_SMOKE_RUN_ID           Canonical GitHub Actions run id for every apply and scoped cleanup.

Optional environment:
  CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true
  CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=1200
  CLOUD_COMPOSE_SMOKE_CONFIG_MANAGEMENT_TIMEOUT=3600
  CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=1800
  CLOUD_COMPOSE_SMOKE_KEEP=true
  CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS=true
                                      Permit an explicit sweep to remove every run for a target.
  CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS=true
  CLOUD_COMPOSE_SMOKE_WORKDIR=.cloud-compose-smoke
  CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE=${CONFIG_MANAGEMENT_IMAGE_DEFAULT}
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "$1 is required" >&2
    exit 1
  fi
}

valid_target() {
  case "$1" in
    ansible-drupal | salt-drupal) return 0 ;;
    *) return 1 ;;
  esac
}

target_method() {
  local target="$1"
  valid_target "$target" || {
    echo "Unknown config-management smoke target: $target" >&2
    usage >&2
    exit 2
  }
  printf '%s\n' "${target%%-*}"
}

target_template() {
  local target="$1"
  target_method "$target" >/dev/null
  printf '%s\n' "${target#*-}"
}

default_targets() {
  printf '%s\n' "${CLOUD_COMPOSE_CONFIG_MANAGEMENT_CLOUD_TARGETS:-ansible-drupal salt-drupal}"
}

positive_integer_env() {
  local name="$1" default="$2" value

  value="${!name:-$default}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -eq 0 ]]; then
    echo "${name} must be a positive integer number of seconds" >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

boot_timeout_seconds() {
  positive_integer_env CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT 1200
}

destroy_timeout_seconds() {
  positive_integer_env CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT 1800
}

config_management_timeout_seconds() {
  positive_integer_env CLOUD_COMPOSE_SMOKE_CONFIG_MANAGEMENT_TIMEOUT 3600
}

smoke_run_id() {
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_RUN_ID:-${GITHUB_RUN_ID:-}}"
}

validate_smoke_run_id() {
  local run_id="$1" runner

  if [[ -z "$run_id" ]]; then
    echo "CLOUD_COMPOSE_SMOKE_RUN_ID is required for every config-management smoke apply" >&2
    return 1
  fi
  runner="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$runner" ]]; then
    echo "Missing compiled CI runner: ${runner}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi
  "$runner" run validate --run-id "$run_id"
}

target_workdir() {
  local target="$1"
  printf '%s/config-management-linode-%s\n' "${CLOUD_COMPOSE_SMOKE_WORKDIR:-$repo_root/.cloud-compose-smoke}" "$target"
}

ensure_key() {
  local key_path="$1"

  if [[ -L "$key_path" || ( -e "$key_path" && ! -f "$key_path" ) ]]; then
    echo "Config-management smoke SSH private-key path is unsafe: $key_path" >&2
    return 1
  fi
  if [[ -f "$key_path" ]]; then
    if [[ -L "${key_path}.pub" || ! -f "${key_path}.pub" ]]; then
      echo "Config-management smoke SSH public-key path is missing or unsafe: ${key_path}.pub" >&2
      return 1
    fi
    chmod 0600 "$key_path"
    return 0
  fi
  mkdir -p "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -N "" -C "cloud-compose-config-management-smoke" -f "$key_path" >/dev/null
  chmod 0600 "$key_path"
}

provider_tag_cleanup() {
  local target="$1" run_id="${2:-}" allow_all_runs="${3:-false}" cleanup_binary
  local -a cleanup_args

  cleanup_binary="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$cleanup_binary" ]]; then
    echo "Missing compiled CI runner: ${cleanup_binary}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi

  cleanup_args=(
    linode sweep
    --scope config-management
    --target "$target"
  )
  if [[ -n "$run_id" ]]; then
    cleanup_args+=(--run-id "$run_id")
  elif [[ "$allow_all_runs" == "true" ]]; then
    cleanup_args+=(--all-runs)
  else
    echo "Provider cleanup requires CLOUD_COMPOSE_SMOKE_RUN_ID; set CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS=true only for an intentional target-wide orphan sweep" >&2
    return 1
  fi

  "$cleanup_binary" "${cleanup_args[@]}"
}

scan_host_key() {
  local host="$1" known_hosts="$2"

  mkdir -p "$(dirname "$known_hosts")"
  touch "$known_hosts"
  chmod 0600 "$known_hosts"
  ssh-keyscan -H "$host" >>"$known_hosts" 2>/dev/null
}

ssh_cmd() {
  local home_dir="$1" key_path="$2" host="$3"
  shift 3

  ssh \
    -i "$key_path" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$home_dir/.ssh/known_hosts" \
    "root@${host}" \
    "$@"
}

wait_for_ssh() {
  local home_dir="$1" key_path="$2" host="$3"
  local timeout_seconds deadline attempt=1

  timeout_seconds="$(boot_timeout_seconds)"
  deadline=$((SECONDS + timeout_seconds))

  echo "Waiting for SSH on root@${host}:22"
  while (( SECONDS < deadline )); do
    scan_host_key "$host" "$home_dir/.ssh/known_hosts" || true
    if ssh_cmd "$home_dir" "$key_path" "$host" "true" >/dev/null 2>&1; then
      return 0
    fi
    echo "SSH not ready for ${host}; retrying in 15s (attempt ${attempt})"
    attempt=$((attempt + 1))
    sleep 15
  done

  echo "Timed out waiting for SSH on ${host}" >&2
  return 1
}

wait_for_cloud_init() {
  local home_dir="$1" key_path="$2" host="$3"
  local timeout_seconds deadline status_output

  timeout_seconds="$(boot_timeout_seconds)"
  deadline=$((SECONDS + timeout_seconds))

  echo "Waiting for raw host cloud-init on ${host}"
  while (( SECONDS < deadline )); do
    status_output="$(ssh_cmd "$home_dir" "$key_path" "$host" "if command -v cloud-init >/dev/null 2>&1; then cloud-init status --long 2>&1; else echo 'cloud-init not installed'; fi" 2>&1 || true)"
    printf '%s\n' "$status_output"
    if grep -q '^cloud-init not installed' <<<"$status_output"; then
      return 0
    fi
    if grep -q '^status: done' <<<"$status_output"; then
      return 0
    fi
    if grep -q '^status: error' <<<"$status_output"; then
      return 1
    fi
    sleep 20
  done

  echo "Timed out waiting for cloud-init on ${host}" >&2
  return 1
}

dump_remote_logs() {
  local home_dir="$1" key_path="$2" host="$3"
  local diagnostics_source="$repo_root/ci/remote/config-management-diagnostics.sh"
  local diagnostics_dir=/root/.cache/libops-ci
  local diagnostics_path="$diagnostics_dir/config-management-diagnostics.sh"

  echo "Dumping config-management smoke diagnostics from ${host}" >&2
  ssh_cmd "$home_dir" "$key_path" "$host" \
    "install -d -m 0700 $diagnostics_dir && install -m 0700 /dev/stdin $diagnostics_path" \
    <"$diagnostics_source" || return 0
  ssh_cmd "$home_dir" "$key_path" "$host" "$diagnostics_path" || true
}

target_var_args() {
  local key_path="$1" target="$2" public_key

  public_key="$(cat "${key_path}.pub")"
  printf '%s\0%s\0' "-var" "ssh_public_key=${public_key}"
  printf '%s\0%s\0' "-var" "method=$(target_method "$target")"
  printf '%s\0%s\0' "-var" "template=$(target_template "$target")"
  if [[ -n "$(smoke_run_id)" ]]; then
    printf '%s\0%s\0' "-var" "smoke_run_id=$(smoke_run_id)"
  fi
}

deploy_config_management() {
  local target="$1" key_path="$2" output_json="$3"
  local method host name template environment project_dir image deploy_timeout container_entrypoint

  method="$(jq -r '.method' "$output_json")"
  host="$(jq -r '.host' "$output_json")"
  name="$(jq -r '.cloud_compose_name' "$output_json")"
  template="$(jq -r '.app' "$output_json")"
  environment="$(jq -r '.environment' "$output_json")"
  project_dir="$(jq -r '.project_dir' "$output_json")"
  image="${CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE:-$CONFIG_MANAGEMENT_IMAGE_DEFAULT}"
  deploy_timeout="$(config_management_timeout_seconds)"
  container_entrypoint="$repo_root/ci/config-management-cloud-smoke-container.sh"
  [[ -f "$container_entrypoint" && ! -L "$container_entrypoint" ]] || {
    echo "Config-management smoke container entrypoint is missing or unsafe" >&2
    return 1
  }

  if [[ -L "$key_path" || ! -f "$key_path" ]]; then
    echo "Config-management smoke SSH private-key path is missing or unsafe: $key_path" >&2
    return 1
  fi
  key_path="$(cd -P -- "$(dirname -- "$key_path")" && pwd)/$(basename -- "$key_path")"
  if [[ "$key_path" == *,* ]]; then
    echo "Config-management smoke SSH private-key path cannot contain a comma: $key_path" >&2
    return 1
  fi

  echo "Deploying ${template} to ${host} with ${method}"
  # Stream only the committed source under test. Archiving the working tree
  # would also copy ignored Terraform state and the generated private key into
  # the helper container and, for Salt, onward to the provisioned VM.
  git -C "$repo_root" archive --format=tar HEAD |
    timeout --signal=TERM --kill-after=30s "${deploy_timeout}s" docker run --rm -i \
      --env "SMOKE_METHOD=${method}" \
      --env "SMOKE_HOST=${host}" \
      --env "SMOKE_NAME=${name}" \
      --env "SMOKE_TEMPLATE=${template}" \
      --env "SMOKE_ENVIRONMENT=${environment}" \
      --env "SMOKE_PROJECT_DIR=${project_dir}" \
      --mount "type=bind,src=${key_path},dst=/run/secrets/cloud-compose-ssh-key,readonly" \
      --mount "type=bind,src=${container_entrypoint},dst=/usr/local/libexec/cloud-compose-config-management-smoke,readonly" \
      --tmpfs /run \
      --tmpfs /tmp \
      "$image" \
      /usr/local/libexec/cloud-compose-config-management-smoke
}

require_run_commands() {
  require_cmd docker
  require_cmd git
  require_cmd jq
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd ssh-keyscan
  require_cmd terraform
  require_cmd timeout
}

require_destroy_commands() {
  require_cmd ssh-keygen
  require_cmd terraform
}

require_sweep_commands() {
  local cleanup_binary

  cleanup_binary="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$cleanup_binary" ]]; then
    echo "Missing compiled CI runner: ${cleanup_binary}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi
}

run_target() (
  set -euo pipefail

  local target="$1" root workdir key_path home_dir output_json host run_id
  local -a auto_args var_args

  valid_target "$target" || {
    echo "Unknown config-management smoke target: $target" >&2
    exit 2
  }
  require_env LINODE_TOKEN

  root="$repo_root/tests/smoke/config-management-linode"
  workdir="$(target_workdir "$target")"
  key_path="$workdir/id_ed25519"
  home_dir="$workdir/home"
  output_json="$workdir/smoke.json"
  mkdir -p "$workdir" "$home_dir/.ssh"
  chmod 0700 "$home_dir/.ssh"

  ensure_key "$key_path"
  run_id="$(smoke_run_id)"
  validate_smoke_run_id "$run_id"
  mapfile -d '' -t var_args < <(target_var_args "$key_path" "$target")

  auto_args=()
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CLOUD_COMPOSE_SMOKE_AUTO_APPROVE:-}" == "true" ]]; then
    auto_args=(-auto-approve)
  fi

  cleanup_started=false
  # shellcheck disable=SC2317
  cleanup() {
    local status="$1"
    local cleanup_status=0 destroy_status=0 destroy_timeout

    trap - EXIT INT TERM HUP
    if [[ "$cleanup_started" == "true" ]]; then
      exit "$status"
    fi
    cleanup_started=true

    if [[ "${CLOUD_COMPOSE_SMOKE_KEEP:-}" == "true" ]]; then
      echo "Keeping ${target} smoke-test resources because CLOUD_COMPOSE_SMOKE_KEEP=true"
      exit "$status"
    fi

    echo "Destroying ${target} config-management smoke resources"
    set +e
    destroy_timeout="$(destroy_timeout_seconds)"
    if command -v timeout >/dev/null 2>&1; then
      timeout "${destroy_timeout}s" \
        env TF_DATA_DIR="$workdir/.terraform" \
        terraform -chdir="$root" destroy -lock-timeout=10m -input=false "${auto_args[@]}" "${var_args[@]}"
      destroy_status=$?
    else
      TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" destroy -lock-timeout=10m -input=false "${auto_args[@]}" "${var_args[@]}"
      destroy_status=$?
    fi
    if [[ "$destroy_status" -ne 0 ]]; then
      provider_tag_cleanup "$target" "$run_id" || cleanup_status=$?
    fi
    if [[ "$status" -eq 0 && "$destroy_status" -ne 0 && "$cleanup_status" -ne 0 ]]; then
      echo "Terraform destroy and provider tag cleanup both failed for ${target}" >&2
      exit "$destroy_status"
    fi
    exit "$status"
  }
  trap 'cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  echo "Initializing ${target} raw Linode smoke"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" init -input=false
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" validate

  if [[ "${CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS:-}" == "true" ]]; then
    provider_tag_cleanup "$target" "" true
  fi

  echo "Applying ${target} raw Linode smoke"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" apply -input=false "${auto_args[@]}" "${var_args[@]}"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" output -json smoke >"$output_json"

  host="$(jq -r '.host' "$output_json")"
  wait_for_ssh "$home_dir" "$key_path" "$host"
  if ! wait_for_cloud_init "$home_dir" "$key_path" "$host"; then
    dump_remote_logs "$home_dir" "$key_path" "$host"
    return 1
  fi
  if ! deploy_config_management "$target" "$key_path" "$output_json"; then
    dump_remote_logs "$home_dir" "$key_path" "$host"
    return 1
  fi

  echo "${target} config-management cloud smoke test passed"
)

destroy_target() (
  set -euo pipefail

  local target="$1" root workdir key_path cleanup_status=0 destroy_status=0 destroy_timeout
  local -a auto_args var_args

  valid_target "$target" || exit 2
  require_env LINODE_TOKEN

  root="$repo_root/tests/smoke/config-management-linode"
  workdir="$(target_workdir "$target")"
  key_path="$workdir/id_ed25519"

  if [[ ! -f "${key_path}.pub" ]]; then
    ensure_key "$key_path"
  fi
  mapfile -d '' -t var_args < <(target_var_args "$key_path" "$target")

  auto_args=()
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CLOUD_COMPOSE_SMOKE_AUTO_APPROVE:-}" == "true" ]]; then
    auto_args=(-auto-approve)
  fi

  if [[ -d "$workdir/.terraform" ]]; then
    echo "Destroying ${target} raw Linode smoke resources from Terraform state"
    set +e
    destroy_timeout="$(destroy_timeout_seconds)"
    if command -v timeout >/dev/null 2>&1; then
      timeout "${destroy_timeout}s" \
        env TF_DATA_DIR="$workdir/.terraform" \
        terraform -chdir="$root" destroy -lock-timeout=10m -input=false "${auto_args[@]}" "${var_args[@]}"
      destroy_status=$?
    else
      TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" destroy -lock-timeout=10m -input=false "${auto_args[@]}" "${var_args[@]}"
      destroy_status=$?
    fi
    set -e
  fi

  provider_tag_cleanup "$target" "$(smoke_run_id)" || cleanup_status=$?
  if [[ "$destroy_status" -ne 0 && "$cleanup_status" -eq 0 ]]; then
    echo "Provider tag cleanup completed for ${target} after Terraform destroy failed"
    return 0
  fi
  if [[ "$destroy_status" -ne 0 ]]; then
    return "$destroy_status"
  fi
  return "$cleanup_status"
)

main() {
  local target

  if [[ "$#" -ne 1 ]]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    all)
      require_run_commands
      for target in $(default_targets); do
        run_target "$target"
      done
      ;;
    sweep)
      require_env LINODE_TOKEN
      require_sweep_commands
      for target in $(default_targets); do
        provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}" "${CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS:-false}"
      done
      ;;
    sweep-*)
      require_env LINODE_TOKEN
      require_sweep_commands
      provider_tag_cleanup "${1#sweep-}" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}" "${CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS:-false}"
      ;;
    destroy-*)
      require_destroy_commands
      destroy_target "${1#destroy-}"
      ;;
    ansible-drupal | salt-drupal)
      require_run_commands
      run_target "$1"
      ;;
    *)
      echo "Unknown config-management cloud smoke command: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
