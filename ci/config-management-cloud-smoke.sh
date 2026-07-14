#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# renovate: datasource=docker depName=python packageName=python versioning=docker
CONFIG_MANAGEMENT_IMAGE_DEFAULT="python:3.11-slim@sha256:e031123e3d85762b141ad1cbc56452ba69c6e722ebf2f042cc0dc86c47c0d8b3"

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

Optional environment:
  CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true
  CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=1200
  CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=1800
  CLOUD_COMPOSE_SMOKE_KEEP=true
  CLOUD_COMPOSE_SMOKE_RUN_ID
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

smoke_run_id() {
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_RUN_ID:-${GITHUB_RUN_ID:-}}"
}

smoke_run_tag() {
  local run_id="$1"

  if [[ -z "$run_id" ]]; then
    return 0
  fi
  run_id="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-16)"
  printf 'gha-run-%s\n' "$run_id"
}

target_tag() {
  local target="$1"
  printf 'config-management-%s-%s\n' "$(target_method "$target")" "$(target_template "$target")"
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

api_request() {
  local method="$1" path="$2"
  local body http_code response

  if response="$(curl -sS \
    --connect-timeout 10 \
    --max-time 45 \
    -X "$method" \
    -H "Authorization: Bearer ${LINODE_TOKEN}" \
    -w $'\n%{http_code}' \
    "https://api.linode.com/v4${path}")"; then
    http_code="${response##*$'\n'}"
    body="${response%$'\n'"$http_code"}"
  else
    echo "linode API request failed for ${method} ${path}; check LINODE_TOKEN and network access." >&2
    return 75
  fi

  case "$http_code" in
    2??)
      printf '%s' "$body"
      ;;
    401)
      echo "linode API rejected LINODE_TOKEN with HTTP 401 for ${method} ${path}; verify the GitHub secret is current and valid for Linode." >&2
      return 22
      ;;
    403)
      echo "linode API rejected LINODE_TOKEN with HTTP 403 for ${method} ${path}; verify the token has the permissions required by smoke cleanup and Terraform." >&2
      return 22
      ;;
    404 | 410)
      if [[ "$method" == "DELETE" ]]; then
        return 0
      fi
      echo "linode API returned HTTP ${http_code} for ${method} ${path}." >&2
      if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >&2
      fi
      return 22
      ;;
    408 | 425 | 429 | 5??)
      echo "linode API returned retryable HTTP ${http_code} for ${method} ${path}." >&2
      if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >&2
      fi
      return 75
      ;;
    409 | 423)
      if [[ "$method" == "DELETE" ]]; then
        echo "linode API returned retryable HTTP ${http_code} for ${method} ${path}." >&2
        if [[ -n "$body" ]]; then
          printf '%s\n' "$body" >&2
        fi
        return 75
      fi
      echo "linode API returned HTTP ${http_code} for ${method} ${path}." >&2
      if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >&2
      fi
      return 22
      ;;
    *)
      echo "linode API returned HTTP ${http_code} for ${method} ${path}." >&2
      if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >&2
      fi
      return 22
      ;;
  esac
}

api_get() {
  local path="$1" attempt=1 delay=2 status

  while true; do
    if api_request GET "$path"; then
      return 0
    else
      status=$?
    fi
    if [[ "$status" -ne 75 || "$attempt" -ge 6 ]]; then
      return "$status"
    fi
    echo "Retrying linode API GET ${path} in ${delay}s (attempt $((attempt + 1)) of 6)" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    if [[ "$delay" -gt 30 ]]; then
      delay=30
    fi
  done
}

api_delete() {
  api_request DELETE "$1" >/dev/null
}

delete_ids() {
  local path_prefix="$1" id attempt status
  local failed=0 deleted

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    deleted=false
    for attempt in {1..12}; do
      echo "Deleting Linode resource ${path_prefix}/${id} (attempt ${attempt})"
      if api_delete "${path_prefix}/${id}"; then
        deleted=true
        break
      else
        status=$?
      fi
      if [[ "$status" -ne 75 ]]; then
        break
      fi
      if [[ "$attempt" -lt 12 ]]; then
        sleep 10
      fi
    done
    if [[ "$deleted" != "true" ]]; then
      echo "Failed to delete Linode resource ${path_prefix}/${id} after ${attempt} attempt(s)" >&2
      failed=1
    fi
  done

  return "$failed"
}

provider_resource_ids() {
  local target="$1" run_id="${2:-}" kind="$3" run_tag tag

  run_tag="$(smoke_run_tag "$run_id")"
  tag="$(target_tag "$target")"

  case "$kind" in
    firewalls)
      api_get "/networking/firewalls?page_size=500" |
        jq -r --arg tag "$tag" --arg run_tag "$run_tag" 'if (.data | type) != "array" then error("Linode firewalls response data is not an array") else .data[] | select((.tags // []) | index("cloud-compose-smoke") and index("config-management-smoke") and index($tag)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id end'
      ;;
    instances)
      api_get "/linode/instances?page_size=500" |
        jq -r --arg tag "$tag" --arg run_tag "$run_tag" 'if (.data | type) != "array" then error("Linode instances response data is not an array") else .data[] | select((.tags // []) | index("cloud-compose-smoke") and index("config-management-smoke") and index($tag)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id end'
      ;;
    volumes)
      api_get "/volumes?page_size=500" |
        jq -r --arg tag "$tag" --arg run_tag "$run_tag" 'if (.data | type) != "array" then error("Linode volumes response data is not an array") else .data[] | select((.tags // []) | index("cloud-compose-smoke") and index("config-management-smoke") and index($tag)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id end'
      ;;
    *)
      echo "Unknown Linode resource kind: ${kind}" >&2
      return 2
      ;;
  esac
}

provider_cleanup_residuals() {
  local target="$1" run_id="${2:-}" kind ids id index
  local -a kinds=(firewalls instances volumes)
  local -a path_prefixes=(/networking/firewalls /linode/instances /volumes)

  for index in "${!kinds[@]}"; do
    kind="${kinds[$index]}"
    if ! ids="$(provider_resource_ids "$target" "$run_id" "$kind")"; then
      return 1
    fi
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      printf '%s%s\n' "${path_prefixes[$index]}/" "$id"
    done <<<"$ids"
  done
}

verify_no_provider_resources() {
  local target="$1" run_id="${2:-}" attempt residuals

  for attempt in {1..6}; do
    if ! residuals="$(provider_cleanup_residuals "$target" "$run_id")"; then
      echo "Could not verify provider cleanup for config-management ${target}" >&2
      return 1
    fi
    if [[ -z "$residuals" ]]; then
      echo "Verified that no matching config-management ${target} smoke resources remain"
      return 0
    fi
    echo "Matching config-management ${target} smoke resources remain after cleanup verification attempt ${attempt}:" >&2
    printf '%s\n' "$residuals" >&2
    if [[ "$attempt" -lt 6 ]]; then
      sleep 10
    fi
  done

  echo "Provider cleanup left matching config-management ${target} smoke resources" >&2
  return 1
}

provider_tag_cleanup() {
  local target="$1" run_id="${2:-}" kind index
  local cleanup_status=0
  local -a kinds=(firewalls instances volumes)
  local -a path_prefixes=(/networking/firewalls /linode/instances /volumes)

  for index in "${!kinds[@]}"; do
    kind="${kinds[$index]}"
    provider_resource_ids "$target" "$run_id" "$kind" |
      delete_ids "${path_prefixes[$index]}" || cleanup_status=1
    if [[ "$kind" == "instances" ]]; then
      sleep 10
    fi
  done
  if [[ "$cleanup_status" -eq 0 ]] && ! verify_no_provider_resources "$target" "$run_id"; then
    cleanup_status=1
  fi

  return "$cleanup_status"
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

  echo "Dumping config-management smoke diagnostics from ${host}" >&2
  ssh_cmd "$home_dir" "$key_path" "$host" "bash -lc 'set +e
echo \"--- cloud-init status ---\"
cloud-init status --long
echo \"--- /var/log/cloud-init-output.log ---\"
tail -n 300 /var/log/cloud-init-output.log
echo \"--- /home/cloud-compose/run.log ---\"
tail -n 300 /home/cloud-compose/run.log
echo \"--- cloud-compose unit ---\"
journalctl -u cloud-compose --no-pager -n 300
echo \"--- docker ps ---\"
docker ps -a
echo \"--- compose manifest ---\"
cat /home/cloud-compose/compose-projects.json
'" || true
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
  local method host name template environment project_dir image

  method="$(jq -r '.method' "$output_json")"
  host="$(jq -r '.host' "$output_json")"
  name="$(jq -r '.cloud_compose_name' "$output_json")"
  template="$(jq -r '.app' "$output_json")"
  environment="$(jq -r '.environment' "$output_json")"
  project_dir="$(jq -r '.project_dir' "$output_json")"
  image="${CLOUD_COMPOSE_CONFIG_MANAGEMENT_IMAGE:-$CONFIG_MANAGEMENT_IMAGE_DEFAULT}"

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
    docker run --rm -i \
      --env "SMOKE_METHOD=${method}" \
      --env "SMOKE_HOST=${host}" \
      --env "SMOKE_NAME=${name}" \
      --env "SMOKE_TEMPLATE=${template}" \
      --env "SMOKE_ENVIRONMENT=${environment}" \
      --env "SMOKE_PROJECT_DIR=${project_dir}" \
      --mount "type=bind,src=${key_path},dst=/run/secrets/cloud-compose-ssh-key,readonly" \
      --tmpfs /run \
      --tmpfs /tmp \
      "$image" \
      bash -lc 'mkdir -p /work && tar -C /work -xf - && cd /work && bash ci/config-management-cloud-smoke-inner.sh'
}

require_run_commands() {
  require_cmd curl
  require_cmd docker
  require_cmd git
  require_cmd jq
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd ssh-keyscan
  require_cmd terraform
}

require_destroy_commands() {
  require_cmd curl
  require_cmd jq
  require_cmd ssh-keygen
  require_cmd terraform
}

require_sweep_commands() {
  require_cmd curl
  require_cmd jq
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
    provider_tag_cleanup "$target"
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
        provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}"
      done
      ;;
    sweep-*)
      require_env LINODE_TOKEN
      require_sweep_commands
      provider_tag_cleanup "${1#sweep-}" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}"
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
