#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gcp-upgrade-contract.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "GCP upgrade smoke contract: $*" >&2
  exit 1
}

[[ "$(grep -Fc 'replace_triggered_by = [google_compute_instance.cloud-compose]' "$repo_root/modules/gcp/main.tf")" -eq 2 ]] ||
  fail "instance-scoped power IAM is not recreated when the same-named VM is replaced"
ppb_module="$(sed -n '/^module "ppb" {/,/^}/p' "$repo_root/modules/gcp/main.tf")"
grep -Fq 'depends_on = [google_compute_firewall.allow-cloud-run-ingress]' <<<"$ppb_module" ||
  fail "the power-button module must wait for its ingress firewall"
if grep -Fq 'google_compute_instance_iam_member.gce-start' <<<"$ppb_module"; then
  fail "the power-button module-wide dependency recreates the hosted VM replacement cycle"
fi

script="$repo_root/ci/gcp-upgrade-smoke.sh"
fixture="$repo_root/tests/smoke/gcp-upgrade/main.tf"
variables="$repo_root/tests/smoke/gcp-upgrade/variables.tf"
workflow="$repo_root/.github/workflows/cloud-smoke.yml"
docs="$repo_root/docs/runtime-contracts.md"

for required in "$script" "$fixture" "$variables" "$workflow" "$docs"; do
  [[ -f "$required" ]] || fail "required file is missing: $required"
done

grep -Fq 'f33117cdbbf4a9c7d59006a4db986baef118e6bb' "$script" ||
  fail "upgrade baseline is not pinned to the exact 0.10.2 commit"
[[ "$(grep -Fc 'worktree add --detach' "$script")" -eq 2 ]] ||
  fail "upgrade runner does not create detached baseline and current worktrees"
grep -Fq "[[ \"\$work_root\" == /* ]]" "$script" ||
  fail "upgrade runner does not require an absolute work directory"
grep -Fq "backend-config=\"path=\${state_path}\"" "$script" ||
  fail "upgrade runner does not use one explicit local-backend state path"
grep -Fq 'trap cleanup EXIT' "$script" ||
  fail "upgrade runner does not install an EXIT cleanup trap"
grep -Fq 'run_upgrade() (' "$script" ||
  fail "upgrade runner cleanup can outlive its function-local lifecycle context"
grep -Fq "provider_tag_cleanup gcp-wp \"\$run_id\"" "$script" ||
  fail "upgrade runner does not finish cleanup with the verified provider sweep"
grep -Fq 'target_env gcp-wp' "$script" ||
  fail "upgrade cleanup does not load the concrete GCP WordPress target environment"
grep -Fq 'CLOUD_COMPOSE_SMOKE_RUN_ID must match GITHUB_RUN_ID in GitHub Actions' "$script" ||
  fail "hosted cleanup ownership is not bound to the actual GitHub run id"
grep -Fq 'CLOUD_COMPOSE_SMOKE_RUN_ID must be set explicitly outside GitHub Actions' "$script" ||
  fail "manual upgrade runs can accidentally reuse an implicit cleanup scope"
grep -Fq '"$runner" gcp namespace --run-id "$run_id"' "$script" ||
  fail "upgrade runner does not use the shared exact run-namespace codec"
grep -Fq 'name="cc-g-wp-${run_namespace}-up"' "$script" ||
  fail "upgrade resource names do not use the exact run namespace"
grep -Fq 'cloud-compose-gcp-upgrade-${run_namespace}' "$script" ||
  fail "upgrade working directories do not use the exact run namespace"
if grep -Fq 'sanitize_run_fragment' "$script"; then
  fail "upgrade runner still truncates run IDs to the legacy namespace"
fi
grep -Fq '/mnt/disks/data/.cloud-compose-upgrade-sentinel' "$script" ||
  fail "upgrade runner omits the persistent data-disk sentinel"
grep -Fq '/mnt/disks/volumes/.cloud-compose-upgrade-sentinel' "$script" ||
  fail "upgrade runner omits the Docker-volume disk sentinel"
grep -Fq 'capture_state_resource_attribute "$state_json" "$boot_disk_address" disk_id' "$script" ||
  fail "upgrade runner does not compare the replaced boot disk's immutable numeric identity"
grep -Fq 'capture_state_resource_attribute "$state_json" "$vm_address" instance_id' "$script" ||
  fail "upgrade runner does not compare the replaced VM's immutable numeric identity"
[[ "$(grep -Fc 'sudo tee /mnt/disks/data/.cloud-compose-upgrade-sentinel' "$script")" -eq 1 ]] ||
  fail "upgrade runner must write the data-disk sentinel exactly once"
[[ "$(grep -Fc 'sudo tee /mnt/disks/volumes/.cloud-compose-upgrade-sentinel' "$script")" -eq 1 ]] ||
  fail "upgrade runner must write the Docker-volume sentinel exactly once"

grep -Fq 'backend "local" {}' "$fixture" ||
  fail "upgrade fixture does not declare the shared local backend"
grep -Fq 'create                   = false' "$fixture" ||
  fail "upgrade fixture still owns an ephemeral network"
grep -Fq 'project_id               = var.gcp_network_project_id' "$fixture" ||
  fail "upgrade fixture does not pin the persistent network project"
grep -Fq 'trimspace(var.gcp_network_project_id) == local.project_id' "$fixture" ||
  fail "direct fixture use does not reject Shared VPC unsupported by the baseline"
grep -Fq 'name                     = var.gcp_network_name' "$fixture" ||
  fail "upgrade fixture does not use the persistent CI network"
grep -Fq 'subnetwork               = var.gcp_subnetwork_name' "$fixture" ||
  fail "upgrade fixture does not use the persistent Direct VPC subnet"
grep -Eq 'ssh_ipv4[[:space:]]*=[[:space:]]*\[var\.runner_ipv4_cidr\]' "$fixture" ||
  fail "upgrade fixture does not constrain SSH to the runner CIDR"
grep -Fq 'power_button_allowed_ips = [var.runner_ipv4_cidr]' "$fixture" ||
  fail "upgrade fixture does not constrain PPB wake-up to the runner CIDR"
grep -Fq 'power_button_ip_depth    = 0' "$fixture" ||
  fail "upgrade fixture does not declare the direct Cloud Run proxy depth"
grep -Fq 'ingress_url          = try(module.app.urls[var.gcp_region], "")' "$fixture" ||
  fail "upgrade fixture does not expose the public Cloud Run URL"
grep -Eq 'enabled[[:space:]]*=[[:space:]]*true' "$fixture" ||
  fail "upgrade fixture does not explicitly enable power management"
grep -Fq 'start_role   = var.gcp_power_start_role' "$fixture" ||
  fail "upgrade fixture does not use the foundation start role"
grep -Fq 'suspend_role = var.gcp_power_suspend_role' "$fixture" ||
  fail "upgrade fixture does not use the foundation suspend role"
grep -Fq 'internal_services_enabled     = true' "$fixture" ||
  fail "upgrade fixture does not retain the pre-1.0 internal-service topology"
grep -Fq 'internal_services_auto_update = true' "$fixture" ||
  fail "upgrade fixture does not retain the pre-1.0 automatic-update behavior"
grep -Fq 'primary      = var.legacy_baseline ? "" : "wordpress"' "$fixture" ||
  fail "upgrade fixture does not select the legacy single-project fallback only for the baseline"
grep -Fq 'repo         = "https://github.com/libops/wp.git"' "$fixture" ||
  fail "upgrade fixture omits the baseline-compatible Compose repository input"
grep -Fq 'branch       = var.wordpress_compose_ref' "$fixture" ||
  fail "upgrade fixture does not pin the baseline-compatible Compose branch input"
grep -Fq 'projects = var.legacy_baseline ? {} : {' "$fixture" ||
  fail "upgrade fixture does not transition from the legacy inputs to the current project map"
for unit in internal-services.timer cloud-compose-internal-services.timer; do
  grep -Fq "$unit" "$fixture" || fail "upgrade fixture does not disable ${unit}"
done
grep -Fq 'initcmd = [' "$fixture" ||
  fail "upgrade fixture does not disable internal-service timers before bootstrap"
grep -Fq 'git -c safe.directory=\"$project\" -C \"$project\"' "$fixture" ||
  fail "upgrade fixture does not explicitly trust its preserved pinned repository"
if grep -Fq 'runcmd = [' "$fixture"; then
  fail "upgrade fixture defers its timer shutdown until after bootstrap"
fi
git -C "$repo_root" show f33117cdbbf4a9c7d59006a4db986baef118e6bb:templates/cloud-init.yml \
  >"$tmp/baseline-cloud-init.yml" || fail "could not inspect the pinned baseline cloud-init"
for cloud_init_template in "$repo_root/templates/cloud-init.yml" "$tmp/baseline-cloud-init.yml"; do
  run_script_line="$(grep -nF 'bash /home/cloud-compose/run.sh' "$cloud_init_template" | cut -d: -f1)"
  template_initcmd_line="$(grep -nF 'for CMD in ADDITIONAL_INITCMD' "$cloud_init_template" | cut -d: -f1)"
  [[ -n "$template_initcmd_line" && -n "$run_script_line" && "$template_initcmd_line" -lt "$run_script_line" ]] ||
    fail "baseline or current cloud-init does not execute fixture initcmd before run.sh"
done
grep -Fq 'for unit in internal-services.timer internal-services.service cloud-compose-internal-services.timer cloud-compose-internal-services.service' "$script" ||
  fail "upgrade runner does not assert that both timer generations remain inactive after boot"
grep -Fq 'run_direct_vpc_cold_start "$new_home" "$key_path" "$new_output" "$name" "$zone"' "$script" ||
  fail "upgrade runner does not exercise the upgraded Direct VPC cold-start path"
grep -Fq 'verify_metadata_isolation "$new_home" "$key_path" "$new_output"' "$script" ||
  fail "upgrade runner does not verify metadata isolation after the replacement boot"
grep -Fq 'nslookup metadata.google.internal' "$script" ||
  fail "upgrade runner does not prove that Compute internal DNS survives metadata isolation"
grep -Fq 'sudo -u cloud-compose curl' "$script" ||
  fail "upgrade runner does not prove that unprivileged host metadata access is denied"
grep -Fq -- '--header '\''X-Forwarded-For: 10.0.0.8'\''' "$script" ||
  fail "Direct VPC smoke does not test an attacker-controlled forwarded prefix"
grep -Fq -- '--max-time 600' "$script" ||
  fail "Direct VPC smoke does not cover the bounded Cloud Run request window"
if sed -n '/run_direct_vpc_cold_start()/,/^}/p' "$script" | grep -Eq -- '--retry|while .*curl'; then
  fail "Direct VPC smoke hides first-request failure behind an HTTP retry"
fi
grep -Fq '.networkInterfaces[0].accessConfigs[0].natIP' "$script" ||
  fail "Direct VPC smoke does not refresh an ephemeral GCE SSH address after restart"
grep -Fq 'jq --arg host "$current_host" '\''.host = $host'\'' "$output_json"' "$script" ||
  fail "Direct VPC smoke does not carry the restarted SSH address into host-level checks"
if grep -Eiq 'operator_ssh|jcorall|MacBook|AAAAC3NzaC1lZDI1NTE5AAAAIOuUg' "$fixture" "$variables"; then
  fail "upgrade fixture contains a non-ephemeral operator SSH key"
fi
grep -Fq 'endswith(var.runner_ipv4_cidr, "/32")' "$variables" ||
  fail "upgrade fixture does not require a runner /32"
for variable in gcp_network_project_id gcp_network_name gcp_subnetwork_name gcp_power_start_role gcp_power_suspend_role; do
  grep -Fq "variable \"${variable}\"" "$variables" ||
    fail "upgrade fixture omits required variable ${variable}"
done
grep -Fq 'variable "legacy_baseline"' "$variables" ||
  fail "upgrade fixture cannot distinguish its legacy and current configuration shapes"
grep -Fq 'GCLOUD_NETWORK_PROJECT_ID must equal GCLOUD_PROJECT for the 0.10.2 baseline' "$script" ||
  fail "upgrade runner does not reject a Shared VPC unsupported by the baseline"
grep -Fq '(.mtu | tonumber) == 1460' "$script" ||
  fail "upgrade runner does not attest the Cloud Run Direct VPC network MTU"
grep -Fq 'valid_direct_vpc_cidr "$subnet_cidr"' "$script" ||
  fail "upgrade runner does not enforce Cloud Run Direct VPC supported IPv4 ranges"
grep -Fq '((10#$subnet_prefix <= 26))' "$script" ||
  fail "upgrade runner does not require a /26-or-larger persistent Direct VPC subnet"
bash -c '
  source "$1"
  valid_direct_vpc_cidr "10.60.0.0/26"
  valid_direct_vpc_cidr "172.20.0.0/24"
  valid_direct_vpc_cidr "100.64.0.0/26"
  valid_direct_vpc_cidr "240.0.0.0/26"
' _ "$script" || fail "upgrade runner rejected a supported Direct VPC IPv4 range"
if bash -c 'source "$1"; valid_direct_vpc_cidr "203.0.113.0/24"' _ "$script"; then
  fail "upgrade runner accepted an unsupported Direct VPC IPv4 range"
fi
bash -c 'source "$1"; validate_upgrade_network_ownership "service-project" "service-project" "ci-network" "ci-subnet"' \
  _ "$script" || fail "upgrade runner rejected safe persistent-network ownership"
if bash -c 'source "$1"; validate_upgrade_network_ownership "service-project" "host-project" "ci-network" "ci-subnet"' \
  _ "$script" >/dev/null 2>&1; then
  fail "upgrade runner accepted Shared VPC input unsupported by the baseline"
fi
if bash -c 'source "$1"; validate_upgrade_network_ownership "service-project" "service-project" "cc-g-wp-owned" "ci-subnet"' \
  _ "$script" >/dev/null 2>&1; then
  fail "upgrade runner placed its persistent network inside the disposable sweep boundary"
fi
network_validation_line="$(grep -nF '  validate_upgrade_network \' "$script" | cut -d: -f1)"
initial_sweep_line="$(grep -nF '  cleanup_resources "$work_root"' "$script" | head -n 1 | cut -d: -f1)"
[[ -n "$network_validation_line" && -n "$initial_sweep_line" && "$network_validation_line" -lt "$initial_sweep_line" ]] ||
  fail "upgrade runner does not validate persistent network ownership before its initial orphan sweep"
grep -Fq 'validate_upgrade_network_ownership \' "$script" ||
  fail "upgrade cleanup does not preserve the external network ownership boundary"
wordpress_ref='5058610fddc7267ace92d65a5c49713dce570ac3'
[[ "$(grep -Fc "$wordpress_ref" "$variables")" -eq 2 ]] ||
  fail "upgrade fixture variable does not default to and enforce the pinned WordPress commit"
grep -Fq 'docker_compose_branch = var.wordpress_compose_ref' "$fixture" ||
  fail "upgrade fixture does not use its pinned WordPress commit"
grep -Fq "git_project checkout --detach \${var.wordpress_compose_ref}" "$fixture" ||
  fail "legacy bootstrap does not pre-check out the exact WordPress commit"
grep -Fq 'wordpress_project_dir = "/mnt/disks/data/libops/wp.git/${var.wordpress_compose_ref}"' "$fixture" ||
  fail "upgrade fixture does not derive the exact legacy single-project checkout path"
grep -Fq 'project=${local.wordpress_project_dir};' "$fixture" ||
  fail "upgrade fixture does not pre-check out the shared baseline/current Compose path"
grep -Fq 'project_dir           = local.wordpress_project_dir' "$fixture" ||
  fail "baseline and current phases do not share the pinned Compose checkout path"

tfvars_dir="$tmp/tfvars"
mkdir -p "$tfvars_dir"
bash -c '
  set -euo pipefail
  source "$1"
  write_tfvars "$2" name project us-east5 us-east5-b key 192.0.2.1/32 \
    project network subnet projects/project/roles/startVM projects/project/roles/suspendVM true
' _ "$script" "$tfvars_dir"
jq -e '.legacy_baseline == true' "$tfvars_dir/upgrade.auto.tfvars.json" >/dev/null ||
  fail "upgrade runner does not mark the old phase as a legacy baseline"

cleanup_log="$tmp/cleanup.log"
set +e
GITHUB_ACTIONS='' \
GITHUB_RUN_ID='' \
CLOUD_COMPOSE_SMOKE_RUN_ID=123456789 \
CLOUD_COMPOSE_UPGRADE_CURRENT_REF=HEAD \
GCLOUD_PROJECT=contract-project \
GCLOUD_NETWORK_PROJECT_ID=contract-project \
GCLOUD_NETWORK_NAME=contract-network \
GCLOUD_SUBNETWORK_NAME=contract-subnet \
GCLOUD_POWER_START_ROLE=projects/contract-project/roles/startVM \
GCLOUD_POWER_SUSPEND_ROLE=projects/contract-project/roles/suspendVM \
CLOUD_COMPOSE_GCP_UPGRADE_WORKDIR="$tmp/cleanup-work" \
CLEANUP_LOG="$cleanup_log" \
  bash -c '
    set -euo pipefail
    source "$1"
    repo_root="$2"
    require_cmd() { :; }
    require_env() { :; }
    validate_upgrade_network() { :; }
    cleanup_calls=0
    cleanup_resources() {
      cleanup_calls=$((cleanup_calls + 1))
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$@" >>"$CLEANUP_LOG"
      [[ "$cleanup_calls" -gt 1 ]]
    }
    run_upgrade
  ' _ "$script" "$repo_root"
cleanup_status=$?
set -e
[[ "$cleanup_status" -eq 1 ]] ||
  fail "upgrade runner did not preserve the original preflight cleanup failure"
[[ "$(wc -l <"$cleanup_log")" -eq 2 ]] ||
  fail "upgrade EXIT trap did not retry cleanup with retained lifecycle context"
awk -F '\t' 'NF != 7 { exit 1 } { for (i = 1; i <= NF; i++) if ($i == "") exit 1 }' "$cleanup_log" ||
  fail "upgrade EXIT cleanup lost one or more lifecycle arguments"

grep -Fq 'name: GCP WordPress' "$workflow" ||
  fail "the stable required GCP check name changed"
grep -Fq 'timeout-minutes: 210' "$workflow" ||
  fail "the GCP job does not allow enough time for both upgrade boots"
grep -Fq 'group: cloud-compose-smoke-gcp-wp' "$workflow" ||
  fail "the GCP upgrade does not share the existing concurrency boundary"
grep -Fq "startsWith(github.event.pull_request.title, '[major]')" "$workflow" ||
  fail "the hosted upgrade is not selected by the major-release marker"
grep -Fq "!startsWith(github.event.pull_request.title, '[major]')" "$workflow" ||
  fail "the fresh and upgrade GCP variants are not mutually exclusive"
grep -Fq "CLOUD_COMPOSE_UPGRADE_CURRENT_REF: \${{ github.sha }}" "$workflow" ||
  fail "the upgrade does not target the exact tested merge commit"
grep -Fq 'ci/gcp-upgrade-smoke.sh run' "$workflow" ||
  fail "the GCP job does not invoke the upgrade runner"
grep -Fq 'ci/gcp-upgrade-smoke.sh destroy' "$workflow" ||
  fail "the GCP job lacks same-job upgrade cleanup"
grep -Fq "env.GCLOUD_NETWORK_PROJECT_ID != '' && env.GCLOUD_NETWORK_NAME != '' && env.GCLOUD_SUBNETWORK_NAME != ''" "$workflow" ||
  fail "the hosted upgrade cleanup can run without its persistent-network ownership boundary"
grep -Fq 'make smoke-test PROVIDER=gcp TEMPLATE=wp' "$workflow" ||
  fail "the non-major fresh GCP smoke path was removed"
for variable in GCLOUD_NETWORK_PROJECT_ID GCLOUD_NETWORK_NAME GCLOUD_SUBNETWORK_NAME GCLOUD_POWER_START_ROLE GCLOUD_POWER_SUSPEND_ROLE; do
  grep -Fq "${variable}: \${{ vars.${variable} || secrets.${variable} }}" "$workflow" ||
    fail "the GCP job does not expose required upgrade setting ${variable}"
  grep -Fq "test -n \"\$${variable}\"" "$workflow" ||
    fail "the GCP job does not fail closed when upgrade setting ${variable} is absent"
done
grep -Fq 'test "$GCLOUD_NETWORK_PROJECT_ID" = "$GCLOUD_PROJECT"' "$workflow" ||
  fail "the GCP job does not reject Shared VPC input unsupported by the baseline before authentication"

gcp_job="$(sed -n '/^  gcp-smoke:/,$p' "$workflow")"
grep -Fq 'fetch-depth: 0' <<<"$gcp_job" ||
  fail "the GCP checkout does not fetch the pinned baseline history"
grep -Fq 'persist-credentials: false' <<<"$gcp_job" ||
  fail "the GCP checkout persists credentials into detached worktrees"
grep -Fq 'id-token: write' <<<"$gcp_job" ||
  fail "the GCP job lost its scoped OIDC permission"

grep -Fq 'f33117cdbbf4a9c7d59006a4db986baef118e6bb' "$docs" ||
  fail "upgrade documentation omits the exact hosted baseline"
grep -Fq 'pull-request titles beginning with `[major]`' "$docs" ||
  fail "upgrade documentation does not explain when the expensive gate runs"
grep -Fq "$wordpress_ref" "$docs" ||
  fail "upgrade documentation omits the pinned WordPress Compose revision"

cat >"$tmp/good-plan.json" <<'EOF'
{
  "format_version": "1.2",
  "resource_changes": [
    {
      "address": "module.app.module.gcp.google_service_account.internal-services[0]",
      "previous_address": "module.app.module.gcp.google_service_account.internal-services",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_service_account_iam_member.internal-services-keys[0]",
      "previous_address": "module.app.module.gcp.google_service_account_iam_member.internal-services-keys",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_project_iam_member.stackdriver[0]",
      "previous_address": "module.app.module.gcp.google_project_iam_member.stackdriver",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_project_iam_member.gce-start[0]",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp.google_project_iam_member.gce-suspend",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp.google_service_account_iam_member.gsa-user",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp.google_service_account_iam_member.token-creator",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp.google_service_account_iam_member.vault_agent_jwt_signer_policy[0]",
      "previous_address": "module.app.module.gcp.google_service_account_iam_member.self_jwt_signer_policy",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp.google_service_account_iam_member.app-keys[0]",
      "previous_address": "module.app.module.gcp.google_service_account_iam_member.app-keys",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_instance_iam_member.gce-start[0]",
      "change": {"actions": ["create"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_instance_iam_member.gce-suspend[0]",
      "change": {"actions": ["create"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_disk.data",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_disk.docker-volumes",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_disk.boot",
      "change": {"actions": ["delete", "create"]}
    },
    {
      "address": "module.app.module.gcp.google_compute_instance.cloud-compose",
      "change": {"actions": ["delete", "create"]}
    },
    {
      "address": "module.app.module.gcp.data.google_project_iam_custom_role.gce-suspend",
      "mode": "data",
      "change": {"actions": ["delete"]}
    }
  ]
}
EOF

bash "$script" check-plan "$tmp/good-plan.json"

cat >"$tmp/state-identities.json" <<'EOF'
{
  "values": {
    "root_module": {
      "resources": [
        {
          "address": "module.contract.google_compute_disk.boot",
          "values": {"id": "projects/p/zones/z/disks/same-name", "disk_id": "111"}
        },
        {
          "address": "module.contract.google_compute_instance.vm",
          "values": {"id": "projects/p/zones/z/instances/same-name", "instance_id": "222"}
        }
      ]
    }
  }
}
EOF
[[ "$(bash -c 'source "$1"; state_resource_attribute "$2" "$3" disk_id' _ \
  "$script" "$tmp/state-identities.json" 'module.contract.google_compute_disk.boot')" == "111" ]] ||
  fail "state identity reader did not select google_compute_disk.disk_id"
[[ "$(bash -c 'source "$1"; state_resource_attribute "$2" "$3" instance_id' _ \
  "$script" "$tmp/state-identities.json" 'module.contract.google_compute_instance.vm')" == "222" ]] ||
  fail "state identity reader did not select google_compute_instance.instance_id"
if bash -c 'source "$1"; capture_state_resource_attribute "$2" "$3" disk_id' _ \
  "$script" "$tmp/state-identities.json" 'module.contract.google_compute_instance.vm' >/dev/null 2>&1; then
  fail "state identity capture accepted a missing immutable provider attribute"
fi

jq '(.resource_changes[] | select(.address | endswith("stackdriver[0]")) | .previous_address) = "wrong"' \
  "$tmp/good-plan.json" >"$tmp/bad-move.json"
if bash "$script" check-plan "$tmp/bad-move.json" >/dev/null 2>&1; then
  fail "plan checker accepted a missing moved-resource provenance"
fi

jq '(.resource_changes[] | select(.address | endswith("docker-volumes")) | .change.actions) = ["delete", "create"]' \
  "$tmp/good-plan.json" >"$tmp/bad-disk.json"
if bash "$script" check-plan "$tmp/bad-disk.json" >/dev/null 2>&1; then
  fail "plan checker accepted persistent-disk replacement"
fi

jq '.resource_changes += [{"address":"module.app.google_compute_disk.unexpected","change":{"actions":["delete"]}}]' \
  "$tmp/good-plan.json" >"$tmp/bad-delete.json"
if bash "$script" check-plan "$tmp/bad-delete.json" >/dev/null 2>&1; then
  fail "plan checker accepted an unexpected destructive action"
fi

jq '(.resource_changes[] | select(.address | endswith("google_project_iam_member.gce-start[0]")) | .change.actions) = ["no-op"]' \
  "$tmp/good-plan.json" >"$tmp/bad-legacy-iam.json"
if bash "$script" check-plan "$tmp/bad-legacy-iam.json" >/dev/null 2>&1; then
  fail "plan checker accepted a retained legacy project-wide power binding"
fi

jq '(.resource_changes[] | select(.address | endswith("google_service_account_iam_member.gsa-user")) | .change.actions) = ["no-op"]' \
  "$tmp/good-plan.json" >"$tmp/bad-legacy-gsa-user.json"
if bash "$script" check-plan "$tmp/bad-legacy-gsa-user.json" >/dev/null 2>&1; then
  fail "plan checker accepted the legacy default Compute service-account impersonation grant"
fi

jq '(.resource_changes[] | select(.address | endswith("google_service_account_iam_member.token-creator")) | .change.actions) = ["no-op"]' \
  "$tmp/good-plan.json" >"$tmp/bad-legacy-vm-token-creator.json"
if bash "$script" check-plan "$tmp/bad-legacy-vm-token-creator.json" >/dev/null 2>&1; then
  fail "plan checker accepted the unused VM self token-creator grant"
fi

jq 'del(.resource_changes[] | select(.address | endswith("google_service_account_iam_member.vault_agent_jwt_signer_policy[0]")) | .previous_address)' \
  "$tmp/good-plan.json" >"$tmp/bad-app-token-move.json"
if bash "$script" check-plan "$tmp/bad-app-token-move.json" >/dev/null 2>&1; then
  fail "plan checker accepted a missing app token-creator moved-resource provenance"
fi

jq 'del(.resource_changes[] | select(.address | endswith("google_compute_instance_iam_member.gce-suspend[0]")))' \
  "$tmp/good-plan.json" >"$tmp/bad-scoped-iam.json"
if bash "$script" check-plan "$tmp/bad-scoped-iam.json" >/dev/null 2>&1; then
  fail "plan checker accepted a missing instance-scoped power binding"
fi

cat >"$tmp/old-ids.json" <<'EOF'
{
  "data_disk": "data-1",
  "docker_disk": "docker-1",
  "boot_disk": "boot-old",
  "vm": "vm-old",
  "internal_service_account": "sa-1",
  "internal_service_keys": "keys-1",
  "stackdriver": "metrics-1",
  "app_key_admin": "app-keys-1",
  "legacy_start": "legacy-start-1",
  "legacy_suspend": "legacy-suspend-1"
}
EOF
cat >"$tmp/new-ids.json" <<'EOF'
{
  "data_disk": "data-1",
  "docker_disk": "docker-1",
  "boot_disk": "boot-new",
  "vm": "vm-new",
  "internal_service_account": "sa-1",
  "internal_service_keys": "keys-1",
  "stackdriver": "metrics-1",
  "app_key_admin": "app-keys-1",
  "scoped_start": "scoped-start-1",
  "scoped_suspend": "scoped-suspend-1"
}
EOF
cat >"$tmp/old-state.txt" <<'EOF'
module.app.module.gcp.google_service_account.internal-services
module.app.module.gcp.google_service_account_iam_member.internal-services-keys
module.app.module.gcp.google_project_iam_member.stackdriver
module.app.module.gcp.google_project_iam_member.gce-start[0]
module.app.module.gcp.google_project_iam_member.gce-suspend
module.app.module.gcp.google_service_account_iam_member.gsa-user
module.app.module.gcp.google_service_account_iam_member.token-creator
module.app.module.gcp.google_service_account_iam_member.self_jwt_signer_policy
module.app.module.gcp.google_service_account_iam_member.app-keys
EOF
cat >"$tmp/new-state.txt" <<'EOF'
module.app.module.gcp.google_service_account.internal-services[0]
module.app.module.gcp.google_service_account_iam_member.internal-services-keys[0]
module.app.module.gcp.google_project_iam_member.stackdriver[0]
module.app.module.gcp.google_compute_instance_iam_member.gce-start[0]
module.app.module.gcp.google_compute_instance_iam_member.gce-suspend[0]
module.app.module.gcp.google_service_account_iam_member.app-keys[0]
EOF

bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/new-state.txt"

jq '.docker_disk = "docker-replaced"' "$tmp/new-ids.json" >"$tmp/bad-new-ids.json"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/bad-new-ids.json" "$tmp/old-state.txt" "$tmp/new-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a changed persistent disk id"
fi

cp "$tmp/new-state.txt" "$tmp/bad-new-state.txt"
printf '%s\n' 'module.app.module.gcp.google_service_account.internal-services' >>"$tmp/bad-new-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-new-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a retained legacy resource address"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-power-state.txt"
printf '%s\n' 'module.app.module.gcp.google_project_iam_member.gce-start[0]' >>"$tmp/bad-legacy-power-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-power-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a retained legacy project-wide power binding"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-gsa-state.txt"
printf '%s\n' 'module.app.module.gcp.google_service_account_iam_member.gsa-user' >>"$tmp/bad-legacy-gsa-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-gsa-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted the legacy default Compute service-account impersonation grant"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-token-state.txt"
printf '%s\n' 'module.app.module.gcp.google_service_account_iam_member.token-creator' >>"$tmp/bad-legacy-token-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-token-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted the unused VM self token-creator grant"
fi

grep -Fvx 'module.app.module.gcp.google_compute_instance_iam_member.gce-suspend[0]' \
  "$tmp/new-state.txt" >"$tmp/bad-missing-scoped-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-missing-scoped-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a missing instance-scoped power binding"
fi

echo "GCP upgrade smoke contracts passed"
