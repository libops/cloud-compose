#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-cleanup.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "cloud smoke cleanup contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/state"

cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_GCLOUD_LOG"
EOF

cat >"$tmp/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'gcloud' >>"$FAKE_GCLOUD_LOG"
printf ' %q' "$@" >>"$FAKE_GCLOUD_LOG"
printf '\n' >>"$FAKE_GCLOUD_LOG"

state_count() {
  local key="$1"

  if [[ -f "$FAKE_GCLOUD_STATE/$key" ]]; then
    cat "$FAKE_GCLOUD_STATE/$key"
  else
    printf '0\n'
  fi
}

mutation_done() {
  [[ -f "$FAKE_GCLOUD_STATE/$1.done" ]]
}

emit_project_binding() {
  local state_key="$1" role="$2" member="$3" separator_name="$4"
  local -n separator_ref="$separator_name"

  if mutation_done "$state_key"; then
    return 0
  fi
  printf '%s{"role":"%s","members":["%s"]}' "$separator_ref" "$role" "$member"
  separator_ref=,
}

command_name=""
case "${1:-} ${2:-} ${3:-} ${4:-}" in
  "run services list "*)
    if [[ "${FAKE_GCLOUD_MODE:-success}" == "residual-cloud-run" ]] || ! mutation_done run-services-delete; then
      printf 'cc-g-wp-12345678-abcd\n'
    fi
    exit 0
    ;;
  "run services get-iam-policy "*)
    if mutation_done run-invoker-remove; then
      printf '{"bindings":[]}\n'
    else
      printf '{"bindings":[{"role":"roles/run.invoker","members":["allUsers"]}]}\n'
    fi
    exit 0
    ;;
  "compute instances list "*)
    if ! mutation_done instances-delete; then
      if [[ " $* " == *" --format=json "* ]]; then
        printf '[{"zone":"https://www.googleapis.com/compute/v1/projects/test-project/zones/us-east5-b","name":"cc-g-wp-12345678-abcd"}]\n'
      else
        printf 'cc-g-wp-12345678-abcd\n'
      fi
    fi
    exit 0
    ;;
  "compute firewall-rules list "*)
    if ! mutation_done firewalls-delete; then
      printf 'allow-ssh-ipv4-cc-g-wp-12345678-abcd\n'
    fi
    exit 0
    ;;
  "compute disks list "*)
    if ! mutation_done disks-delete; then
      if [[ " $* " == *" --format=json "* ]]; then
        printf '[{"zone":"https://www.googleapis.com/compute/v1/projects/test-project/zones/us-east5-b","name":"cc-g-wp-12345678-abcd-data-disk"}]\n'
      else
        printf 'cc-g-wp-12345678-abcd-data-disk\n'
      fi
    fi
    exit 0
    ;;
  "iam service-accounts list "*)
    if ! mutation_done service-accounts-delete; then
      printf '%s\n' \
        'vm-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com' \
        'internal-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com' \
        'ppb-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com' \
        'cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com'
    fi
    exit 0
    ;;
  "compute networks subnets list")
    if ! mutation_done subnets-delete; then
      if [[ " $* " == *" --format=json "* ]]; then
        printf '[{"region":"https://www.googleapis.com/compute/v1/projects/test-project/regions/us-east5","name":"cc-g-wp-12345678-abcd"}]\n'
      else
        printf 'cc-g-wp-12345678-abcd\n'
      fi
    fi
    exit 0
    ;;
  "compute networks list "*)
    if ! mutation_done networks-delete; then
      printf 'cc-g-wp-12345678-abcd\n'
    fi
    exit 0
    ;;
  "projects get-iam-policy test-project "*)
    separator=""
    printf '{"bindings":['
    emit_project_binding iam-log-remove roles/logging.logWriter \
      serviceAccount:vm-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com separator
    emit_project_binding iam-monitoring-remove roles/monitoring.metricWriter \
      serviceAccount:internal-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com separator
    emit_project_binding iam-suspend-remove projects/test-project/roles/suspendVM \
      serviceAccount:internal-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com separator
    emit_project_binding iam-start-remove projects/test-project/roles/startVM \
      serviceAccount:ppb-cc-g-wp-12345678-abcd@test-project.iam.gserviceaccount.com separator
    printf ']}\n'
    exit 0
    ;;
  "run services remove-iam-policy-binding "*)
    command_name="run-invoker-remove"
    ;;
  "run services delete "*)
    command_name="run-services-delete"
    ;;
  "projects remove-iam-policy-binding "*)
    case " $* " in
      *" --role roles/logging.logWriter "*) command_name="iam-log-remove" ;;
      *" --role roles/monitoring.metricWriter "*) command_name="iam-monitoring-remove" ;;
      *" --role projects/test-project/roles/suspendVM "*) command_name="iam-suspend-remove" ;;
      *" --role projects/test-project/roles/startVM "*) command_name="iam-start-remove" ;;
      *) echo "unexpected project IAM removal: $*" >&2; exit 64 ;;
    esac
    ;;
  "compute instances delete "*)
    command_name="instances-delete"
    ;;
  "compute firewall-rules delete "*)
    command_name="firewalls-delete"
    ;;
  "compute disks delete "*)
    command_name="disks-delete"
    ;;
  "iam service-accounts delete "*)
    command_name="service-accounts-delete"
    ;;
  "compute networks subnets delete")
    command_name="subnets-delete"
    ;;
  "compute networks delete "*)
    command_name="networks-delete"
    ;;
  *)
    echo "unexpected gcloud invocation: $*" >&2
    exit 64
    ;;
esac

count_file="$FAKE_GCLOUD_STATE/$command_name"
count="$(state_count "$command_name")"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

case "${FAKE_GCLOUD_MODE:-success}:$command_name:$count" in
  retry-transient:run-services-delete:1 | retry-transient:iam-log-remove:1 | retry-transient:networks-delete:1)
    exit 1
    ;;
esac
if [[ "${FAKE_GCLOUD_MODE:-success}" == "aggregate-failure" &&
  ( "$command_name" == "run-services-delete" || "$command_name" == "instances-delete" || "$command_name" == "subnets-delete" ) ]]; then
  exit 1
fi

touch "$FAKE_GCLOUD_STATE/$command_name.done"
EOF

chmod +x "$tmp/bin/gcloud" "$tmp/bin/sleep"

run_cleanup() {
  local mode="$1" log="$2" state="$3"

  mkdir -p "$state"
  PATH="$tmp/bin:$PATH" \
    FAKE_GCLOUD_LOG="$log" \
    FAKE_GCLOUD_MODE="$mode" \
    FAKE_GCLOUD_STATE="$state" \
    GCLOUD_PROJECT=test-project \
    CLOUD_COMPOSE_SMOKE_RUN_ID=123456789 \
    bash "$repo_root/ci/cloud-smoke.sh" sweep-gcp-wp
}

success_log="$tmp/success.log"
run_cleanup retry-transient "$success_log" "$tmp/state/success"

[[ "$(<"$tmp/state/success/run-services-delete")" == "2" ]] || \
  fail "Cloud Run cleanup did not retry a transient delete failure"
[[ "$(<"$tmp/state/success/iam-log-remove")" == "2" ]] || \
  fail "GCP IAM cleanup did not retry a transient removal failure"
[[ "$(<"$tmp/state/success/networks-delete")" == "2" ]] || \
  fail "GCP network cleanup did not retry a transient delete failure"

for command_name in \
  "run services remove-iam-policy-binding" \
  "run services delete" \
  "projects remove-iam-policy-binding" \
  "compute instances delete" \
  "compute firewall-rules delete" \
  "compute disks delete" \
  "iam service-accounts delete" \
  "compute networks subnets delete" \
  "compute networks delete"; do
  grep -Fq "gcloud ${command_name}" "$success_log" || \
    fail "GCP fallback omitted ${command_name}"
done

grep -F 'gcloud compute instances list' "$success_log" | grep -Fq 'cc-g-wp-12345678-' || \
  fail "GCP cleanup did not constrain resources to the originating workflow run"
grep -F 'gcloud iam service-accounts list' "$success_log" | grep -Fq 'ppb-' || \
  fail "GCP cleanup does not select the power-button service account"
for role in \
  roles/logging.logWriter \
  roles/monitoring.metricWriter \
  projects/test-project/roles/suspendVM \
  projects/test-project/roles/startVM; do
  grep -F 'gcloud projects remove-iam-policy-binding' "$success_log" | grep -Fq "$role" || \
    fail "GCP cleanup omitted project IAM role ${role}"
done
for account in \
  vm-cc-g-wp-12345678-abcd \
  internal-cc-g-wp-12345678-abcd \
  ppb-cc-g-wp-12345678-abcd \
  cc-g-wp-12345678-abcd; do
  grep -F 'gcloud iam service-accounts delete' "$success_log" | grep -Fq "$account@test-project.iam.gserviceaccount.com" || \
    fail "GCP cleanup omitted service account ${account}"
done
grep -F 'gcloud run services remove-iam-policy-binding' "$success_log" | grep -Fq -- '--condition=None' || \
  fail "Cloud Run invoker cleanup did not target the unconditional binding"
if grep -F 'gcloud projects remove-iam-policy-binding' "$success_log" | grep -Fv -- '--condition=None' >/dev/null; then
  fail "Project IAM cleanup did not target unconditional bindings explicitly"
fi

run_invoker_line="$(grep -nF 'gcloud run services remove-iam-policy-binding' "$success_log" | head -n1 | cut -d: -f1)"
run_delete_line="$(grep -nF 'gcloud run services delete' "$success_log" | tail -n1 | cut -d: -f1)"
instance_line="$(grep -nF 'gcloud compute instances delete' "$success_log" | head -n1 | cut -d: -f1)"
[[ "$run_invoker_line" -lt "$run_delete_line" && "$run_delete_line" -lt "$instance_line" ]] || \
  fail "GCP fallback did not remove Cloud Run ingress before deleting the service and VM"

last_project_iam_line="$(grep -nF 'gcloud projects remove-iam-policy-binding' "$success_log" | tail -n1 | cut -d: -f1)"
first_service_account_line="$(grep -nF 'gcloud iam service-accounts delete' "$success_log" | head -n1 | cut -d: -f1)"
[[ "$last_project_iam_line" -lt "$first_service_account_line" ]] || \
  fail "GCP fallback deleted service accounts before removing their project IAM bindings"

subnet_line="$(grep -nF 'gcloud compute networks subnets delete' "$success_log" | tail -n1 | cut -d: -f1)"
network_line="$(grep -nF 'gcloud compute networks delete' "$success_log" | head -n1 | cut -d: -f1)"
[[ "$subnet_line" -lt "$network_line" ]] || \
  fail "GCP fallback did not delete subnetworks before their parent networks"
last_verification_line="$(grep -nF 'gcloud projects get-iam-policy' "$success_log" | tail -n1 | cut -d: -f1)"
[[ "$network_line" -lt "$last_verification_line" ]] || \
  fail "GCP fallback did not verify residual resources after all deletions"

[[ "$(<"$tmp/state/success/service-accounts-delete")" == "4" ]] || \
  fail "GCP cleanup did not delete VM, internal, power-button, and app service accounts"

failure_log="$tmp/failure.log"
if run_cleanup aggregate-failure "$failure_log" "$tmp/state/failure" >/dev/null 2>&1; then
  fail "GCP fallback reported success after permanent resource deletion failures"
fi
[[ "$(<"$tmp/state/failure/run-services-delete")" == "12" ]] || \
  fail "Cloud Run deletion did not exhaust its retry budget"
[[ "$(<"$tmp/state/failure/instances-delete")" == "12" ]] || \
  fail "GCP instance deletion did not exhaust its retry budget"
[[ "$(<"$tmp/state/failure/subnets-delete")" == "12" ]] || \
  fail "GCP subnetwork deletion did not exhaust its retry budget"
[[ -f "$tmp/state/failure/networks-delete" ]] || \
  fail "GCP cleanup stopped instead of aggregating failures across resource kinds"
[[ -f "$tmp/state/failure/service-accounts-delete" ]] || \
  fail "GCP cleanup skipped unrelated resources after an earlier failure"

residual_log="$tmp/residual.log"
if run_cleanup residual-cloud-run "$residual_log" "$tmp/state/residual" >/dev/null 2>&1; then
  fail "GCP fallback reported success while a matching Cloud Run service remained"
fi
[[ "$(grep -cF 'gcloud run services list' "$residual_log")" -ge 13 ]] || \
  fail "GCP cleanup did not exhaust residual-resource verification retries"

pr_workflow="$repo_root/.github/workflows/cloud-smoke.yml"
cleanup_workflow="$repo_root/.github/workflows/cloud-smoke-cleanup.yml"
docs="$repo_root/docs/runtime-contracts.md"

grep -Fq "if: always()" "$pr_workflow" || \
  fail "PR smoke jobs no longer destroy resources in the already-approved job"
if grep -Eq '^  (config-management-cleanup|cleanup|gcp-cleanup):' "$pr_workflow"; then
  fail "PR-controlled workflow still contains a second secret-bearing cleanup job"
fi
grep -Fq "workflow_run:" "$cleanup_workflow" || \
  fail "trusted default-branch fallback cleanup is missing"
grep -Fq "github.event.workflow_run.event == 'pull_request'" "$cleanup_workflow" || \
  fail "fallback cleanup is not restricted to pull-request workflow runs"
grep -Fq "github.event.workflow_run.head_repository.full_name == github.repository" "$cleanup_workflow" || \
  fail "fallback cleanup is not restricted to same-repository workflow runs"
grep -Fq "ref: \${{ github.sha }}" "$cleanup_workflow" || \
  fail "fallback cleanup does not check out the trusted default-branch revision"
if grep -Fq "github.event.workflow_run.head_sha" "$cleanup_workflow"; then
  fail "fallback cleanup checks out pull-request-controlled code"
fi
for environment in \
  cloud-smoke-cleanup-digitalocean \
  cloud-smoke-cleanup-linode \
  cloud-smoke-cleanup-gcp; do
  if grep -Fq "$environment" "$pr_workflow"; then
    fail "pull-request-controlled workflow can request cleanup environment ${environment}"
  fi
  grep -Fq "$environment" "$cleanup_workflow" || \
    fail "fallback cleanup is missing dedicated environment ${environment}"
  grep -Fq "$environment" "$docs" || \
    fail "runtime documentation omits cleanup environment ${environment}"
done

echo "Cloud smoke cleanup contracts passed"
