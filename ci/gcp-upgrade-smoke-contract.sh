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
shared_smoke="$repo_root/ci/cloud-smoke.sh"
fixture="$repo_root/tests/smoke/gcp-upgrade/main.tf"
variables="$repo_root/tests/smoke/gcp-upgrade/variables.tf"
fixture_prepare="$repo_root/tests/smoke/gcp-upgrade/rootfs/home/cloud-compose/gcp-upgrade-prepare-repository.sh"
fixture_up="$repo_root/tests/smoke/gcp-upgrade/rootfs/etc/cloud-compose/lifecycle.d/gcp-upgrade-up.sh"
context_fixture="$repo_root/tests/smoke/modules/context/main.tf"
remote_services="$repo_root/ci/remote/gcp-upgrade-assert-services-disabled.sh"
remote_metadata="$repo_root/ci/remote/gcp-upgrade-verify-metadata-isolation.sh"
remote_container_metadata="$repo_root/ci/remote/gcp-upgrade-container-metadata-isolation.sh"
remote_sentinels="$repo_root/ci/remote/gcp-upgrade-write-disk-sentinels.sh"
remote_filesystem_size="$repo_root/ci/remote/gcp-upgrade-read-filesystem-size.sh"
workflow="$repo_root/.github/workflows/cloud-smoke.yml"
docs="$repo_root/docs/runtime-contracts.md"
contract_harness="$repo_root/ci/fixtures/gcp-upgrade-smoke-contract-harness.sh"

for required in \
  "$script" \
  "$shared_smoke" \
  "$fixture" \
  "$variables" \
  "$fixture_prepare" \
  "$fixture_up" \
  "$context_fixture" \
  "$remote_services" \
  "$remote_metadata" \
  "$remote_container_metadata" \
  "$remote_sentinels" \
  "$remote_filesystem_size" \
  "$contract_harness" \
  "$workflow" \
  "$docs"; do
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
grep -Fq 'readonly diagnostics_program="/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"' "$shared_smoke" ||
  fail "shared smoke diagnostics do not use the checked-in privileged program"
for diagnostics_command in state status dump; do
  grep -Fq "sudo -n \${diagnostics_program} ${diagnostics_command}" "$shared_smoke" ||
    fail "shared smoke diagnostics do not invoke the ${diagnostics_command} command non-interactively"
done
grep -Fq 'test -f /home/cloud-compose/.cloud-compose-bootstrap-complete' "$shared_smoke" ||
  fail "shared smoke readiness lost its pinned-baseline marker compatibility probe"
grep -Fq 'systemctl is-active --quiet cloud-compose.service' "$shared_smoke" ||
  fail "shared smoke readiness lost its pre-bootstrap-unit compatibility signal"
grep -Fq 'cloud-init completed without the Cloud Compose readiness marker' "$shared_smoke" ||
  fail "current smoke readiness can still accept cloud-init completion without durable application readiness"
grep -Fq 'The pinned upgrade fixture predates the durable readiness marker.' "$shared_smoke" ||
  fail "legacy cloud-init completion is not explicitly confined to the pinned upgrade fixture"
grep -Fq 'test ! -L /home/cloud-compose/run.log' "$shared_smoke" ||
  fail "shared smoke diagnostics do not retain a guarded legacy bootstrap log fallback"
grep -Fq 'sudo -n /usr/bin/systemctl status cloud-compose.service' "$shared_smoke" ||
  fail "shared smoke diagnostics do not limit pinned-baseline sudo to its existing exact command"
grep -Fq 'readonly smoke_healthcheck_program="/home/cloud-compose/smoke-healthcheck.sh"' "$shared_smoke" ||
  fail "shared smoke healthcheck does not use the checked-in host wrapper"
grep -Fq '"${smoke_healthcheck_program} ${quoted_context}"' "$shared_smoke" ||
  fail "shared smoke healthcheck does not invoke the checked-in host wrapper directly"
grep -Fq 'env HOME=/home/cloud-compose DOCKER_CONFIG=/mnt/disks/data/docker-config PATH=/home/cloud-compose/bin:' "$shared_smoke" ||
  fail "shared smoke healthcheck lost its direct pinned-baseline fallback"
if sed -n '/^run_healthcheck()/,/^}/p' "$shared_smoke" | grep -Fq 'bash -lc'; then
  fail "shared smoke healthcheck still sends an embedded Bash program over SSH"
fi
grep -Fq 'CLOUD_COMPOSE_SMOKE_RUN_ID must match GITHUB_RUN_ID in GitHub Actions' "$script" ||
  fail "hosted cleanup ownership is not bound to the actual GitHub run id"
grep -Fq 'CLOUD_COMPOSE_SMOKE_RUN_ID must be set explicitly outside GitHub Actions' "$script" ||
  fail "manual upgrade runs can accidentally reuse an implicit cleanup scope"
grep -Fq '"$runner" gcp namespace --run-id "$run_id"' "$script" ||
  fail "upgrade runner does not use the shared exact run-namespace codec"
grep -Fq '"$runner" gcp upgrade check-plan --plan "$plan_json"' "$script" ||
  fail "upgrade runner does not delegate Terraform plan policy to the compiled CI runner"
grep -Fq '"$runner" gcp upgrade check-transition \' "$script" ||
  fail "upgrade runner does not delegate state-transition policy to the compiled CI runner"
grep -Fq '"$runner" gcp upgrade capture-ids --phase "$phase" --state "$state_json"' "$script" ||
  fail "upgrade runner does not delegate immutable state identity capture to the compiled CI runner"
if sed -n '/assert_upgrade_plan()/,/^}/p; /assert_state_transition()/,/^}/p; /write_phase_ids()/,/^}/p' "$script" | grep -Fq 'jq '; then
  fail "upgrade plan, identity capture, or state-transition policy remains implemented in jq"
fi
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
grep -Fq 'gcp-upgrade-write-disk-sentinels.sh' "$script" ||
  fail "upgrade runner does not stage the checked disk-sentinel program"
[[ "$(grep -Fc '>/mnt/disks/data/.cloud-compose-upgrade-sentinel' "$remote_sentinels")" -eq 1 ]] ||
  fail "checked remote program must write the data-disk sentinel exactly once"
[[ "$(grep -Fc '>/mnt/disks/volumes/.cloud-compose-upgrade-sentinel' "$remote_sentinels")" -eq 1 ]] ||
  fail "checked remote program must write the Docker-volume sentinel exactly once"
grep -Fq '[[ "$#" -ne 1 || ! "$1" =~ ^[A-Za-z0-9._:-]{1,128}$ ]]' "$remote_sentinels" ||
  fail "checked disk-sentinel program does not validate its nonce argument"
grep -Fq 'read_data_filesystem_size_bytes()' "$script" ||
  fail "upgrade runner does not measure mounted application-data filesystem capacity"
grep -Fq 'filesystem="$(findmnt -n -o FSTYPE --target /mnt/disks/data)"' "$remote_filesystem_size" ||
  fail "checked filesystem-size program does not require the application-data mount to remain ext4"
grep -Fq 'df --block-size=1 --output=size -- /mnt/disks/data' "$remote_filesystem_size" ||
  fail "checked filesystem-size program does not measure mounted ext4 capacity in bytes"
grep -Fq '((10#$upgraded_data_filesystem_bytes > 10#$baseline_data_filesystem_bytes))' "$script" ||
  fail "upgrade runner does not prove mounted ext4 grew beyond its baseline capacity"

grep -Fq 'backend "local" {}' "$fixture" ||
  fail "upgrade fixture does not declare the shared local backend"
grep -Fq 'source = "../../.."' "$fixture" ||
  fail "upgrade fixture does not exercise the GCP-only compatibility root"
grep -Fq 'application_data_size_gb = var.legacy_baseline ? 20 : 30' "$fixture" ||
  fail "upgrade fixture does not request exact 20-to-30-GB application-data growth"
grep -Fq 'data_size_gb           = local.application_data_size_gb' "$fixture" ||
  fail "upgrade fixture does not pass its phase-specific application-data size"
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
  grep -Fq "$unit" "$fixture_prepare" || fail "upgrade fixture program does not disable ${unit}"
done
grep -Fq 'initcmd = [' "$fixture" ||
  fail "upgrade fixture does not disable internal-service timers before bootstrap"
grep -Fq 'rootfs = "${path.module}/rootfs"' "$fixture" ||
  fail "upgrade fixture does not package its checked initialization program"
grep -Fq 'bash /home/cloud-compose/gcp-upgrade-prepare-repository.sh' "$fixture" ||
  fail "upgrade fixture does not invoke its checked initialization program"
grep -Fq '"/etc/cloud-compose/lifecycle.d/gcp-upgrade-up.sh"' "$fixture" ||
  fail "upgrade fixture does not invoke its checked lifecycle program"
grep -Fq '"/home/cloud-compose/default-lifecycle.sh up"' "$context_fixture" ||
  fail "hosted smoke context does not invoke the checked default lifecycle program"
grep -Fq 'sitectl compose --context "$context" up -d --remove-orphans' "$fixture_up" ||
  fail "checked upgrade lifecycle program does not bring up the exact sitectl context"
grep -Fq 'sitectl healthcheck --context "$context" --persist' "$fixture_up" ||
  fail "checked upgrade lifecycle program does not persist the post-start healthcheck"
[[ -x "$fixture_up" ]] ||
  fail "checked upgrade lifecycle program is not executable"
if grep -Eq '"sitectl (compose|healthcheck)' "$fixture" "$context_fixture"; then
  fail "smoke fixtures still embed raw sitectl lifecycle commands in Terraform"
fi
grep -Fq 'git -c safe.directory="$project" -C "$project"' "$fixture_prepare" ||
  fail "upgrade fixture does not explicitly trust its preserved pinned repository"
if grep -Fq 'runcmd = [' "$fixture"; then
  fail "upgrade fixture defers its timer shutdown until after bootstrap"
fi
git -C "$repo_root" show f33117cdbbf4a9c7d59006a4db986baef118e6bb:templates/cloud-init.yml \
  >"$tmp/baseline-cloud-init.yml" || fail "could not inspect the pinned baseline cloud-init"
baseline_run_line="$(grep -nF 'bash /home/cloud-compose/run.sh' "$tmp/baseline-cloud-init.yml" | cut -d: -f1 || true)"
baseline_initcmd_line="$(grep -nF 'for CMD in ADDITIONAL_INITCMD' "$tmp/baseline-cloud-init.yml" | cut -d: -f1 || true)"
[[ -n "$baseline_initcmd_line" && -n "$baseline_run_line" && "$baseline_initcmd_line" -lt "$baseline_run_line" ]] ||
  fail "baseline cloud-init does not execute fixture initcmd before run.sh"

current_bootstrap_line="$(
  grep -nF 'bash /etc/cloud-compose/libexec/start-cloud-compose-bootstrap.sh' \
    "$repo_root/rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh" |
    cut -d: -f1 || true
)"
current_initcmd_line="$(
  grep -nF 'source "$init_commands_file"' \
    "$repo_root/rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh" |
    cut -d: -f1 || true
)"
[[ -n "$current_initcmd_line" && -n "$current_bootstrap_line" && "$current_initcmd_line" -lt "$current_bootstrap_line" ]] ||
  fail "current checked-in cloud-init program does not execute fixture initcmd before retryable bootstrap"
for unit in internal-services.timer internal-services.service cloud-compose-internal-services.timer cloud-compose-internal-services.service; do
  grep -Fq "$unit" "$remote_services" ||
    fail "checked service assertion does not cover ${unit}"
done
grep -Fq 'gcp-upgrade-assert-services-disabled.sh' "$script" ||
  fail "upgrade runner does not invoke the checked service assertion after boot"
grep -Fq 'run_direct_vpc_cold_start "$new_home" "$key_path" "$new_output" "$name" "$zone"' "$script" ||
  fail "upgrade runner does not exercise the upgraded Direct VPC cold-start path"
grep -Fq 'verify_metadata_isolation "$new_home" "$key_path" "$new_output"' "$script" ||
  fail "upgrade runner does not verify metadata isolation after the replacement boot"
grep -Fq 'nslookup metadata.google.internal' "$remote_container_metadata" ||
  fail "upgrade runner does not prove that Compute internal DNS survives metadata isolation"
grep -Fq 'for metadata_scheme in http https; do' "$remote_metadata" ||
  fail "upgrade runner does not prove that unprivileged host metadata access is denied"
grep -Fq 'type=bind,src=${container_program},dst=/usr/local/bin/cloud-compose-metadata-isolation,readonly' "$remote_metadata" ||
  fail "metadata-isolation smoke does not mount its checked container program read-only"
grep -Fq '/bin/sh /usr/local/bin/cloud-compose-metadata-isolation' "$remote_metadata" ||
  fail "metadata-isolation smoke does not invoke its checked container program directly"
if grep -Eq 'base64[^[:space:]]*[[:space:]]*\|[[:space:]]*(sudo[[:space:]]+)?bash|ssh_cmd.*bash[[:space:]]+-(c|lc)' "$script"; then
  fail "upgrade runner still sends an embedded Bash program to the remote host"
fi
grep -Fq 'remote_dir=/home/cloud-compose/.cache/libops-ci' "$script" ||
  fail "upgrade runner does not stage checked remote programs at a stable path"
grep -Fq 'install -m 0700 /dev/stdin $remote_path' "$script" ||
  fail "upgrade runner does not install checked remote programs with a private executable mode"
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
"$contract_harness" supported-cidrs "$script" ||
  fail "upgrade runner rejected a supported Direct VPC IPv4 range"
if "$contract_harness" cidr "$script" "203.0.113.0/24"; then
  fail "upgrade runner accepted an unsupported Direct VPC IPv4 range"
fi
"$contract_harness" network-ownership "$script" \
  service-project service-project ci-network ci-subnet ||
  fail "upgrade runner rejected safe persistent-network ownership"
if "$contract_harness" network-ownership "$script" \
  service-project host-project ci-network ci-subnet >/dev/null 2>&1; then
  fail "upgrade runner accepted Shared VPC input unsupported by the baseline"
fi
if "$contract_harness" network-ownership "$script" \
  service-project service-project cc-g-wp-owned ci-subnet >/dev/null 2>&1; then
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
grep -Fq 'git_project checkout --detach "$revision"' "$fixture_prepare" ||
  fail "legacy bootstrap does not pre-check out the exact WordPress commit"
grep -Eq 'wordpress_project_dir[[:space:]]*=[[:space:]]*"/mnt/disks/data/libops/wp.git/\$\{var\.wordpress_compose_ref\}"' "$fixture" ||
  fail "upgrade fixture does not derive the exact legacy single-project checkout path"
grep -Fq '[[ "$project" == "/mnt/disks/data/libops/wp.git/${revision}" ]]' "$fixture_prepare" ||
  fail "upgrade fixture program does not constrain the shared baseline/current Compose path"
grep -Fq 'project_dir           = local.wordpress_project_dir' "$fixture" ||
  fail "baseline and current phases do not share the pinned Compose checkout path"

tfvars_dir="$tmp/tfvars"
mkdir -p "$tfvars_dir"
"$contract_harness" write-tfvars "$script" "$tfvars_dir"
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
  "$contract_harness" cleanup-failure "$script" "$repo_root"
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
grep -Fq 'controlled reboot after the apply' "$docs" ||
  fail "GCP disk-growth documentation does not explain when ext4 capacity activates"
grep -Fq 'update-only application-data growth from 20 to 30 GB' "$docs" ||
  fail "upgrade documentation omits the exact in-place data-disk growth contract"

cat >"$tmp/good-plan.json" <<'EOF'
{
  "format_version": "1.2",
  "resource_changes": [
    {
      "address": "module.app.module.gcp[0].google_service_account.internal-services[0]",
      "previous_address": "module.app.module.gcp[0].google_service_account.internal-services",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp[0].google_service_account_iam_member.internal-services-keys[0]",
      "previous_address": "module.app.module.gcp[0].google_service_account_iam_member.internal-services-keys",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp[0].google_project_iam_member.stackdriver[0]",
      "previous_address": "module.app.module.gcp[0].google_project_iam_member.stackdriver",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp[0].google_project_iam_member.gce-start[0]",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp[0].google_project_iam_member.gce-suspend",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp[0].google_service_account_iam_member.gsa-user",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp[0].google_service_account_iam_member.token-creator",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp[0].google_service_account_iam_member.vault_agent_jwt_signer_policy[0]",
      "previous_address": "module.app.module.gcp[0].google_service_account_iam_member.self_jwt_signer_policy",
      "change": {"actions": ["delete"]}
    },
    {
      "address": "module.app.module.gcp[0].google_service_account_iam_member.app-keys[0]",
      "previous_address": "module.app.module.gcp[0].google_service_account_iam_member.app-keys",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp[0].google_compute_instance_iam_member.gce-start[0]",
      "change": {"actions": ["create"]}
    },
    {
      "address": "module.app.module.gcp[0].google_compute_instance_iam_member.gce-suspend[0]",
      "change": {"actions": ["create"]}
    },
    {
      "address": "module.app.module.gcp[0].google_compute_disk.data",
      "change": {
        "actions": ["update"],
        "before": {"size": 20},
        "after": {"size": 30}
      }
    },
    {
      "address": "module.app.module.gcp[0].google_compute_disk.docker-volumes",
      "change": {"actions": ["no-op"]}
    },
    {
      "address": "module.app.module.gcp[0].google_compute_disk.boot",
      "change": {"actions": ["delete", "create"]}
    },
    {
      "address": "module.app.module.gcp[0].google_compute_instance.cloud-compose",
      "change": {"actions": ["delete", "create"]}
    },
    {
      "address": "module.app.module.gcp[0].data.google_project_iam_custom_role.gce-suspend",
      "mode": "data",
      "change": {"actions": ["delete"]}
    }
  ]
}
EOF

bash "$script" check-plan "$tmp/good-plan.json"

jq '(.resource_changes[] | select(.address | endswith("stackdriver[0]")) | .previous_address) = "wrong"' \
  "$tmp/good-plan.json" >"$tmp/bad-move.json"
if bash "$script" check-plan "$tmp/bad-move.json" >/dev/null 2>&1; then
  fail "plan checker accepted a missing moved-resource provenance"
fi

jq '(.resource_changes[] | select(.address | endswith("google_compute_disk.data")) | .change.actions) = ["delete", "create"]' \
  "$tmp/good-plan.json" >"$tmp/bad-data-disk.json"
if bash "$script" check-plan "$tmp/bad-data-disk.json" >/dev/null 2>&1; then
  fail "plan checker accepted application-data disk replacement"
fi

jq '(.resource_changes[] | select(.address | endswith("google_compute_disk.data")) | .change.after.size) = 29' \
  "$tmp/good-plan.json" >"$tmp/bad-data-growth.json"
if bash "$script" check-plan "$tmp/bad-data-growth.json" >/dev/null 2>&1; then
  fail "plan checker accepted the wrong application-data growth target"
fi

jq '(.resource_changes[] | select(.address | endswith("docker-volumes")) | .change.actions) = ["delete", "create"]' \
  "$tmp/good-plan.json" >"$tmp/bad-docker-disk.json"
if bash "$script" check-plan "$tmp/bad-docker-disk.json" >/dev/null 2>&1; then
  fail "plan checker accepted Docker-volume disk replacement"
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
module.app.module.gcp[0].google_service_account.internal-services
module.app.module.gcp[0].google_service_account_iam_member.internal-services-keys
module.app.module.gcp[0].google_project_iam_member.stackdriver
module.app.module.gcp[0].google_project_iam_member.gce-start[0]
module.app.module.gcp[0].google_project_iam_member.gce-suspend
module.app.module.gcp[0].google_service_account_iam_member.gsa-user
module.app.module.gcp[0].google_service_account_iam_member.token-creator
module.app.module.gcp[0].google_service_account_iam_member.self_jwt_signer_policy
module.app.module.gcp[0].google_service_account_iam_member.app-keys
EOF
cat >"$tmp/new-state.txt" <<'EOF'
module.app.module.gcp[0].google_service_account.internal-services[0]
module.app.module.gcp[0].google_service_account_iam_member.internal-services-keys[0]
module.app.module.gcp[0].google_project_iam_member.stackdriver[0]
module.app.module.gcp[0].google_compute_instance_iam_member.gce-start[0]
module.app.module.gcp[0].google_compute_instance_iam_member.gce-suspend[0]
module.app.module.gcp[0].google_service_account_iam_member.app-keys[0]
EOF

bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/new-state.txt"

jq '.docker_disk = "docker-replaced"' "$tmp/new-ids.json" >"$tmp/bad-new-ids.json"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/bad-new-ids.json" "$tmp/old-state.txt" "$tmp/new-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a changed Docker-volume disk id"
fi

jq '.data_disk = "data-replaced"' "$tmp/new-ids.json" >"$tmp/bad-data-ids.json"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/bad-data-ids.json" "$tmp/old-state.txt" "$tmp/new-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a changed application-data disk id"
fi

cp "$tmp/new-state.txt" "$tmp/bad-new-state.txt"
printf '%s\n' 'module.app.module.gcp[0].google_service_account.internal-services' >>"$tmp/bad-new-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-new-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a retained legacy resource address"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-power-state.txt"
printf '%s\n' 'module.app.module.gcp[0].google_project_iam_member.gce-start[0]' >>"$tmp/bad-legacy-power-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-power-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a retained legacy project-wide power binding"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-gsa-state.txt"
printf '%s\n' 'module.app.module.gcp[0].google_service_account_iam_member.gsa-user' >>"$tmp/bad-legacy-gsa-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-gsa-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted the legacy default Compute service-account impersonation grant"
fi

cp "$tmp/new-state.txt" "$tmp/bad-legacy-token-state.txt"
printf '%s\n' 'module.app.module.gcp[0].google_service_account_iam_member.token-creator' >>"$tmp/bad-legacy-token-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-legacy-token-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted the unused VM self token-creator grant"
fi

grep -Fvx 'module.app.module.gcp[0].google_compute_instance_iam_member.gce-suspend[0]' \
  "$tmp/new-state.txt" >"$tmp/bad-missing-scoped-state.txt"
if bash "$script" check-transition \
  "$tmp/old-ids.json" "$tmp/new-ids.json" "$tmp/old-state.txt" "$tmp/bad-missing-scoped-state.txt" >/dev/null 2>&1; then
  fail "state checker accepted a missing instance-scoped power binding"
fi

echo "GCP upgrade smoke contracts passed"
