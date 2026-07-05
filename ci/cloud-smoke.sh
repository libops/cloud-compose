#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ci/cloud-smoke.sh all
  ci/cloud-smoke.sh <provider>-<template>
  ci/cloud-smoke.sh destroy-<provider>-<template>
  ci/cloud-smoke.sh sweep
  ci/cloud-smoke.sh sweep-<provider>-<template>

Examples:
  ci/cloud-smoke.sh digitalocean-isle
  ci/cloud-smoke.sh linode-wp
  ci/cloud-smoke.sh gcp-wp

Required environment:
  DIGITALOCEAN_TOKEN  DigitalOcean API token for digitalocean targets.
  LINODE_TOKEN        Linode API token for linode targets.
  GCLOUD_PROJECT      Google Cloud project for gcp targets.

Optional environment:
  CLOUD_COMPOSE_SMOKE_AUTO_APPROVE=true   Pass -auto-approve outside GitHub Actions.
  CLOUD_COMPOSE_SMOKE_KEEP=true           Keep resources for debugging instead of destroying them.
  CLOUD_COMPOSE_SMOKE_WORKDIR=.smoke      Directory for generated keys, Terraform data, and sitectl config.
  CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=3600   Seconds to wait for SSH and cloud-init.
  CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT=1800
                                      Seconds allowed for Terraform destroy during cleanup.
  CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS=true
                                      Remove prior smoke resources for the same target before apply.
  CLOUD_COMPOSE_SMOKE_RUN_ID          Optional run id used to target provider cleanup.
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
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_TARGETS:-digitalocean-isle linode-wp gcp-wp}"
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
  printf '%s/tests/smoke/app\n' "$repo_root"
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
  positive_integer_env CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT 3600
}

destroy_timeout_seconds() {
  positive_integer_env CLOUD_COMPOSE_SMOKE_DESTROY_TIMEOUT 1800
}

smoke_run_id() {
  printf '%s\n' "${CLOUD_COMPOSE_SMOKE_RUN_ID:-${GITHUB_RUN_ID:-}}"
}

api_delete() {
  local provider="$1" path="$2" token

  case "$provider" in
    digitalocean)
      token="${DIGITALOCEAN_TOKEN:-}"
      curl -fsS -X DELETE -H "Authorization: Bearer ${token}" "https://api.digitalocean.com/v2${path}" >/dev/null
      ;;
    linode)
      token="${LINODE_TOKEN:-}"
      curl -fsS -X DELETE -H "Authorization: Bearer ${token}" "https://api.linode.com/v4${path}" >/dev/null
      ;;
  esac
}

api_get() {
  local provider="$1" path="$2" token

  case "$provider" in
    digitalocean)
      token="${DIGITALOCEAN_TOKEN:-}"
      curl -fsS -H "Authorization: Bearer ${token}" "https://api.digitalocean.com/v2${path}"
      ;;
    linode)
      token="${LINODE_TOKEN:-}"
      curl -fsS -H "Authorization: Bearer ${token}" "https://api.linode.com/v4${path}"
      ;;
  esac
}

gcp_region() {
  printf '%s\n' "${GCLOUD_REGION:-us-east5}"
}

gcp_zone() {
  printf '%s\n' "${GCLOUD_ZONE:-$(gcp_region)-b}"
}

delete_ids() {
  local provider="$1" path_prefix="$2" id attempt

  while IFS= read -r id; do
    if [[ -z "$id" ]]; then
      continue
    fi
    for attempt in {1..12}; do
      echo "Deleting ${provider} ${path_prefix}/${id} (attempt ${attempt})"
      if api_delete "$provider" "${path_prefix}/${id}"; then
        break
      fi
      sleep 10
    done
  done
}

smoke_run_tag() {
  local run_id="$1"

  if [[ -z "$run_id" ]]; then
    return 0
  fi
  run_id="$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-16)"
  printf 'gha-run-%s\n' "$run_id"
}

template_slug() {
  case "$1" in
    archivesspace) printf 'as\n' ;;
    ojs) printf 'ojs\n' ;;
    isle) printf 'isle\n' ;;
    drupal) printf 'dr\n' ;;
    wp) printf 'wp\n' ;;
    omeka-s) printf 'os\n' ;;
    omeka-classic) printf 'oc\n' ;;
    *)
      echo "Unknown smoke template: $1" >&2
      exit 2
      ;;
  esac
}

provider_slug() {
  case "$1" in
    digitalocean) printf 'do\n' ;;
    gcp) printf 'g\n' ;;
    linode) printf 'ln\n' ;;
    *)
      echo "Unknown smoke provider: $1" >&2
      exit 2
      ;;
  esac
}

target_name_prefix() {
  local target="$1" provider template

  provider="$(target_provider "$target")"
  template="$(target_template "$target")"
  printf 'cc-%s-%s\n' "$(provider_slug "$provider")" "$(template_slug "$template")"
}

provider_tag_cleanup() {
  local target="$1" run_id="${2:-}" run_tag run_fragment provider name_prefix

  run_tag="$(smoke_run_tag "$run_id")"
  run_fragment=""
  if [[ -n "$run_id" ]]; then
    run_fragment="-$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-16)-"
  fi
  provider="$(target_provider "$target")"
  name_prefix="$(target_name_prefix "$target")"

  case "$provider" in
    digitalocean)
      api_get digitalocean "/firewalls?per_page=200" |
        jq -r --arg name_prefix "${name_prefix}-" --arg run_fragment "$run_fragment" '.firewalls[]? | select(.name | startswith($name_prefix)) | select($run_fragment == "" or (.name | contains($run_fragment))) | .id' |
        delete_ids digitalocean "/firewalls"
      api_get digitalocean "/droplets?tag_name=cloud-compose-smoke&per_page=200" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.droplets[]? | select((.tags // []) | index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids digitalocean "/droplets"
      sleep 10
      api_get digitalocean "/volumes?tag_name=cloud-compose-smoke&per_page=200" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.volumes[]? | select((.tags // []) | index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids digitalocean "/volumes"
      ;;
    linode)
      api_get linode "/networking/firewalls?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/networking/firewalls"
      api_get linode "/linode/instances?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/linode/instances"
      sleep 10
      api_get linode "/volumes?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/volumes"
      ;;
    gcp)
      local project name_filter
      project="$GCLOUD_PROJECT"
      name_filter="^${name_prefix}-"
      if [[ -n "$run_id" ]]; then
        name_filter="^${name_prefix}-$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-8)-"
      fi

      gcloud compute instances list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format=json |
        jq -r '.[]? | [.zone, .name] | @tsv' |
        while IFS=$'\t' read -r zone_url name; do
          [[ -n "$name" ]] || continue
          echo "Deleting gcp instance ${name}"
          gcloud compute instances delete "$name" \
            --project "$project" \
            --zone "${zone_url##*/}" \
            --quiet || true
        done

      gcloud compute firewall-rules list \
        --project "$project" \
        --filter="name~'^(allow-ssh-ipv4-|allow-ssh-ipv6-)${name_filter#^}'" \
        --format='value(name)' |
        while IFS= read -r name; do
          [[ -n "$name" ]] || continue
          echo "Deleting gcp firewall ${name}"
          gcloud compute firewall-rules delete "$name" --project "$project" --quiet || true
        done

      gcloud compute disks list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format=json |
        jq -r '.[]? | [.zone, .name] | @tsv' |
        while IFS=$'\t' read -r zone_url name; do
          [[ -n "$name" ]] || continue
          echo "Deleting gcp disk ${name}"
          gcloud compute disks delete "$name" \
            --project "$project" \
            --zone "${zone_url##*/}" \
            --quiet || true
        done

      gcloud iam service-accounts list \
        --project "$project" \
        --filter="email~'^(vm-|internal-)?${name_filter#^}.*@${project}\\.iam\\.gserviceaccount\\.com$'" \
        --format='value(email)' |
        while IFS= read -r email; do
          [[ -n "$email" ]] || continue
          echo "Deleting gcp service account ${email}"
          gcloud projects remove-iam-policy-binding "$project" \
            --member "serviceAccount:${email}" \
            --role roles/logging.logWriter \
            --quiet >/dev/null 2>&1 || true
          gcloud projects remove-iam-policy-binding "$project" \
            --member "serviceAccount:${email}" \
            --role roles/monitoring.metricWriter \
            --quiet >/dev/null 2>&1 || true
          gcloud projects remove-iam-policy-binding "$project" \
            --member "serviceAccount:${email}" \
            --role "projects/${project}/roles/suspendVM" \
            --quiet >/dev/null 2>&1 || true
          gcloud iam service-accounts delete "$email" --project "$project" --quiet || true
        done
      ;;
  esac
}

maybe_sweep_orphans() {
  local target="$1"

  if [[ "${CLOUD_COMPOSE_SMOKE_SWEEP_ORPHANS:-}" != "true" ]]; then
    return 0
  fi
  echo "Sweeping prior ${target} smoke-test resources"
  provider_tag_cleanup "$target"
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
  local root="$1" key_path="$2" target="$3" public_key provider template

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
    printf '%s\0%s\0' "-var" "cloud_compose_source_ref=${CLOUD_COMPOSE_SOURCE_REF:-${GITHUB_SHA:-main}}"
  fi
  if grep -q 'variable "smoke_run_id"' "$root/variables.tf" && [[ -n "$(smoke_run_id)" ]]; then
    printf '%s\0%s\0' "-var" "smoke_run_id=$(smoke_run_id)"
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

remote_bootstrap_state() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"

  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set +e
if [ -f /home/cloud-compose/.cloud-compose-bootstrap-complete ]; then
  echo complete
  exit 0
fi
if systemctl is-active --quiet cloud-compose; then
  echo complete
  exit 0
fi
if systemctl is-active --quiet cloud-final.service; then
  echo active
  exit 0
fi
if pgrep -f \"[/]home/cloud-compose/run[.]sh|[/]home/cloud-compose/[h]ost-conf[.]sh|[/]home/cloud-compose/[h]ost-init[.]sh|[/]home/cloud-compose/[a]pp-init[.]sh|[/]home/cloud-compose/[i]nstall-dependencies|[a]pt-get|[r]pm-ostree|[d]ocker run|[s]itectl|[g]it clone\" >/dev/null; then
  echo active
  exit 0
fi
echo idle
exit 1
'" 2>/dev/null || true
}

wait_for_cloud_init() {
  local home_dir="$1" key_path="$2" host="$3" port="$4" user="$5"
  local timeout_seconds
  local deadline
  local status_output
  local bootstrap_state
  local last_dump=0

  timeout_seconds="$(boot_timeout_seconds)"
  deadline=$((SECONDS + timeout_seconds))

  echo "Waiting for cloud-init on ${host}"
  while (( SECONDS < deadline )); do
    bootstrap_state="$(remote_bootstrap_state "$home_dir" "$key_path" "$host" "$port" "$user")"
    if [[ "$bootstrap_state" == "complete" ]]; then
      return 0
    fi

    status_output="$(
      ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
        "if command -v cloud-init >/dev/null 2>&1; then sudo cloud-init status --long 2>&1; else echo 'cloud-init not installed'; fi" 2>&1 || true
    )"
    printf '%s\n' "$status_output"

    if grep -q '^status: done' <<<"$status_output"; then
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

    if (( SECONDS - last_dump >= 120 )); then
      last_dump=$SECONDS
      ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set +e
echo \"--- active bootstrap processes ---\"
ps -eo pid,ppid,stat,etime,args | grep -E \"cloud-init|runcmd|run.sh|host-conf|host-init|app-init|install-dependencies|apt-get|docker|sitectl|git clone\" | grep -v grep
echo \"--- /home/cloud-compose/run.log ---\"
sudo tail -n 160 /home/cloud-compose/run.log
echo \"--- /var/log/cloud-init-output.log ---\"
sudo tail -n 120 /var/log/cloud-init-output.log
'" || true
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
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set +e
echo \"--- cloud-init status ---\"
sudo cloud-init status --long
echo \"--- /var/log/cloud-init-output.log ---\"
sudo tail -n 400 /var/log/cloud-init-output.log
echo \"--- /var/log/cloud-init.log ---\"
sudo tail -n 400 /var/log/cloud-init.log
echo \"--- cloud-init runcmd ---\"
sudo sed -n '1,240p' /var/lib/cloud/instance/scripts/runcmd
echo \"--- /home/cloud-compose/run.log ---\"
sudo tail -n 400 /home/cloud-compose/run.log
echo \"--- cloud-compose unit ---\"
sudo journalctl -u cloud-compose --no-pager -n 300
echo \"--- docker ps ---\"
sudo docker ps -a
echo \"--- docker compose ps ---\"
if [ -d ${quoted_project_dir} ]; then
  if command -v runuser >/dev/null 2>&1; then
    runuser -u cloud-compose -- env HOME=/home/cloud-compose PROJECT_DIR=${quoted_project_dir} bash -lc \"source /home/cloud-compose/profile.sh && cd \\\"\$PROJECT_DIR\\\" && docker compose ps\"
  else
    sudo -u cloud-compose env HOME=/home/cloud-compose PROJECT_DIR=${quoted_project_dir} bash -lc \"source /home/cloud-compose/profile.sh && cd \\\"\$PROJECT_DIR\\\" && docker compose ps\"
  fi
else
  echo \"Project directory ${project_dir} is not present yet\"
fi
'" || true
}

configure_sitectl_context() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local host port user context plugin environment site project_name project_dir compose_project_name

  host="$(jq -r '.host' "$output_json")"
  port="$(jq -r '.ssh_port' "$output_json")"
  user="$(jq -r '.ssh_user' "$output_json")"
  context="$(jq -r '.context_name' "$output_json")"
  plugin="$(jq -r '.plugin' "$output_json")"
  environment="$(jq -r '.environment' "$output_json")"
  site="$(jq -r '.site' "$output_json")"
  project_name="$(jq -r '.project_name' "$output_json")"
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
    --project-name "$project_name" \
    --compose-project-name "$compose_project_name" \
    --docker-socket /var/run/docker.sock \
    --env-file .env \
    --default
}

run_healthcheck() {
  local home_dir="$1" output_json="$2"
  local context timeout interval

  context="$(jq -r '.context_name' "$output_json")"
  timeout="$(jq -r '.healthcheck_timeout' "$output_json")"
  interval="$(jq -r '.healthcheck_interval' "$output_json")"

  HOME="$home_dir" sitectl healthcheck \
    --context "$context" \
    --persist \
    --timeout "$timeout" \
    --interval "$interval" \
    --format table
}

run_target() (
  set -euo pipefail

  local target="$1"
  local root workdir key_path home_dir output_json public_key
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
  mapfile -d '' -t var_args < <(target_var_args "$root" "$key_path" "$target")

  auto_args=()
  if [[ -n "${GITHUB_ACTIONS:-}" || "${CLOUD_COMPOSE_SMOKE_AUTO_APPROVE:-}" == "true" ]]; then
    auto_args=(-auto-approve)
  fi

  cleanup_started=false
  # shellcheck disable=SC2317
  cleanup() {
    local status=$?
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
      provider_tag_cleanup "$target" || cleanup_status=$?
    fi
    if [[ "$status" -eq 0 && "$destroy_status" -ne 0 && "$cleanup_status" -ne 0 ]]; then
      exit "$destroy_status"
    fi
    exit "$status"
  }
  trap cleanup EXIT INT TERM HUP

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

  configure_sitectl_context "$home_dir" "$key_path" "$output_json"
  if ! run_healthcheck "$home_dir" "$output_json"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi

  echo "${target} smoke test passed"
)

destroy_target() (
  set -euo pipefail

  local target="$1"
  local root workdir key_path destroy_status destroy_timeout cleanup_status
  local -a auto_args var_args

  root="$(target_root "$target")"
  target_env "$target"

  workdir="$(target_workdir "$target")"
  key_path="$workdir/id_ed25519"
  mapfile -d '' -t var_args < <(target_var_args "$root" "$key_path" "$target")

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
  local target provider

  if [[ "$#" -ne 1 ]]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    sweep)
      for target in $(default_targets); do
        provider="$(target_provider "$target")"
        require_cmd jq
        case "$provider" in
          digitalocean | linode)
            require_cmd curl
            ;;
          gcp)
            require_cmd gcloud
            ;;
        esac
        target_env "$target"
        provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}"
      done
      exit 0
      ;;
    sweep-*)
      target="${1#sweep-}"
      provider="$(target_provider "$target")"
      require_cmd jq
      case "$provider" in
        digitalocean | linode)
          require_cmd curl
          ;;
        gcp)
          require_cmd gcloud
          ;;
      esac
      target_env "$target"
      provider_tag_cleanup "$target" "${CLOUD_COMPOSE_SMOKE_RUN_ID:-}"
      exit 0
      ;;
    destroy-*)
      target="${1#destroy-}"
      provider="$(target_provider "$target")"
      require_cmd jq
      require_cmd terraform
      case "$provider" in
        digitalocean | linode)
          require_cmd curl
          ;;
        gcp)
          require_cmd gcloud
          ;;
      esac
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

main "$@"
