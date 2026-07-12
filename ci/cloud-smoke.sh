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
  CLOUD_COMPOSE_SMOKE_BOOT_TIMEOUT=1200   Seconds to wait for SSH and cloud-init.
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

api_request() {
  local provider="$1" method="$2" path="$3"
  local base_url body http_code response token token_name

  case "$provider" in
    digitalocean)
      token="${DIGITALOCEAN_TOKEN:-}"
      token_name="DIGITALOCEAN_TOKEN"
      base_url="https://api.digitalocean.com/v2"
      ;;
    linode)
      token="${LINODE_TOKEN:-}"
      token_name="LINODE_TOKEN"
      base_url="https://api.linode.com/v4"
      ;;
  esac

  if response="$(curl -sS -X "$method" -H "Authorization: Bearer ${token}" -w $'\n%{http_code}' "${base_url}${path}")"; then
    http_code="${response##*$'\n'}"
    body="${response%$'\n'"$http_code"}"
  else
    echo "${provider} API request failed for ${method} ${path}; check ${token_name} and network access." >&2
    return 1
  fi

  case "$http_code" in
    2??)
      printf '%s' "$body"
      ;;
    401)
      echo "${provider} API rejected ${token_name} with HTTP 401 for ${method} ${path}; verify the GitHub secret is current and valid for this provider." >&2
      return 22
      ;;
    403)
      echo "${provider} API rejected ${token_name} with HTTP 403 for ${method} ${path}; verify the token has the permissions required by smoke cleanup and Terraform." >&2
      return 22
      ;;
    *)
      echo "${provider} API returned HTTP ${http_code} for ${method} ${path}." >&2
      if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >&2
      fi
      return 22
      ;;
  esac
}

api_delete() {
  api_request "$1" DELETE "$2" >/dev/null
}

api_get() {
  api_request "$1" GET "$2"
}

gcp_region() {
  printf '%s\n' "${GCLOUD_REGION:-us-east5}"
}

gcp_zone() {
  printf '%s\n' "${GCLOUD_ZONE:-$(gcp_region)-b}"
}

delete_ids() {
  local provider="$1" path_prefix="$2" id attempt
  local failed=0 deleted

  while IFS= read -r id; do
    if [[ -z "$id" ]]; then
      continue
    fi
    deleted=false
    for attempt in {1..12}; do
      echo "Deleting ${provider} ${path_prefix}/${id} (attempt ${attempt})"
      if api_delete "$provider" "${path_prefix}/${id}"; then
        deleted=true
        break
      fi
      sleep 10
    done
    if [[ "$deleted" != "true" ]]; then
      echo "Failed to delete ${provider} ${path_prefix}/${id} after 12 attempts" >&2
      failed=1
    fi
  done

  return "$failed"
}

gcp_command_with_retry() {
  local operation="$1" description="$2" attempt
  shift 2

  for attempt in {1..12}; do
    echo "${operation} gcp ${description} (attempt ${attempt})"
    if gcloud "$@"; then
      return 0
    fi
    if ((attempt < 12)); then
      sleep 10
    fi
  done

  echo "Failed while ${operation,,} gcp ${description} after 12 attempts" >&2
  return 1
}

gcp_delete_with_retry() {
  local description="$1"
  shift

  gcp_command_with_retry "Deleting" "$description" "$@"
}

gcp_remove_with_retry() {
  local description="$1"
  shift

  gcp_command_with_retry "Removing" "$description" "$@"
}

gcp_project_iam_rows() {
  local project="$1" name_filter="$2" account_pattern

  account_pattern="(vm-|internal-|ppb-)?${name_filter#^}.*@${project}\\.iam\\.gserviceaccount\\.com"
  gcloud projects get-iam-policy "$project" --format=json |
    jq -r \
      --arg account_pattern "$account_pattern" \
      --arg start_role "projects/${project}/roles/startVM" \
      --arg suspend_role "projects/${project}/roles/suspendVM" '
        [$start_role, $suspend_role, "roles/logging.logWriter", "roles/monitoring.metricWriter"] as $managed_roles |
        .bindings[]? |
        select(.condition == null) |
        select(.role as $role | $managed_roles | index($role)) |
        .role as $role |
        .members[]? |
        select(test("^(deleted:)?serviceAccount:" + $account_pattern + "(\\?uid=[^[:space:]]+)?$")) |
        [$role, .] | @tsv
      '
}

gcp_smoke_residuals() {
  local project="$1" name_filter="$2" region="$3"
  local output name email role member

  if ! output="$(gcloud run services list \
    --project "$project" \
    --region "$region" \
    --filter="metadata.name~'${name_filter}'" \
    --format='value(metadata.name)')"; then
    echo "Could not verify Cloud Run cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'cloud-run\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcloud compute instances list \
    --project "$project" \
    --filter="name~'${name_filter}'" \
    --format='value(name)')"; then
    echo "Could not verify GCP instance cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'instance\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcloud compute firewall-rules list \
    --project "$project" \
    --filter="name~'^(allow-ssh-ipv4-|allow-ssh-ipv6-|allow-rollout-ipv4-)${name_filter#^}'" \
    --format='value(name)')"; then
    echo "Could not verify GCP firewall cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'firewall\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcloud compute disks list \
    --project "$project" \
    --filter="name~'${name_filter}'" \
    --format='value(name)')"; then
    echo "Could not verify GCP disk cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'disk\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcloud iam service-accounts list \
    --project "$project" \
    --filter="email~'^(vm-|internal-|ppb-)?${name_filter#^}.*@${project}\\.iam\\.gserviceaccount\\.com$'" \
    --format='value(email)')"; then
    echo "Could not verify GCP service-account cleanup" >&2
    return 1
  fi
  while IFS= read -r email; do
    [[ -n "$email" ]] && printf 'service-account\t%s\n' "$email"
  done <<<"$output"

  if ! output="$(gcloud compute networks subnets list \
    --project "$project" \
    --filter="name~'${name_filter}'" \
    --format='value(name)')"; then
    echo "Could not verify GCP subnetwork cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'subnetwork\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcloud compute networks list \
    --project "$project" \
    --filter="name~'${name_filter}'" \
    --format='value(name)')"; then
    echo "Could not verify GCP network cleanup" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && printf 'network\t%s\n' "$name"
  done <<<"$output"

  if ! output="$(gcp_project_iam_rows "$project" "$name_filter")"; then
    echo "Could not verify GCP project-IAM cleanup" >&2
    return 1
  fi
  while IFS=$'\t' read -r role member; do
    [[ -n "$role" && -n "$member" ]] && printf 'project-iam\t%s\t%s\n' "$role" "$member"
  done <<<"$output"

  return 0
}

gcp_verify_no_smoke_resources() {
  local project="$1" name_filter="$2" region="$3"
  local attempt residuals

  for attempt in {1..12}; do
    residuals=""
    if residuals="$(gcp_smoke_residuals "$project" "$name_filter" "$region")"; then
      if [[ -z "$residuals" ]]; then
        echo "Verified that no matching gcp smoke resources remain"
        return 0
      fi
      echo "Matching gcp smoke resources remain after cleanup attempt ${attempt}:" >&2
      printf '%s\n' "$residuals" >&2
    else
      echo "Could not complete gcp residual-resource verification (attempt ${attempt})" >&2
    fi
    if ((attempt < 12)); then
      sleep 10
    fi
  done

  echo "GCP smoke cleanup left matching resources or could not verify their removal" >&2
  return 1
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
  local cleanup_status=0

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
        delete_ids digitalocean "/firewalls" || cleanup_status=1
      api_get digitalocean "/droplets?tag_name=cloud-compose-smoke&per_page=200" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.droplets[]? | select((.tags // []) | index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids digitalocean "/droplets" || cleanup_status=1
      sleep 10
      api_get digitalocean "/volumes?tag_name=cloud-compose-smoke&per_page=200" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.volumes[]? | select((.tags // []) | index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids digitalocean "/volumes" || cleanup_status=1
      ;;
    linode)
      api_get linode "/networking/firewalls?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/networking/firewalls" || cleanup_status=1
      api_get linode "/linode/instances?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/linode/instances" || cleanup_status=1
      sleep 10
      api_get linode "/volumes?page_size=500" |
        jq -r --arg target "$target" --arg run_tag "$run_tag" '.data[]? | select((.tags // []) | index("cloud-compose-smoke") and index($target)) | select($run_tag == "" or ((.tags // []) | index($run_tag))) | .id' |
        delete_ids linode "/volumes" || cleanup_status=1
      ;;
    gcp)
      local project name_filter region cloud_run_services instance_rows firewall_names disk_rows
      local project_iam_rows service_accounts subnetwork_rows network_names
      local zone_url region_url name email role member cloud_run_policy
      project="$GCLOUD_PROJECT"
      region="$(gcp_region)"
      name_filter="^${name_prefix}-"
      if [[ -n "$run_id" ]]; then
        name_filter="^${name_prefix}-$(printf '%s' "$run_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-8)-"
      fi

      if ! cloud_run_services="$(gcloud run services list \
        --project "$project" \
        --region "$region" \
        --filter="metadata.name~'${name_filter}'" \
        --format='value(metadata.name)')"; then
        cleanup_status=1
        cloud_run_services=""
      fi
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        cloud_run_policy=""
        if cloud_run_policy="$(gcloud run services get-iam-policy "$name" \
          --project "$project" \
          --region "$region" \
          --format=json)"; then
          if ! jq -e 'type == "object" and ((has("bindings") | not) or (.bindings | type == "array"))' \
            <<<"$cloud_run_policy" >/dev/null; then
            echo "Cloud Run IAM policy for ${name} was not valid JSON policy data" >&2
            cleanup_status=1
          elif jq -e '
            any(.bindings[]?;
              .role == "roles/run.invoker" and
              .condition == null and
              any(.members[]?; . == "allUsers")
            )
          ' <<<"$cloud_run_policy" >/dev/null; then
            if ! gcp_remove_with_retry "Cloud Run invoker from ${name}" \
              run services remove-iam-policy-binding "$name" \
              --project "$project" \
              --region "$region" \
              --member allUsers \
              --role roles/run.invoker \
              --condition=None \
              --quiet; then
              cleanup_status=1
            fi
          fi
        else
          echo "Could not inspect Cloud Run IAM policy for ${name}" >&2
          cleanup_status=1
        fi
        if ! gcp_delete_with_retry "Cloud Run service ${name}" run services delete "$name" \
          --project "$project" \
          --region "$region" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$cloud_run_services"

      if ! instance_rows="$(gcloud compute instances list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format=json |
        jq -r '.[]? | [.zone, .name] | @tsv')"; then
        cleanup_status=1
        instance_rows=""
      fi
      while IFS=$'\t' read -r zone_url name; do
        [[ -n "$name" ]] || continue
        if ! gcp_delete_with_retry "instance ${name}" compute instances delete "$name" \
          --project "$project" \
          --zone "${zone_url##*/}" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$instance_rows"

      if ! firewall_names="$(gcloud compute firewall-rules list \
        --project "$project" \
        --filter="name~'^(allow-ssh-ipv4-|allow-ssh-ipv6-|allow-rollout-ipv4-)${name_filter#^}'" \
        --format='value(name)')"; then
        cleanup_status=1
        firewall_names=""
      fi
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! gcp_delete_with_retry "firewall ${name}" compute firewall-rules delete "$name" \
          --project "$project" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$firewall_names"

      if ! disk_rows="$(gcloud compute disks list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format=json |
        jq -r '.[]? | [.zone, .name] | @tsv')"; then
        cleanup_status=1
        disk_rows=""
      fi
      while IFS=$'\t' read -r zone_url name; do
        [[ -n "$name" ]] || continue
        if ! gcp_delete_with_retry "disk ${name}" compute disks delete "$name" \
          --project "$project" \
          --zone "${zone_url##*/}" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$disk_rows"

      if ! project_iam_rows="$(gcp_project_iam_rows "$project" "$name_filter")"; then
        cleanup_status=1
        project_iam_rows=""
      fi
      while IFS=$'\t' read -r role member; do
        [[ -n "$role" && -n "$member" ]] || continue
        if ! gcp_remove_with_retry "project IAM binding ${role} for ${member}" \
          projects remove-iam-policy-binding "$project" \
          --member "$member" \
          --role "$role" \
          --condition=None \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$project_iam_rows"

      if ! service_accounts="$(gcloud iam service-accounts list \
        --project "$project" \
        --filter="email~'^(vm-|internal-|ppb-)?${name_filter#^}.*@${project}\\.iam\\.gserviceaccount\\.com$'" \
        --format='value(email)')"; then
        cleanup_status=1
        service_accounts=""
      fi
      while IFS= read -r email; do
        [[ -n "$email" ]] || continue
        if ! gcp_delete_with_retry "service account ${email}" iam service-accounts delete "$email" \
          --project "$project" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$service_accounts"

      if ! subnetwork_rows="$(gcloud compute networks subnets list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format=json |
        jq -r '.[]? | [.region, .name] | @tsv')"; then
        cleanup_status=1
        subnetwork_rows=""
      fi
      while IFS=$'\t' read -r region_url name; do
        [[ -n "$name" ]] || continue
        if ! gcp_delete_with_retry "subnetwork ${name}" compute networks subnets delete "$name" \
          --project "$project" \
          --region "${region_url##*/}" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$subnetwork_rows"

      if ! network_names="$(gcloud compute networks list \
        --project "$project" \
        --filter="name~'${name_filter}'" \
        --format='value(name)')"; then
        cleanup_status=1
        network_names=""
      fi
      while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! gcp_delete_with_retry "network ${name}" compute networks delete "$name" \
          --project "$project" \
          --quiet; then
          cleanup_status=1
        fi
      done <<<"$network_names"

      if ! gcp_verify_no_smoke_resources "$project" "$name_filter" "$region"; then
        cleanup_status=1
      fi
      ;;
  esac

  return "$cleanup_status"
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

    ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set -euo pipefail
export HOME=/home/cloud-compose
source /home/cloud-compose/profile.sh
exec sitectl healthcheck --context ${quoted_context} --persist --format table
'"
    return
  fi

  HOME="$home_dir" sitectl healthcheck \
    --context "$context" \
    --persist \
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
  if ! run_healthcheck "$home_dir" "$key_path" "$output_json"; then
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
