#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

# Reuse the production smoke runner's strict SSH, bootstrap, diagnostics,
# sitectl context, healthcheck, provider-sweep, and timeout behavior.
# shellcheck source=ci/cloud-smoke.sh
source "$script_dir/cloud-smoke.sh"

readonly upgrade_base_sha="f33117cdbbf4a9c7d59006a4db986baef118e6bb"
readonly resource_prefix="module.app.module.gcp[0]"
readonly data_disk_address="${resource_prefix}.google_compute_disk.data"
readonly docker_disk_address="${resource_prefix}.google_compute_disk.docker-volumes"
readonly boot_disk_address="${resource_prefix}.google_compute_disk.boot"
readonly vm_address="${resource_prefix}.google_compute_instance.cloud-compose"
readonly legacy_start_address="${resource_prefix}.google_project_iam_member.gce-start[0]"
readonly legacy_suspend_address="${resource_prefix}.google_project_iam_member.gce-suspend"
readonly legacy_gsa_user_address="${resource_prefix}.google_service_account_iam_member.gsa-user"
readonly legacy_vm_token_creator_address="${resource_prefix}.google_service_account_iam_member.token-creator"
readonly legacy_app_token_creator_address="${resource_prefix}.google_service_account_iam_member.self_jwt_signer_policy"
readonly conditional_app_token_creator_address="${resource_prefix}.google_service_account_iam_member.vault_agent_jwt_signer_policy[0]"
readonly scoped_start_address="${resource_prefix}.google_compute_instance_iam_member.gce-start[0]"
readonly scoped_suspend_address="${resource_prefix}.google_compute_instance_iam_member.gce-suspend[0]"
readonly -a legacy_removed_from_addresses=(
  "$legacy_start_address"
  "$legacy_suspend_address"
  "$legacy_gsa_user_address"
  "$legacy_vm_token_creator_address"
  "$legacy_app_token_creator_address"
)
readonly -a legacy_removed_to_addresses=(
  "$legacy_start_address"
  "$legacy_suspend_address"
  "$legacy_gsa_user_address"
  "$legacy_vm_token_creator_address"
  "$conditional_app_token_creator_address"
)

readonly -a moved_from_addresses=(
  "${resource_prefix}.google_service_account.internal-services"
  "${resource_prefix}.google_service_account_iam_member.internal-services-keys"
  "${resource_prefix}.google_project_iam_member.stackdriver"
  "${resource_prefix}.google_service_account_iam_member.app-keys"
)
readonly -a moved_to_addresses=(
  "${resource_prefix}.google_service_account.internal-services[0]"
  "${resource_prefix}.google_service_account_iam_member.internal-services-keys[0]"
  "${resource_prefix}.google_project_iam_member.stackdriver[0]"
  "${resource_prefix}.google_service_account_iam_member.app-keys[0]"
)

usage() {
  cat <<'EOF'
Usage:
  ci/gcp-upgrade-smoke.sh run
  ci/gcp-upgrade-smoke.sh destroy
  ci/gcp-upgrade-smoke.sh check-plan PLAN_JSON
  ci/gcp-upgrade-smoke.sh check-transition OLD_IDS NEW_IDS OLD_STATE_LIST NEW_STATE_LIST

The run command provisions the exact cloud-compose 0.10.2 release, preserves
its local Terraform state, upgrades that state with the checked-out commit,
proves the expected moves/replacements and disk persistence, then destroys the
disposable resources. The pre-provisioned CI network and subnet remain outside
the upgrade state. The destroy command is an idempotent same-job cleanup fallback.
EOF
}

fail() {
  echo "GCP upgrade smoke: $*" >&2
  return 1
}

exact_run_namespace() {
  local run_id="$1" runner

  runner="${CLOUD_COMPOSE_CI_BIN:-$repo_root/.bin/cloud-compose-ci}"
  if [[ ! -x "$runner" ]]; then
    fail "compiled CI runner is missing at ${runner}; run 'make cloud-compose-ci' first"
    return 1
  fi
  "$runner" gcp namespace --run-id "$run_id"
}

upgrade_run_id() {
  local requested="${CLOUD_COMPOSE_SMOKE_RUN_ID:-}"

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    [[ -n "${GITHUB_RUN_ID:-}" ]] || fail "GITHUB_RUN_ID is required in GitHub Actions"
    if [[ -n "$requested" && "$requested" != "$GITHUB_RUN_ID" ]]; then
      fail "CLOUD_COMPOSE_SMOKE_RUN_ID must match GITHUB_RUN_ID in GitHub Actions"
      return 1
    fi
    printf '%s\n' "$GITHUB_RUN_ID"
    return 0
  fi

  [[ -n "$requested" ]] ||
    fail "CLOUD_COMPOSE_SMOKE_RUN_ID must be set explicitly outside GitHub Actions"
  printf '%s\n' "$requested"
}

valid_ipv4() {
  local value="$1" part
  local -a parts=()

  [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<<"$value"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}

valid_custom_role() {
  local value="$1"

  [[ "$value" =~ ^(projects/([a-z0-9][a-z0-9.-]*:)?[a-z][a-z0-9-]{4,28}[a-z0-9]|organizations/[0-9]+)/roles/[A-Za-z0-9_.]+$ ]]
}

valid_direct_vpc_cidr() {
  local address="${1%/*}" prefix="${1##*/}"
  local first second
  local -a octets=()

  valid_ipv4 "$address" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<<"$address"
  first=$((10#${octets[0]}))
  second=$((10#${octets[1]}))
  prefix=$((10#$prefix))

  ((
    (first == 10 && prefix >= 8) ||
      (first == 172 && second >= 16 && second <= 31 && prefix >= 12) ||
      (first == 192 && second == 168 && prefix >= 16) ||
      (first == 100 && second >= 64 && second <= 127 && prefix >= 10) ||
      (first >= 240 && prefix >= 4)
  ))
}

validate_upgrade_network_ownership() {
  local project="$1" network_project="$2" network_reference="$3" subnetwork_reference="$4"
  local network_name subnetwork_name

  [[ "$network_project" == "$project" ]] ||
    fail "GCLOUD_NETWORK_PROJECT_ID must equal GCLOUD_PROJECT for the 0.10.2 baseline"

  network_reference="${network_reference%/}"
  subnetwork_reference="${subnetwork_reference%/}"
  network_name="${network_reference##*/}"
  subnetwork_name="${subnetwork_reference##*/}"
  [[ -n "$network_name" && "$network_name" != cc-g-wp-* ]] ||
    fail "the persistent upgrade network must not use the disposable cc-g-wp- prefix"
  [[ -n "$subnetwork_name" && "$subnetwork_name" != cc-g-wp-* ]] ||
    fail "the persistent upgrade subnet must not use the disposable cc-g-wp- prefix"
}

validate_upgrade_network() {
  local project="$1" region="$2" network_reference="$3" subnetwork_reference="$4"
  local network_name subnetwork_name network_json subnetwork_json subnet_cidr subnet_prefix

  validate_upgrade_network_ownership \
    "$project" \
    "$GCLOUD_NETWORK_PROJECT_ID" \
    "$network_reference" \
    "$subnetwork_reference"

  network_reference="${network_reference%/}"
  subnetwork_reference="${subnetwork_reference%/}"
  network_name="${network_reference##*/}"
  subnetwork_name="${subnetwork_reference##*/}"

  network_json="$(gcloud compute networks describe "$network_name" \
    --project "$GCLOUD_NETWORK_PROJECT_ID" \
    --format=json)"
  subnetwork_json="$(gcloud compute networks subnets describe "$subnetwork_name" \
    --project "$GCLOUD_NETWORK_PROJECT_ID" \
    --region "$region" \
    --format=json)"

  jq -e \
    --arg project "$GCLOUD_NETWORK_PROJECT_ID" \
    --arg network "$network_name" '
      .name == $network and
      (.selfLink | endswith("/projects/" + $project + "/global/networks/" + $network)) and
      (.mtu | tonumber) == 1460
    ' <<<"$network_json" >/dev/null ||
    fail "the persistent upgrade network must exist in the configured project with the Cloud Run default MTU of 1460"

  jq -e \
    --arg project "$GCLOUD_NETWORK_PROJECT_ID" \
    --arg region "$region" \
    --arg network "$network_name" \
    --arg subnetwork "$subnetwork_name" '
      .name == $subnetwork and
      (.selfLink | endswith("/projects/" + $project + "/regions/" + $region + "/subnetworks/" + $subnetwork)) and
      (.network | endswith("/projects/" + $project + "/global/networks/" + $network)) and
      (.ipCidrRange | type == "string")
    ' <<<"$subnetwork_json" >/dev/null ||
    fail "the persistent upgrade subnet must exist in the configured region and belong to the configured network"

  subnet_cidr="$(jq -er '.ipCidrRange' <<<"$subnetwork_json")"
  subnet_prefix="${subnet_cidr##*/}"
  valid_direct_vpc_cidr "$subnet_cidr" ||
    fail "the persistent subnet CIDR is outside Cloud Run Direct VPC supported IPv4 ranges: ${subnet_cidr}"
  [[ "$subnet_prefix" =~ ^[0-9]+$ ]] && ((10#$subnet_prefix <= 26)) ||
    fail "the persistent Direct VPC subnet must be /26 or larger (found ${subnet_cidr})"
}

assert_upgrade_plan() {
  local plan_json="$1" index previous_address current_address

  [[ -s "$plan_json" ]] || fail "plan JSON is missing: $plan_json"
  jq -e '.format_version and (.resource_changes | type == "array")' "$plan_json" >/dev/null ||
    fail "Terraform plan JSON is invalid"

  for index in "${!moved_from_addresses[@]}"; do
    previous_address="${moved_from_addresses[$index]}"
    current_address="${moved_to_addresses[$index]}"
    jq -e \
      --arg previous "$previous_address" \
      --arg current "$current_address" '
        any(.resource_changes[]?;
          .address == $current and
          .previous_address == $previous and
          ((.change.actions | index("delete")) == null)
        )
      ' "$plan_json" >/dev/null ||
      fail "plan did not preserve moved resource ${previous_address} -> ${current_address}"
  done

  for current_address in "$data_disk_address" "$docker_disk_address"; do
    jq -e --arg address "$current_address" '
      any(.resource_changes[]?;
        .address == $address and .change.actions == ["no-op"]
      )
    ' "$plan_json" >/dev/null ||
      fail "persistent disk was not a no-op in the upgrade plan: ${current_address}"
  done

  for index in "${!legacy_removed_to_addresses[@]}"; do
    previous_address="${legacy_removed_from_addresses[$index]}"
    current_address="${legacy_removed_to_addresses[$index]}"
    jq -e --arg address "$current_address" '
      any(.resource_changes[]?;
        .address == $address and .change.actions == ["delete"]
      )
    ' "$plan_json" >/dev/null ||
      fail "upgrade plan did not remove the legacy over-broad IAM binding: ${current_address}"
    if [[ "$previous_address" != "$current_address" ]]; then
      jq -e --arg previous "$previous_address" --arg current "$current_address" '
        any(.resource_changes[]?;
          .address == $current and .previous_address == $previous
        )
      ' "$plan_json" >/dev/null ||
        fail "plan did not preserve moved-resource provenance before removing ${previous_address}"
    fi
  done

  for current_address in "$scoped_start_address" "$scoped_suspend_address"; do
    jq -e --arg address "$current_address" '
      any(.resource_changes[]?;
        .address == $address and .change.actions == ["create"]
      )
    ' "$plan_json" >/dev/null ||
      fail "upgrade plan did not create the instance-scoped power binding: ${current_address}"
  done

  jq -e \
    --arg boot "$boot_disk_address" \
    --arg vm "$vm_address" \
    --arg legacy_start "$legacy_start_address" \
    --arg legacy_suspend "$legacy_suspend_address" \
    --arg legacy_gsa_user "$legacy_gsa_user_address" \
    --arg legacy_vm_token_creator "$legacy_vm_token_creator_address" \
    --arg conditional_app_token_creator "$conditional_app_token_creator_address" '
      def replacement:
        . == ["delete", "create"] or . == ["create", "delete"];

      ([
        .resource_changes[]? |
        select((.mode // "managed") == "managed") |
        select(.change.actions | index("delete")) |
        .address
      ] | sort) == ([$boot, $vm, $legacy_start, $legacy_suspend, $legacy_gsa_user, $legacy_vm_token_creator, $conditional_app_token_creator] | sort) and
      all(.resource_changes[]?;
        if (.mode // "managed") == "data" then
          true
        elif .address == $boot or .address == $vm then
          (.change.actions | replacement)
        elif .address == $legacy_start or
             .address == $legacy_suspend or
             .address == $legacy_gsa_user or
             .address == $legacy_vm_token_creator or
             .address == $conditional_app_token_creator then
          .change.actions == ["delete"]
        else
          ((.change.actions | index("delete")) == null)
        end
      )
    ' "$plan_json" >/dev/null ||
    fail "upgrade plan contained a managed-resource deletion beyond the expected VM/boot replacements and legacy IAM removals"
}

assert_state_transition() {
  local old_ids="$1" new_ids="$2" old_state_list="$3" new_state_list="$4"
  local key address index previous_address current_address

  for key in data_disk docker_disk internal_service_account internal_service_keys stackdriver app_key_admin; do
    jq -ne \
      --slurpfile old "$old_ids" \
      --slurpfile new "$new_ids" \
      --arg key "$key" '
        ($old[0][$key] | type == "string" and length > 0) and
        $old[0][$key] == $new[0][$key]
      ' >/dev/null ||
      fail "resource identity changed across the upgrade: ${key}"
  done

  for key in boot_disk vm; do
    jq -ne \
      --slurpfile old "$old_ids" \
      --slurpfile new "$new_ids" \
      --arg key "$key" '
        ($old[0][$key] | type == "string" and length > 0) and
        ($new[0][$key] | type == "string" and length > 0) and
        $old[0][$key] != $new[0][$key]
      ' >/dev/null ||
      fail "expected replacement did not change resource identity: ${key}"
  done

  for key in legacy_start legacy_suspend; do
    jq -e --arg key "$key" '.[$key] | type == "string" and length > 0' "$old_ids" >/dev/null ||
      fail "baseline state did not capture the legacy project-wide power binding: ${key}"
  done
  for key in scoped_start scoped_suspend; do
    jq -e --arg key "$key" '.[$key] | type == "string" and length > 0' "$new_ids" >/dev/null ||
      fail "upgraded state did not capture the instance-scoped power binding: ${key}"
  done

  for address in "${moved_from_addresses[@]}"; do
    grep -Fxq "$address" "$old_state_list" ||
      fail "baseline state did not contain expected legacy address: ${address}"
    if grep -Fxq "$address" "$new_state_list"; then
      fail "upgraded state retained legacy address: ${address}"
    fi
  done
  for address in "${moved_to_addresses[@]}"; do
    grep -Fxq "$address" "$new_state_list" ||
      fail "upgraded state did not contain moved address: ${address}"
  done
  for index in "${!legacy_removed_from_addresses[@]}"; do
    previous_address="${legacy_removed_from_addresses[$index]}"
    current_address="${legacy_removed_to_addresses[$index]}"
    grep -Fxq "$previous_address" "$old_state_list" ||
      fail "baseline state did not contain expected legacy IAM binding: ${previous_address}"
    if grep -Fxq "$previous_address" "$new_state_list" || grep -Fxq "$current_address" "$new_state_list"; then
      fail "upgraded state retained legacy IAM binding: ${previous_address}"
    fi
  done
  for address in "$scoped_start_address" "$scoped_suspend_address"; do
    if grep -Fxq "$address" "$old_state_list"; then
      fail "baseline state unexpectedly contained current instance-scoped power binding: ${address}"
    fi
    grep -Fxq "$address" "$new_state_list" ||
      fail "upgraded state did not contain instance-scoped power binding: ${address}"
  done
}

state_resource_attribute() {
  local state_json="$1" address="$2" attribute="${3:-id}"

  jq -er --arg address "$address" --arg attribute "$attribute" '
    def all_resources:
      .resources[]?,
      (.child_modules[]? | all_resources);

    .values.root_module |
    all_resources |
    select(.address == $address) |
    .values[$attribute] |
    select(type == "string" and length > 0)
  ' "$state_json"
}

capture_state_resource_attribute() {
  local state_json="$1" address="$2" attribute="${3:-id}"
  local value

  if ! value="$(state_resource_attribute "$state_json" "$address" "$attribute")"; then
    fail "state did not expose ${attribute} for ${address}"
    return 1
  fi
  printf '%s\n' "$value"
}

write_phase_ids() {
  local phase="$1" state_json="$2" destination="$3"
  local internal_service_account internal_service_keys stackdriver app_key_admin start_binding suspend_binding
  local data_disk_id docker_disk_id boot_disk_id vm_id internal_service_account_id
  local internal_service_keys_id stackdriver_id app_key_admin_id start_binding_id suspend_binding_id

  case "$phase" in
    old)
      internal_service_account="${moved_from_addresses[0]}"
      internal_service_keys="${moved_from_addresses[1]}"
      stackdriver="${moved_from_addresses[2]}"
      app_key_admin="${moved_from_addresses[3]}"
      start_binding="$legacy_start_address"
      suspend_binding="$legacy_suspend_address"
      ;;
    new)
      internal_service_account="${moved_to_addresses[0]}"
      internal_service_keys="${moved_to_addresses[1]}"
      stackdriver="${moved_to_addresses[2]}"
      app_key_admin="${moved_to_addresses[3]}"
      start_binding="$scoped_start_address"
      suspend_binding="$scoped_suspend_address"
      ;;
    *) fail "unknown state-capture phase: $phase" ;;
  esac

  data_disk_id="$(capture_state_resource_attribute "$state_json" "$data_disk_address")" || return 1
  docker_disk_id="$(capture_state_resource_attribute "$state_json" "$docker_disk_address")" || return 1
  boot_disk_id="$(capture_state_resource_attribute "$state_json" "$boot_disk_address" disk_id)" || return 1
  vm_id="$(capture_state_resource_attribute "$state_json" "$vm_address" instance_id)" || return 1
  internal_service_account_id="$(capture_state_resource_attribute "$state_json" "$internal_service_account")" || return 1
  internal_service_keys_id="$(capture_state_resource_attribute "$state_json" "$internal_service_keys")" || return 1
  stackdriver_id="$(capture_state_resource_attribute "$state_json" "$stackdriver")" || return 1
  app_key_admin_id="$(capture_state_resource_attribute "$state_json" "$app_key_admin")" || return 1
  start_binding_id="$(capture_state_resource_attribute "$state_json" "$start_binding")" || return 1
  suspend_binding_id="$(capture_state_resource_attribute "$state_json" "$suspend_binding")" || return 1

  jq -n \
    --arg data_disk "$data_disk_id" \
    --arg docker_disk "$docker_disk_id" \
    --arg boot_disk "$boot_disk_id" \
    --arg vm "$vm_id" \
    --arg internal_service_account "$internal_service_account_id" \
    --arg internal_service_keys "$internal_service_keys_id" \
    --arg stackdriver "$stackdriver_id" \
    --arg app_key_admin "$app_key_admin_id" \
    --arg start_binding "$start_binding_id" \
    --arg suspend_binding "$suspend_binding_id" \
    --arg phase "$phase" '
      ({
        data_disk: $data_disk,
        docker_disk: $docker_disk,
        boot_disk: $boot_disk,
        vm: $vm,
        internal_service_account: $internal_service_account,
        internal_service_keys: $internal_service_keys,
        stackdriver: $stackdriver,
        app_key_admin: $app_key_admin
      }) + if $phase == "old" then {
        legacy_start: $start_binding,
        legacy_suspend: $suspend_binding
      } else {
        scoped_start: $start_binding,
        scoped_suspend: $suspend_binding
      } end
    ' >"$destination"
  chmod 0600 "$destination"
}

tf_in() {
  local root="$1" data_dir="$2"
  shift 2

  TF_DATA_DIR="$data_dir" terraform -chdir="$root" "$@"
}

initialize_phase() {
  local root="$1" data_dir="$2" state_path="$3"

  mkdir -p "$data_dir"
  tf_in "$root" "$data_dir" init \
    -input=false \
    -reconfigure \
    -backend-config="path=${state_path}"
  tf_in "$root" "$data_dir" validate
}

phase_output() {
  local root="$1" data_dir="$2" output_json="$3"

  tf_in "$root" "$data_dir" output -json smoke >"$output_json"
  chmod 0600 "$output_json"
}

dump_remote_logs_from_output() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local host port user project_dir

  host="$(jq -er '.host' "$output_json")"
  port="$(jq -er '.ssh_port' "$output_json")"
  user="$(jq -er '.ssh_user' "$output_json")"
  project_dir="$(jq -er '.project_dir' "$output_json")"
  dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
}

run_phase_healthcheck() {
  local phase="$1" home_dir="$2" key_path="$3" output_json="$4"
  local host port user project_dir

  host="$(jq -er '.host' "$output_json")"
  port="$(jq -er '.ssh_port' "$output_json")"
  user="$(jq -er '.ssh_user' "$output_json")"
  project_dir="$(jq -er '.project_dir' "$output_json")"

  mkdir -p "$home_dir/.ssh"
  chmod 0700 "$home_dir/.ssh"
  echo "Waiting for the ${phase} GCP host"
  wait_for_ssh "$home_dir" "$key_path" "$host" "$port" "$user"
  if ! wait_for_cloud_init "$home_dir" "$key_path" "$host" "$port" "$user"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set -euo pipefail
sudo systemctl disable --now internal-services.timer internal-services.service 2>/dev/null || true
sudo systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service 2>/dev/null || true
for unit in internal-services.timer internal-services.service cloud-compose-internal-services.timer cloud-compose-internal-services.service; do
  if sudo systemctl is-active --quiet \"\$unit\" 2>/dev/null; then
    echo \"Fixture-only internal service remained active: \$unit\" >&2
    exit 1
  fi
done
'"
  configure_sitectl_context "$home_dir" "$key_path" "$output_json"
  if ! run_healthcheck "$home_dir" "$key_path" "$output_json"; then
    dump_remote_logs "$home_dir" "$key_path" "$host" "$port" "$user" "$project_dir"
    return 1
  fi
}

run_direct_vpc_cold_start() {
  local home_dir="$1" key_path="$2" output_json="$3" instance_name="$4" zone="$5"
  local ingress_url status_code attempt status instance_json previous_host current_host refreshed_output

  ingress_url="$(jq -er '.ingress_url | select(type == "string" and length > 0)' "$output_json")"
  echo "Stopping ${instance_name} before the Cloud Run Direct VPC egress first-request test"
  gcloud compute instances stop "$instance_name" \
    --project "$GCLOUD_PROJECT" \
    --zone "$zone" \
    --quiet

  status=""
  for ((attempt = 1; attempt <= 60; attempt++)); do
    status="$(gcloud compute instances describe "$instance_name" \
      --project "$GCLOUD_PROJECT" \
      --zone "$zone" \
      --format='value(status)')"
    [[ "$status" == "TERMINATED" ]] && break
    sleep 5
  done
  [[ "$status" == "TERMINATED" ]] || fail "instance did not stop before the Direct VPC test (status: ${status})"

  # One curl invocation is deliberate: PPB may retry TCP establishment before
  # sending bytes, but the smoke must not hide a failed first request with an
  # HTTP-level replay. Google must append the actual runner after this hostile
  # prefix so PPB's depth-zero client selection still matches the runner /32.
  echo "Sending one adversarial first request through public Cloud Run with Direct VPC egress"
  status_code="$(curl -4sS \
    --connect-timeout 30 \
    --max-time 600 \
    --output /dev/null \
    --write-out '%{http_code}' \
    --header 'X-Forwarded-For: 10.0.0.8' \
    --header "X-Cloud-Compose-Smoke: ${CLOUD_COMPOSE_SMOKE_RUN_ID}" \
    "$ingress_url")"
  if [[ ! "$status_code" =~ ^(2|3)[0-9][0-9]$ ]]; then
    echo "Direct VPC first-request diagnostics: instance status $(
      gcloud compute instances describe "$instance_name" \
        --project "$GCLOUD_PROJECT" \
        --zone "$zone" \
        --format='value(status)' 2>/dev/null || echo unknown
    )" >&2
    dump_remote_logs_from_output "$home_dir" "$key_path" "$output_json" || true
    fail "the first Cloud Run request over the Direct VPC egress path returned HTTP ${status_code}"
  fi

  # A stopped GCE instance with an ephemeral external address can receive a
  # different SSH address when PPB starts it. The successful public response
  # proves the private Direct VPC path reached the workload; refresh only the
  # test runner's SSH endpoint before performing host-level assertions.
  instance_json="$(gcloud compute instances describe "$instance_name" \
    --project "$GCLOUD_PROJECT" \
    --zone "$zone" \
    --format=json)"
  status="$(jq -er '.status' <<<"$instance_json")"
  [[ "$status" == "RUNNING" ]] ||
    fail "the first Direct VPC request succeeded but the instance is ${status}"
  current_host="$(jq -er '
    .networkInterfaces[0].accessConfigs[0].natIP |
    select(type == "string" and length > 0)
  ' <<<"$instance_json")" ||
    fail "the restarted smoke instance does not expose an external SSH address"
  valid_ipv4 "$current_host" ||
    fail "the restarted smoke instance returned an invalid external SSH address"
  previous_host="$(jq -er '.host' "$output_json")"
  if [[ "$previous_host" != "$current_host" ]]; then
    echo "GCP restart changed the ephemeral SSH address from ${previous_host} to ${current_host}"
  fi
  refreshed_output="$(mktemp "${output_json}.XXXXXX")"
  jq --arg host "$current_host" '.host = $host' "$output_json" >"$refreshed_output"
  chmod 0600 "$refreshed_output"
  mv "$refreshed_output" "$output_json"

  run_phase_healthcheck "post-Direct-VPC cold start" "$home_dir" "$key_path" "$output_json"
}

verify_metadata_isolation() {
  local home_dir="$1" key_path="$2" output_json="$3"
  local host port user remote_script encoded_script quoted_script

  host="$(jq -er '.host' "$output_json")"
  port="$(jq -er '.ssh_port' "$output_json")"
  user="$(jq -er '.ssh_user' "$output_json")"

  read -r -d '' remote_script <<'EOF' || true
set -euo pipefail

metadata_address="169.254.169.254"
metadata_header="Metadata-Flavor: Google"
alpine_image="alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"

# The default bridge must retain normal and Compute internal DNS through the
# metadata resolver, while metadata HTTP and HTTPS remain unreachable.
docker run --rm --network bridge "$alpine_image" /bin/sh -ec '
  nslookup dl-cdn.alpinelinux.org >/dev/null
  nslookup metadata.google.internal | grep -Fq "169.254.169.254"
  for metadata_port in 80 443; do
    if nc -z -w 3 169.254.169.254 "$metadata_port"; then
      echo "Container reached GCP metadata TCP port ${metadata_port}" >&2
      exit 1
    fi
  done
'

# Root retains the narrow access required by key rotation.
curl -fsS --connect-timeout 3 --max-time 10 \
  --header "$metadata_header" \
  "http://${metadata_address}/computeMetadata/v1/instance/id" >/dev/null

# No unprivileged host process may reach either metadata transport.
if sudo -u cloud-compose curl -kfsS --connect-timeout 3 --max-time 5 \
  --header "$metadata_header" \
  "http://${metadata_address}/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
  echo "Unprivileged host process reached GCP metadata HTTP" >&2
  exit 1
fi
if sudo -u cloud-compose curl -kfsS --connect-timeout 3 --max-time 5 \
  --header "$metadata_header" \
  "https://${metadata_address}/computeMetadata/v1/instance/id" >/dev/null 2>&1; then
  echo "Unprivileged host process reached GCP metadata HTTPS" >&2
  exit 1
fi
EOF

  encoded_script="$(printf '%s' "$remote_script" | base64 | tr -d '\n')"
  quoted_script="$(shell_quote "$encoded_script")"
  echo "Verifying GCP DNS continuity and metadata isolation after the replacement boot"
  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "printf %s ${quoted_script} | base64 -d | sudo bash"
}

write_disk_sentinels() {
  local home_dir="$1" key_path="$2" output_json="$3" nonce="$4"
  local host port user encoded_nonce quoted_nonce

  host="$(jq -er '.host' "$output_json")"
  port="$(jq -er '.ssh_port' "$output_json")"
  user="$(jq -er '.ssh_user' "$output_json")"
  encoded_nonce="$(printf '%s' "$nonce" | base64 | tr -d '\n')"
  quoted_nonce="$(shell_quote "$encoded_nonce")"

  ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" "bash -lc 'set -euo pipefail
sudo findmnt -n /mnt/disks/data >/dev/null
sudo findmnt -n /mnt/disks/volumes >/dev/null
printf %s ${quoted_nonce} | base64 -d | sudo tee /mnt/disks/data/.cloud-compose-upgrade-sentinel >/dev/null
printf %s ${quoted_nonce} | base64 -d | sudo tee /mnt/disks/volumes/.cloud-compose-upgrade-sentinel >/dev/null
sudo sync
'"
}

verify_disk_sentinels() {
  local home_dir="$1" key_path="$2" output_json="$3" nonce="$4"
  local host port user actual_data actual_volumes

  host="$(jq -er '.host' "$output_json")"
  port="$(jq -er '.ssh_port' "$output_json")"
  user="$(jq -er '.ssh_user' "$output_json")"
  actual_data="$(ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "sudo cat /mnt/disks/data/.cloud-compose-upgrade-sentinel")"
  actual_volumes="$(ssh_cmd "$home_dir" "$key_path" "$host" "$port" "$user" \
    "sudo cat /mnt/disks/volumes/.cloud-compose-upgrade-sentinel")"

  [[ "$actual_data" == "$nonce" ]] || fail "the persistent data-disk sentinel did not survive the upgrade"
  [[ "$actual_volumes" == "$nonce" ]] || fail "the Docker-volume disk sentinel did not survive the upgrade"
}

write_tfvars() {
  local root="$1" name="$2" project="$3" region="$4" zone="$5" public_key="$6" runner_cidr="$7"
  local network_project="$8" network_name="$9" subnetwork_name="${10}"
  local power_start_role="${11}" power_suspend_role="${12}" legacy_baseline="${13}"

  [[ "$legacy_baseline" == "true" || "$legacy_baseline" == "false" ]] ||
    fail "legacy_baseline must be true or false"

  jq -n \
    --arg name "$name" \
    --arg project "$project" \
    --arg region "$region" \
    --arg zone "$zone" \
    --arg public_key "$public_key" \
    --arg runner_cidr "$runner_cidr" \
    --arg network_project "$network_project" \
    --arg network_name "$network_name" \
    --arg subnetwork_name "$subnetwork_name" \
    --arg power_start_role "$power_start_role" \
    --arg power_suspend_role "$power_suspend_role" \
    --argjson legacy_baseline "$legacy_baseline" '
      {
        name: $name,
        gcp_project_id: $project,
        gcp_region: $region,
        gcp_zone: $zone,
        gcp_network_project_id: $network_project,
        gcp_network_name: $network_name,
        gcp_subnetwork_name: $subnetwork_name,
        gcp_power_start_role: $power_start_role,
        gcp_power_suspend_role: $power_suspend_role,
        legacy_baseline: $legacy_baseline,
        ssh_public_key: $public_key,
        runner_ipv4_cidr: $runner_cidr
      }
    ' >"$root/upgrade.auto.tfvars.json"
  chmod 0600 "$root/upgrade.auto.tfvars.json"
}

remove_worktree() {
  local path="$1"

  if [[ -e "$path" || -L "$path" ]]; then
    git -C "$repo_root" worktree remove --force "$path" >/dev/null 2>&1 || rm -rf "$path"
  fi
}

destroy_terraform_state() {
  local root="$1" data_dir="$2" timeout_seconds destroy_status

  timeout_seconds="$(destroy_timeout_seconds)"
  destroy_status=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" \
      env TF_DATA_DIR="$data_dir" \
      terraform -chdir="$root" destroy -lock-timeout=10m -input=false -auto-approve || destroy_status=$?
  else
    TF_DATA_DIR="$data_dir" terraform -chdir="$root" destroy \
      -lock-timeout=10m -input=false -auto-approve || destroy_status=$?
  fi
  return "$destroy_status"
}

cleanup_resources() {
  local work_root="$1" old_source="$2" new_source="$3" old_data="$4" new_data="$5" state_path="$6" run_id="$7"
  local cleanup_status=0 destroy_status=0 destroy_root="" destroy_data=""

  if [[ -s "$state_path" ]]; then
    if [[ -d "$new_source/tests/smoke/gcp-upgrade" && -d "$new_data" ]]; then
      destroy_root="$new_source/tests/smoke/gcp-upgrade"
      destroy_data="$new_data"
    elif [[ -d "$old_source/tests/smoke/gcp-upgrade" && -d "$old_data" ]]; then
      destroy_root="$old_source/tests/smoke/gcp-upgrade"
      destroy_data="$old_data"
    fi
  fi

  if [[ -n "$destroy_root" ]]; then
    echo "Destroying GCP upgrade resources from preserved Terraform state"
    destroy_terraform_state "$destroy_root" "$destroy_data" || destroy_status=$?
  elif [[ -s "$state_path" ]]; then
    echo "Terraform state remains but neither initialized source tree is available; using provider sweep" >&2
    destroy_status=1
  fi

  target_env gcp-wp
  if ! provider_tag_cleanup gcp-wp "$run_id"; then
    cleanup_status=1
  fi
  if [[ "$destroy_status" -ne 0 && "$cleanup_status" -eq 0 ]]; then
    echo "Provider sweep verified cleanup after Terraform destroy was unavailable or failed"
  fi

  if [[ "$cleanup_status" -eq 0 ]]; then
    remove_worktree "$old_source"
    remove_worktree "$new_source"
    git -C "$repo_root" worktree prune >/dev/null 2>&1 || true
    rm -rf "$work_root"
  else
    echo "Preserving GCP upgrade state under ${work_root} for the same-job cleanup retry" >&2
  fi

  return "$cleanup_status"
}

run_upgrade() (
  # Keep the EXIT trap inside this subshell so Bash retains all function-local
  # cleanup context until the trap has finished. A brace-bodied function loses
  # its locals before a process-level EXIT trap runs.
  set -euo pipefail

  require_cmd base64
  require_cmd curl
  require_cmd gcloud
  require_cmd git
  require_cmd jq
  require_cmd sha256sum
  require_cmd sitectl
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd ssh-keyscan
  require_cmd terraform
  require_env GCLOUD_PROJECT
  require_env GCLOUD_NETWORK_PROJECT_ID
  require_env GCLOUD_NETWORK_NAME
  require_env GCLOUD_SUBNETWORK_NAME
  require_env GCLOUD_POWER_START_ROLE
  require_env GCLOUD_POWER_SUSPEND_ROLE

  local requested_base current_ref current_sha base_sha run_id run_namespace name
  local work_root old_source new_source state_path old_data new_data key_path public_key
  local runner_ipv4 runner_cidr region zone plan_file plan_json nonce
  local old_root new_root old_output new_output old_home new_home
  local old_state_json new_state_json old_ids new_ids old_state_list new_state_list
  local cleanup_started=false

  requested_base="${CLOUD_COMPOSE_UPGRADE_BASE_SHA:-$upgrade_base_sha}"
  [[ "$requested_base" == "$upgrade_base_sha" ]] ||
    fail "CLOUD_COMPOSE_UPGRADE_BASE_SHA must remain pinned to ${upgrade_base_sha}"
  base_sha="$(git -C "$repo_root" rev-parse --verify "${requested_base}^{commit}")"
  [[ "$base_sha" == "$upgrade_base_sha" ]] || fail "the local baseline commit did not resolve exactly"

  current_ref="${CLOUD_COMPOSE_UPGRADE_CURRENT_REF:-HEAD}"
  current_sha="$(git -C "$repo_root" rev-parse --verify "${current_ref}^{commit}")"
  [[ "$current_sha" =~ ^[0-9a-f]{40}$ ]] || fail "current upgrade ref did not resolve to a full commit"

  run_id="$(upgrade_run_id)"
  run_namespace="$(exact_run_namespace "$run_id")"
  name="cc-g-wp-${run_namespace}-up"
  export CLOUD_COMPOSE_SMOKE_RUN_ID="$run_id"

  work_root="${CLOUD_COMPOSE_GCP_UPGRADE_WORKDIR:-${RUNNER_TEMP:-/tmp}/cloud-compose-gcp-upgrade-${run_namespace}}"
  [[ "$work_root" == /* ]] || fail "CLOUD_COMPOSE_GCP_UPGRADE_WORKDIR must be an absolute path"
  old_source="$work_root/source-0.10.2"
  new_source="$work_root/source-current"
  state_path="$work_root/state/terraform.tfstate"
  old_data="$work_root/terraform-data/old"
  new_data="$work_root/terraform-data/new"
  key_path="$work_root/ssh/id_ed25519"
  old_home="$work_root/home-old"
  new_home="$work_root/home-new"
  region="${GCLOUD_REGION:-us-east5}"
  zone="${GCLOUD_ZONE:-${region}-b}"
  valid_custom_role "$GCLOUD_POWER_START_ROLE" ||
    fail "GCLOUD_POWER_START_ROLE must be a full project- or organization-custom-role name"
  valid_custom_role "$GCLOUD_POWER_SUSPEND_ROLE" ||
    fail "GCLOUD_POWER_SUSPEND_ROLE must be a full project- or organization-custom-role name"
  # Validate the externally owned references before the initial orphan sweep;
  # a disposable-prefix typo must never bring the persistent CI network into
  # the sweep's ownership boundary.
  validate_upgrade_network \
    "$GCLOUD_PROJECT" \
    "$region" \
    "$GCLOUD_NETWORK_NAME" \
    "$GCLOUD_SUBNETWORK_NAME"

  # shellcheck disable=SC2317
  cleanup() {
    local status=$? cleanup_result=0

    trap - EXIT INT TERM HUP
    if [[ "$cleanup_started" == "true" ]]; then
      exit "$status"
    fi
    cleanup_started=true
    set +e
    cleanup_resources "$work_root" "$old_source" "$new_source" "$old_data" "$new_data" "$state_path" "$run_id"
    cleanup_result=$?
    set -e
    if [[ "$status" -eq 0 && "$cleanup_result" -ne 0 ]]; then
      exit "$cleanup_result"
    fi
    exit "$status"
  }
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP

  cleanup_resources "$work_root" "$old_source" "$new_source" "$old_data" "$new_data" "$state_path" "$run_id"
  mkdir -p "$work_root/state" "$work_root/terraform-data" "$work_root/ssh"
  chmod 0700 "$work_root" "$work_root/state" "$work_root/terraform-data" "$work_root/ssh"

  ensure_key "$key_path"
  public_key="$(<"${key_path}.pub")"
  runner_ipv4="${CLOUD_COMPOSE_SMOKE_RUNNER_IPV4:-}"
  if [[ -z "$runner_ipv4" ]]; then
    runner_ipv4="$(curl -4fsS --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors \
      --connect-timeout 10 --max-time 60 https://api.ipify.org)"
  fi
  valid_ipv4 "$runner_ipv4" || fail "could not determine a valid public IPv4 address for the runner"
  runner_cidr="${runner_ipv4}/32"

  git -C "$repo_root" worktree add --detach "$old_source" "$base_sha"
  git -C "$repo_root" worktree add --detach "$new_source" "$current_sha"
  [[ -d "$new_source/tests/smoke/gcp-upgrade" ]] || fail "current source does not contain the GCP upgrade fixture"
  cp -a "$new_source/tests/smoke/gcp-upgrade" "$old_source/tests/smoke/gcp-upgrade"

  old_root="$old_source/tests/smoke/gcp-upgrade"
  new_root="$new_source/tests/smoke/gcp-upgrade"
  write_tfvars \
    "$old_root" \
    "$name" \
    "$GCLOUD_PROJECT" \
    "$region" \
    "$zone" \
    "$public_key" \
    "$runner_cidr" \
    "$GCLOUD_NETWORK_PROJECT_ID" \
    "$GCLOUD_NETWORK_NAME" \
    "$GCLOUD_SUBNETWORK_NAME" \
    "$GCLOUD_POWER_START_ROLE" \
    "$GCLOUD_POWER_SUSPEND_ROLE" \
    true
  write_tfvars \
    "$new_root" \
    "$name" \
    "$GCLOUD_PROJECT" \
    "$region" \
    "$zone" \
    "$public_key" \
    "$runner_cidr" \
    "$GCLOUD_NETWORK_PROJECT_ID" \
    "$GCLOUD_NETWORK_NAME" \
    "$GCLOUD_SUBNETWORK_NAME" \
    "$GCLOUD_POWER_START_ROLE" \
    "$GCLOUD_POWER_SUSPEND_ROLE" \
    false

  initialize_phase "$old_root" "$old_data" "$state_path"
  echo "Applying cloud-compose 0.10.2 at ${base_sha}"
  tf_in "$old_root" "$old_data" apply -lock-timeout=10m -input=false -auto-approve
  chmod 0600 "$state_path"

  old_output="$work_root/old-smoke.json"
  old_state_json="$work_root/old-state.json"
  old_ids="$work_root/old-ids.json"
  old_state_list="$work_root/old-state-list.txt"
  phase_output "$old_root" "$old_data" "$old_output"
  run_phase_healthcheck "0.10.2 baseline" "$old_home" "$key_path" "$old_output"
  tf_in "$old_root" "$old_data" show -json >"$old_state_json"
  tf_in "$old_root" "$old_data" state list >"$old_state_list"
  chmod 0600 "$old_state_json" "$old_state_list"
  write_phase_ids old "$old_state_json" "$old_ids"

  nonce="$(printf '%s' "${run_id}:${base_sha}:${current_sha}" | sha256sum | awk '{print $1}')"
  write_disk_sentinels "$old_home" "$key_path" "$old_output" "$nonce"

  initialize_phase "$new_root" "$new_data" "$state_path"
  plan_file="$work_root/upgrade.tfplan"
  plan_json="$work_root/upgrade-plan.json"
  echo "Planning the upgrade to ${current_sha}"
  tf_in "$new_root" "$new_data" plan -lock-timeout=10m -input=false -out="$plan_file"
  tf_in "$new_root" "$new_data" show -json "$plan_file" >"$plan_json"
  chmod 0600 "$plan_file" "$plan_json"
  assert_upgrade_plan "$plan_json"

  echo "Applying the verified upgrade plan"
  tf_in "$new_root" "$new_data" apply -input=false "$plan_file"
  new_output="$work_root/new-smoke.json"
  new_state_json="$work_root/new-state.json"
  new_ids="$work_root/new-ids.json"
  new_state_list="$work_root/new-state-list.txt"
  phase_output "$new_root" "$new_data" "$new_output"
  tf_in "$new_root" "$new_data" show -json >"$new_state_json"
  tf_in "$new_root" "$new_data" state list >"$new_state_list"
  chmod 0600 "$new_state_json" "$new_state_list"
  write_phase_ids new "$new_state_json" "$new_ids"
  assert_state_transition "$old_ids" "$new_ids" "$old_state_list" "$new_state_list"

  run_phase_healthcheck "upgraded current" "$new_home" "$key_path" "$new_output"
  run_direct_vpc_cold_start "$new_home" "$key_path" "$new_output" "$name" "$zone"
  verify_metadata_isolation "$new_home" "$key_path" "$new_output"
  verify_disk_sentinels "$new_home" "$key_path" "$new_output" "$nonce"
  echo "GCP cloud-compose 0.10.2 -> ${current_sha} upgrade smoke test passed"
)

destroy_upgrade() {
  require_cmd git
  require_cmd gcloud
  require_cmd jq
  require_cmd terraform
  require_env GCLOUD_PROJECT
  require_env GCLOUD_NETWORK_PROJECT_ID
  require_env GCLOUD_NETWORK_NAME
  require_env GCLOUD_SUBNETWORK_NAME

  local current_sha run_id run_namespace work_root old_source new_source state_path old_data new_data

  current_sha="$(git -C "$repo_root" rev-parse --verify "${CLOUD_COMPOSE_UPGRADE_CURRENT_REF:-HEAD}^{commit}")"
  run_id="$(upgrade_run_id)"
  run_namespace="$(exact_run_namespace "$run_id")"
  export CLOUD_COMPOSE_SMOKE_RUN_ID="$run_id"
  work_root="${CLOUD_COMPOSE_GCP_UPGRADE_WORKDIR:-${RUNNER_TEMP:-/tmp}/cloud-compose-gcp-upgrade-${run_namespace}}"
  [[ "$work_root" == /* ]] || fail "CLOUD_COMPOSE_GCP_UPGRADE_WORKDIR must be an absolute path"
  old_source="$work_root/source-0.10.2"
  new_source="$work_root/source-current"
  state_path="$work_root/state/terraform.tfstate"
  old_data="$work_root/terraform-data/old"
  new_data="$work_root/terraform-data/new"

  # Keep the externally owned network outside the provider sweep even when
  # this explicit fallback runs after an earlier upgrade failure.
  validate_upgrade_network_ownership \
    "$GCLOUD_PROJECT" \
    "$GCLOUD_NETWORK_PROJECT_ID" \
    "$GCLOUD_NETWORK_NAME" \
    "$GCLOUD_SUBNETWORK_NAME"

  cleanup_resources "$work_root" "$old_source" "$new_source" "$old_data" "$new_data" "$state_path" "$run_id"
}

upgrade_main() {
  case "${1:-}" in
    run)
      [[ "$#" -eq 1 ]] || { usage >&2; return 2; }
      run_upgrade
      ;;
    destroy)
      [[ "$#" -eq 1 ]] || { usage >&2; return 2; }
      destroy_upgrade
      ;;
    check-plan)
      [[ "$#" -eq 2 ]] || { usage >&2; return 2; }
      require_cmd jq
      assert_upgrade_plan "$2"
      ;;
    check-transition)
      [[ "$#" -eq 5 ]] || { usage >&2; return 2; }
      require_cmd jq
      assert_state_transition "$2" "$3" "$4" "$5"
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  upgrade_main "$@"
fi
