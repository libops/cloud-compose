#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly diagnostics_program="/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"
readonly smoke_healthcheck_program="/home/cloud-compose/smoke-healthcheck.sh"

usage() {
  cat <<'EOF'
Usage:
  ci/cloud-smoke.sh all
  ci/cloud-smoke.sh <provider>-<template>
  ci/cloud-smoke.sh destroy-<provider>-<template>
  ci/cloud-smoke.sh sweep
  ci/cloud-smoke.sh sweep-<provider>-<template>

Examples:
  ci/cloud-smoke.sh digitalocean-wp
  ci/cloud-smoke.sh linode-wp
  ci/cloud-smoke.sh gcp-wp

Required environment:
  DIGITALOCEAN_TOKEN  DigitalOcean API token for digitalocean targets.
  LINODE_TOKEN        Linode API token for linode targets.
  GCLOUD_PROJECT      Google Cloud project for gcp targets.
  CLOUD_COMPOSE_SMOKE_RUN_ID
                      Canonical GitHub Actions run id for every apply and scoped cleanup.

Optional environment:
  CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true   Pass -auto-approve outside GitHub Actions.
  CLOUD_COMPOSE_SMOKE_KEEP=true           Keep resources for debugging instead of destroying them.
  CLOUD_COMPOSE_SMOKE_WORKDIR=.smoke      Directory for generated keys, Terraform data, and sitectl config.
  CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=1200   Seconds to wait for SSH and cloud-init.
  CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=1800
                                      Seconds allowed for Terraform destroy during cleanup.
  CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS=true
                                      Remove prior smoke resources for the same target before apply.
  CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS=true
                                      Permit an explicit sweep command to remove every run for a target.
  CLOUD_COMPOSE_SMOKE_TARGETS         Space-separated targets used by "all" and "sweep".
  DIGITALOCEAN_API_TOKEN                  Backward-compatible alias for DIGITALOCEAN_TOKEN.
  GCLOUD_REGION=us-east5              Google Cloud region for gcp targets.
  GCLOUD_ZONE=us-east5-b              Google Cloud zone for gcp targets.
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

default_targets() {
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_TARGETS:-digitalocean-wp linode-wp gcp-wp}"
}

valid_template() {
  case "$1" in
    archivesspace | ojs | isle | drupal | wp | omeka-s | omeka-classic) return 0 ;;
    *) return 1 ;;
  esac
}

target_provider() {
  case "$1" in
    digitalocean-*) printf 'digitalocean\n' ;;
    linode-*) printf 'linode\n' ;;
    gcp-*) printf 'gcp\n' ;;
    *)
      echo "Unknown smoke target: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

target_template() {
  local target="$1" provider template

  provider="$(target_provider "$target")"
  template="${target#"$provider"-}"
  if ! valid_template "$template"; then
    echo "Unknown smoke template in target: $target" >&2
    usage >&2
    exit 2
  fi
  printf '%s\n' "$template"
}

target_root() {
  target_template "$1" >/dev/null
  case "$(target_provider "$1")" in
    digitalocean) printf '%s/tests/smoke/do\n' "$repo_root" ;;
    gcp) printf '%s/tests/smoke/gcp\n' "$repo_root" ;;
    linode) printf '%s/tests/smoke/linode\n' "$repo_root" ;;
  esac
}

target_env() {
  case "$(target_provider "$1")" in
    digitalocean)
      if [[ -z "${DIGITALOCEAN_TOKEN:-}" && -n "${DIGITALOCEAN_API_TOKEN:-}" ]]; then
        export DIGITALOCEAN_TOKEN="$DIGITALOCEAN_API_TOKEN"
      fi
      require_env DIGITALOCEAN_TOKEN
      ;;
    linode)
      require_env LINODE_TOKEN
      ;;
    gcp)
      require_env GCLOUD_PROJECT
      export GOOGLE_PROJECT="${GOOGLE_PROJECT:-$GCLOUD_PROJECT}"
      export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-$GCLOUD_PROJECT}"
      export CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-$GCLOUD_PROJECT}"
      ;;
  esac
}

shell_quote() {
  printf '%q' "$1"
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

smoke_run_id() {
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_RUN_ID:-${GITHUB_RUN_ID:-}}"
}

validate_smoke_run_id() {
  local run_id="$1" runner

  if [[ -z "$run_id" ]]; then
    echo "CLOUD_COMPOSE_SMOKE_RUN_ID is required for every provider smoke apply" >&2
    return 1
  fi
  runner="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$runner" ]]; then
    echo "Missing compiled CI runner: ${runner}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi
  "$runner" run validate --run-id "$run_id"
}

gcp_run_namespace() {
  local target="$1" run_id="$2" runner

  if [[ "$(target_provider "$target")" != "gcp" ]]; then
    return 0
  fi
  if [[ -z "$run_id" ]]; then
    echo "CLOUD_COMPOSE_SMOKE_RUN_ID is required for every GCP smoke apply" >&2
    return 1
  fi

  runner="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$runner" ]]; then
    echo "Missing compiled CI runner: ${runner}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi
  "$runner" gcp namespace --run-id "$run_id"
}

gcp_region() {
  printf '%s\n' "${GCLOUD_REGION:-us-east5}"
}

gcp_zone() {
  printf '%s\n' "${GCLOUD_ZONE:-$(gcp_region)-b}"
}

provider_tag_cleanup() {
  local target="$1" run_id="${2:-}" allow_all_runs="${3:-false}" provider cleanup_binary
  local -a cleanup_args

  provider="$(target_provider "$target")"
  cleanup_binary="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$cleanup_binary" ]]; then
    echo "Missing compiled CI runner: ${cleanup_binary}; run 'make cloud-compose-ci' first" >&2
    return 1
  fi

  case "$provider" in
    digitalocean | linode)
      cleanup_args=(
        "$provider" sweep
        --scope application
        --target "$target"
      )
      ;;
    gcp)
      cleanup_args=(
        gcp sweep
        --project "$GCLOUD_PROJECT"
        --region "$(gcp_region)"
        --target "$target"
      )
      ;;
  esac

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

maybe_sweep_orphans() {
  local target="$1"

  if [[ "${CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS:-}" != "true" ]]; then
    return 0
  fi
  echo "Sweeping prior ${target} smoke-test resources"
  provider_tag_cleanup "$target" "" true
}

ensure_key() {
  local key_path="$1"

  if [[ -f "$key_path" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -N "" -C "cloud-compose-smoke" -f "$key_path" >/dev/null
  chmod 0600 "$key_path"
}

target_workdir() {
  local target="$1"

  printf '%s/%s\n' "${CLOUD_COMPOSE_SMOKE_WORKDIR:-$repo_root/.cloud-compose-smoke}" "$target"
}

target_var_args() {
  local root="$1" key_path="$2" target="$3" run_id="$4" run_namespace="$5"
  local public_key provider template
  local source_ref source_sha256 source_cache_key checksum_dir checksum_file archive_tmp checkout_sha

  provider="$(target_provider "$target")"
  template="$(target_template "$target")"

  if [[ -f "${key_path}.pub" ]]; then
    public_key="$(cat "${key_path}.pub")"
  else
    public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake cloud-compose-smoke-placeholder"
  fi

  printf '%s\0%s\0' "-var" "ssh_public_key=${public_key}"
  if grep -q 'variable "cloud_provider"' "$root/variables.tf"; then
    printf '%s\0%s\0' "-var" "cloud_provider=${provider}"
  fi
  if grep -q 'variable "template"' "$root/variables.tf"; then
    printf '%s\0%s\0' "-var" "template=${template}"
  fi
  if grep -q 'variable "cloud_compose_source_ref"' "$root/variables.tf"; then
    checkout_sha="$(git -C "$repo_root" rev-parse HEAD)"
    source_ref="${CLOUD_COMPOSE_SOURCE_REF:-${GITHUB_SHA:-$checkout_sha}}"
    if [[ ! "$source_ref" =~ ^[0-9a-f]{40}$ || "$source_ref" != "$checkout_sha" ]]; then
      echo "CLOUD_COMPOSE_SOURCE_REF must equal the exact lowercase checked-out commit ${checkout_sha}" >&2
      return 1
    fi
    printf '%s\0%s\0' "-var" "cloud_compose_source_ref=${source_ref}"
  fi
  if grep -q 'variable "cloud_compose_source_sha256"' "$root/variables.tf"; then
    source_sha256="${CLOUD_COMPOSE_SOURCE_SHA256:-}"
    if [[ -z "$source_sha256" ]]; then
      checksum_dir="$(target_workdir "$target")"
      source_cache_key="$(printf '%s' "$source_ref" | sha256sum | cut -d' ' -f1)"
      checksum_file="${checksum_dir}/cloud-compose-source-${source_cache_key}.sha256"
      mkdir -p "$checksum_dir"
      if [[ -s "$checksum_file" ]]; then
        source_sha256="$(<"$checksum_file")"
      else
        archive_tmp="$(mktemp "${checksum_dir}/cloud-compose-source.XXXXXX.tar.gz")"
        echo "Calculating SHA-256 for cloud-compose source archive ${source_ref}" >&2
        curl -fsSL --retry 3 \
          "https://github.com/libops/cloud-compose/archive/${source_ref}.tar.gz" \
          -o "$archive_tmp"
        source_sha256="$(sha256sum "$archive_tmp" | cut -d' ' -f1)"
        rm -f "$archive_tmp"
        printf '%s\n' "$source_sha256" > "$checksum_file"
      fi
    fi
    if [[ ! "$source_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "CLOUD_COMPOSE_SOURCE_SHA256 must be a 64-character SHA-256 digest" >&2
      return 1
    fi
    printf '%s\0%s\0' "-var" "cloud_compose_source_sha256=${source_sha256}"
  fi
  if grep -q 'variable "smoke_run_id"' "$root/variables.tf" && [[ -n "$run_id" ]]; then
    printf '%s\0%s\0' "-var" "smoke_run_id=${run_id}"
  fi
  if grep -q 'variable "smoke_run_namespace"' "$root/variables.tf" && [[ -n "$run_namespace" ]]; then
    printf '%s\0%s\0' "-var" "smoke_run_namespace=${run_namespace}"
  fi
  if grep -q 'variable "gcp_project_id"' "$root/variables.tf"; then
    printf '%s\0%s\0' "-var" "gcp_project_id=${GCLOUD_PROJECT:-}"
  fi
  if grep -q 'variable "gcp_region"' "$root/variables.tf"; then
    printf '%s\0%s\0' "-var" "gcp_region=$(gcp_region)"
  fi
  if grep -q 'variable "gcp_zone"' "$root/variables.tf"; then
    printf '%s\0%s\0' "-var" "gcp_zone=$(gcp_zone)"
  fi
}

scan_host_key() {
  local host="$1" port="$2" known_hosts="$3"

  mkdir -p "$(dirname "$known_hosts")"
  touch "$known_hosts"
  chmod 0600 "$known_hosts"
  ssh-keyscan -p "$port" -H "$host" >> "$known_hosts" 2>/dev/null
}

ssh_cmd() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"
  shift 5

  ssh \
    -i "$key_path" \
    -p "$port" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$home_dir/.ssh/known_hosts" \
    "${user}@${host}" \
    "$@"
}

wait_for_ssh() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"
  local timeout_seconds
  local deadline
  local attempt=1

  timeout_seconds="$(boot_timeout_seconds)"
  deadline=$((SECONDS + timeout_seconds))

  echo "Waiting for SSH on ${user}@${host}:${port}"
  while (( SECONDS < deadline )); do
    scan_host_key "$host" "$port" "$home_dir/.ssh/known_hosts" || true
    if ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "true" >/dev/null 2>&1; then
      return 0
    fi
    echo "SSH not ready for ${host}; retrying in 15s (attempt ${attempt})"
    attempt=$((attempt + 1))
    sleep 15
  done

  echo "Timed out waiting for SSH on ${host}" >&2
  return 1
}

remote_diagnostics_available() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"

  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "test -x ${diagnostics_program}" >/dev/null 2>&1
}

remote_bootstrap_state() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"

  if remote_diagnostics_available "$home_dir" "$key_path" "$host" "$port" "$user"; then
    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "sudo -n ${diagnostics_program} state" 2>/dev/null || true
    return
  fi

  # The pinned upgrade fixture predates the checked-in diagnostics program.
  # Keep its compatibility probes simple and non-interactive.
  if ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "test -f /home/cloud-compose/.cloud-compose-bootstrap-complete" >/dev/null 2>&1; then
    echo complete
  elif ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "systemctl is-active --quiet cloud-compose.service" >/dev/null 2>&1; then
    echo complete
  elif ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "systemctl is-active --quiet cloud-final.service" >/dev/null 2>&1; then
    echo active
  else
    echo idle
  fi
}

wait_for_cloud_init() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"
  local timeout_seconds
  local deadline
  local status_output
  local bootstrap_state
  local diagnostics_available

  timeout_seconds="$(boot_timeout_seconds)"
  deadline=$((SECONDS + timeout_seconds))

  echo "Waiting for cloud-init on ${host}"
  while (( SECONDS < deadline )); do
    diagnostics_available=false
    if remote_diagnostics_available "$home_dir" "$key_path" "$host" "$port" "$user"; then
      diagnostics_available=true
    fi
    bootstrap_state="$(remote_bootstrap_state "$home_dir" "$key_path" "$host" "$port" "$user")"
    if [[ "$bootstrap_state" == "complete" ]]; then
      return 0
    fi

    if [[ "$diagnostics_available" == "true" ]]; then
      status_output="$(
        ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
          "sudo -n ${diagnostics_program} status" 2>&1 || true
      )"
    else
      status_output="$(
        ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
          "cloud-init status --long" 2>&1 || true
      )"
    fi
    printf '%s\n' "$status_output"

    if grep -q '^status: done' <<<"$status_output"; then
      if [[ "$diagnostics_available" == "true" ]]; then
        if [[ "$bootstrap_state" == "active" ]]; then
          echo "cloud-init is done while cloud-compose bootstrap is still active; continuing"
          sleep 30
          continue
        fi
        echo "cloud-init completed without the Cloud Compose readiness marker" >&2
        return 1
      fi
      # The pinned upgrade fixture predates the durable readiness marker.
      # Retain cloud-init completion as its final compatibility signal.
      return 0
    fi
    if grep -q '^status: error' <<<"$status_output"; then
      if [[ "$bootstrap_state" == "active" ]]; then
        echo "cloud-init reports an error while cloud-compose bootstrap is still active; continuing"
        sleep 30
        continue
      fi
      return 1
    fi

    sleep 30
  done

  echo "Timed out waiting for cloud-init on ${host}" >&2
  return 1
}

dump_remote_logs() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5" project_dir="$6"
  local quoted_project_dir
  quoted_project_dir="$(shell_quote "$project_dir")"

  echo "Dumping smoke-test diagnostics from ${host}" >&2
  if remote_diagnostics_available "$home_dir" "$key_path" "$host" "$port" "$user"; then
    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "sudo -n ${diagnostics_program} dump" || true
    return
  fi

  # Compatibility diagnostics for the pinned pre-program upgrade fixture.
  echo "--- legacy cloud-init status ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "cloud-init status --long" || true
  echo "--- legacy /var/log/cloud-init-output.log ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "tail -n 400 /var/log/cloud-init-output.log" || true
  echo "--- legacy /var/log/cloud-init.log ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "tail -n 400 /var/log/cloud-init.log" || true
  echo "--- legacy cloud-init runcmd ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "sed -n 1,240p /var/lib/cloud/instance/scripts/runcmd" || true
  echo "--- legacy cloud-compose bootstrap unit ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "systemctl status cloud-compose-bootstrap.service --no-pager" || true
  echo "--- legacy cloud-compose bootstrap log ---"
  if ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "test -f /home/cloud-compose/run.log" >/dev/null 2>&1 &&
    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "test ! -L /home/cloud-compose/run.log" >/dev/null 2>&1; then
    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "tail -n 400 /home/cloud-compose/run.log" || true
  else
    echo "Legacy bootstrap log is not present"
  fi
  echo "--- legacy cloud-compose unit ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "sudo -n /usr/bin/systemctl status cloud-compose.service" || true
  echo "--- legacy lifecycle lock permissions ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "stat -Lc '%A %a %U:%G %u:%g %n' /run/lock/cloud-compose /run/lock/cloud-compose/lifecycle.lock" || true
  echo "--- legacy docker ps ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "docker ps -a" || true
  echo "--- legacy docker compose ps ---"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "docker compose --project-directory ${quoted_project_dir} ps" || true
}

configure_sitectl_context() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local host port user context plugin environment site project_dir compose_project_name

  host="$(jq -r '.host' "$output_json")"
  port="$(jq -r '.ssh_port' "$output_json")"
  user="$(jq -r '.ssh_user' "$output_json")"
  context="$(jq -r '.context_name' "$output_json")"
  plugin="$(jq -r '.plugin' "$output_json")"
  environment="$(jq -r '.environment' "$output_json")"
  site="$(jq -r '.site' "$output_json")"
  project_dir="$(jq -r '.project_dir' "$output_json")"
  compose_project_name="$(jq -r '.compose_project_name' "$output_json")"

  HOME="$home_dir" sitectl config set-context "$context" \
    --type remote \
    --ssh-hostname "$host" \
    --ssh-port "$port" \
    --ssh-user "$user" \
    --ssh-key "$key_path" \
    --project-dir "$project_dir" \
    --site "$site" \
    --plugin "$plugin" \
    --environment "$environment" \
    --compose-project-name "$compose_project_name" \
    --docker-socket /var/run/docker.sock \
    --env-file .env \
    --yolo \
    --default
}

run_healthcheck() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local provider context

  provider="$(jq -r '.provider' "$output_json")"
  context="$(jq -r '.context_name' "$output_json")"

  if [[ "$provider" == "gcp" ]]; then
    local host port user quoted_context

    host="$(jq -r '.host' "$output_json")"
    port="$(jq -r '.ssh_port' "$output_json")"
    user="$(jq -r '.ssh_user' "$output_json")"
    quoted_context="$(shell_quote "$context")"

    if ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "test -x ${smoke_healthcheck_program}" >/dev/null 2>&1; then
      ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
        "${smoke_healthcheck_program} ${quoted_context}"
    else
      # The pinned 0.10.2 upgrade fixture predates the checked-in wrapper.
      # Invoke its sitectl binary directly with the environment profile's
      # stable path settings, without sending an embedded shell program.
      ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
        "env HOME=/home/cloud-compose DOCKER_CONFIG=/mnt/disks/data/docker-config PATH=/home/cloud-compose/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin sitectl healthcheck --context ${quoted_context} --persist --format table"
    fi
    return
  fi

  HOME="$home_dir" sitectl healthcheck \
    --context "$context" \
    --persist \
    --format table
}

run_lifecycle_program_contract() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local host port user remote_contract_dir remote_contract status

  host="$(jq -r '.host' "$output_json")"
  port="$(jq -r '.ssh_port' "$output_json")"
  user="$(jq -r '.ssh_user' "$output_json")"
  if ! remote_contract_dir="$(ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    'mktemp -d /mnt/disks/data/cloud-compose-hosted-contract.XXXXXX')"; then
    echo "Could not create the remote lifecycle contract directory on the executable data disk" >&2
    return 1
  fi
  if [[ ! "$remote_contract_dir" =~ ^/mnt/disks/data/cloud-compose-hosted-contract\.[A-Za-z0-9]+$ ]]; then
    echo "Remote lifecycle contract directory is unsafe: $remote_contract_dir" >&2
    return 1
  fi

  remote_contract="$remote_contract_dir/lifecycle-program-contract.sh"
  if ! ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "install -m 0700 /dev/stdin $remote_contract" \
    <"$repo_root/ci/lifecycle-program-contract.sh"; then
    echo "Could not install the remote lifecycle program contract" >&2
    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
      "rm -f -- $remote_contract && rmdir -- $remote_contract_dir" || true
    return 1
  fi

  if ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "test -x /home/cloud-compose/default-lifecycle.sh && bash $remote_contract /home/cloud-compose/default-lifecycle.sh"; then
    status=0
  else
    status=$?
    echo "Remote lifecycle program contract failed with status $status" >&2
  fi
  if ! ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "rm -f -- $remote_contract && rmdir -- $remote_contract_dir"; then
    echo "Could not remove the remote lifecycle program contract" >&2
  fi
  return "$status"
}

run_target() (
  set -euo pipefail

  local target="$1"
  local root workdir key_path home_dir output_json public_key run_id run_namespace
  local -a auto_args var_args

  root="$(target_root "$target")"
  target_env "$target"

  workdir="$(target_workdir "$target")"
  key_path="$workdir/id_ed25519"
  home_dir="$workdir/home"
  output_json="$workdir/smoke.json"
  mkdir -p "$workdir" "$home_dir/.ssh"
  chmod 0700 "$home_dir/.ssh"

  ensure_key "$key_path"
  run_id="$(smoke_run_id)"
  validate_smoke_run_id "$run_id"
  # Compute outside process substitution so an invalid hosted run ID aborts
  # before Terraform can create resources under an undiscoverable namespace.
  run_namespace="$(gcp_run_namespace "$target" "$run_id")"
  mapfile -d '' -t var_args < <(target_var_args "$root" "$key_path" "$target" "$run_id" "$run_namespace")

  auto_args=()
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CLOUD_COMPOSE_SMOKE_AUTO_APPROVE:-}" == "true" ]]; then
    auto_args=(-auto-approve)
  fi

  cleanup_started=false
  # shellcheck disable=SC2317
  cleanup() {
    local status="$1"
    local destroy_status destroy_timeout cleanup_status

    trap - EXIT INT TERM HUP
    if [[ "$cleanup_started" == "true" ]]; then
      exit "$status"
    fi
    cleanup_started=true

    if [[ "${CLOUD_COMPOSE_SMOKE_KEEP:-}" == "true" ]]; then
      echo "Keeping ${target} smoke-test resources because CLOUD_COMPOSE_SMOKE_KEEP=true"
      exit "$status"
    fi

    echo "Destroying ${target} smoke-test resources"
    set +e
    cleanup_status=0
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
      echo "Terraform destroy failed for ${target}; attempting provider tag cleanup"
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

  echo "Initializing ${target}"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" init -input=false
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" validate

  maybe_sweep_orphans "$target"

  echo "Applying ${target}"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" apply -input=false "${auto_args[@]}" "${var_args[@]}"
  TF_DATA_DIR="$workdir/.terraform" terraform -chdir="$root" output -json smoke > "$output_json"

  local host port user project_dir
  host="$(jq -r '.host' "$output_json")"
  port="$(jq -r '.ssh_port' "$output_json")"
  user="$(jq -r '.ssh_user' "$output_json")"
  project_dir="$(jq -r '.project_dir' "$output_json")"

  wait_for_ssh "$home_dir" "$key_path" "$host" "$port" "$user"
  if ! wait_for_cloud_init "$home_dir" "$key_path" "$host" "$port" "$user"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi

  if ! run_lifecycle_program_contract "$home_dir" "$key_path" "$output_json"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi

  configure_sitectl_context "$home_dir" "$key_path" "$output_json"
  if ! run_healthcheck "$home_dir" "$key_path" "$output_json"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi

  echo "${target} smoke test passed"
)

destroy_target() (
  set -euo pipefail

  local target="$1"
  local root workdir key_path destroy_status destroy_timeout cleanup_status run_id run_namespace
  local -a auto_args var_args

  root="$(target_root "$target")"
  target_env "$target"

  workdir="$(target_workdir "$target")"
  key_path="$workdir/id_ed25519"
  run_id="$(smoke_run_id)"
  run_namespace=""
  if [[ -n "$run_id" ]]; then
    run_namespace="$(gcp_run_namespace "$target" "$run_id")"
  fi
  mapfile -d '' -t var_args < <(target_var_args "$root" "$key_path" "$target" "$run_id" "$run_namespace")

  auto_args=()
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CLOUD_COMPOSE_SMOKE_AUTO_APPROVE:-}" == "true" ]]; then
    auto_args=(-auto-approve)
  fi

  destroy_status=0
  if [[ -d "$workdir/.terraform" ]]; then
    echo "Destroying ${target} smoke-test resources from Terraform state"
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
  else
    echo "No Terraform data directory found for ${target}; using provider cleanup"
  fi

  cleanup_status=0
  provider_tag_cleanup "$target" "$run_id" || cleanup_status=$?

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
  local target provider

  if [[ "$#" -ne 1 ]]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    sweep)
      for target in $(default_targets); do
        provider="$(target_provider "$target")"
        if [[ "$provider" == "gcp" ]]; then
          require_cmd gcloud
        fi
        target_env "$target"
        provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}" "${CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS:-false}"
      done
      exit 0
      ;;
    sweep-*)
      target="${1#sweep-}"
      provider="$(target_provider "$target")"
      if [[ "$provider" == "gcp" ]]; then
        require_cmd gcloud
      fi
      target_env "$target"
      provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}" "${CLOUD_COMPOSE_SMOKE_ALLOW_ALL_RUNS:-false}"
      exit 0
      ;;
    destroy-*)
      target="${1#destroy-}"
      provider="$(target_provider "$target")"
      require_cmd terraform
      require_cmd curl
      if [[ "$provider" == "gcp" ]]; then
        require_cmd gcloud
      fi
      destroy_target "$target"
      exit 0
      ;;
  esac

  require_cmd jq
  require_cmd curl
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd ssh-keyscan
  require_cmd sitectl
  require_cmd terraform

  case "$1" in
    all)
      for target in $(default_targets); do
        run_target "$target"
      done
      ;;
    digitalocean-* | linode-* | gcp-*)
      target_template "$1" >/dev/null
      run_target "$1"
      ;;
    *)
      echo "Unknown smoke target: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
