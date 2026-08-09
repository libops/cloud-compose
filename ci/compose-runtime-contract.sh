#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "compose runtime contract: $*" >&2
  exit 1
}

lifecycle_program="$repo_root/rootfs/home/cloud-compose/default-lifecycle.sh"
for defaults_file in \
  modules/gcp/variables.tf \
  modules/linux-vm-runtime/variables.tf \
  ansible/roles/cloud_compose/defaults/main.yml \
  salt/cloud-compose/init.sls; do
  for action in init up down rollout; do
    if [[ "$(grep -Fc -- "/home/cloud-compose/default-lifecycle.sh $action" "$repo_root/$defaults_file")" -ne 1 ]]; then
      fail "$defaults_file does not invoke the $action lifecycle program exactly once"
    fi
  done
  if grep -Fq -- 'TARGET_REF=' "$repo_root/$defaults_file"; then
    fail "$defaults_file still splits rollout state across lifecycle command entries"
  fi
done
bash "$repo_root/ci/lifecycle-program-contract.sh" \
  "$lifecycle_program" \
  "$repo_root/rootfs/etc/cloud-compose/jq/sitectl-verify-args.jq"
grep -Fq -- 'run_lifecycle_program_contract "$home_dir" "$key_path" "$output_json"' \
  "$repo_root/ci/cloud-smoke.sh" || fail "provider smoke does not execute the lifecycle program contract"
grep -Fq -- 'bash "$lifecycle_program_contract" /home/cloud-compose/default-lifecycle.sh' \
  "$repo_root/ci/remote/config-management-verify.sh" || \
  fail "config-management smoke does not execute the lifecycle program contract"

grep -Fq 'cd "$script_dir"' "$repo_root/rootfs/home/cloud-compose/prepare-app-sources.sh" || \
  fail "source preparation does not enter an accessible working directory before dropping privileges"
grep -Fq 'run_as_cloud_compose() (' "$repo_root/rootfs/home/cloud-compose/run.sh" || \
  fail "privilege-drop helper does not isolate its working-directory change"
grep -Fq 'cd /home/cloud-compose' "$repo_root/rootfs/home/cloud-compose/run.sh" || \
  fail "privilege-drop helper can inherit an inaccessible caller working directory"
if grep -Fq 'su -s /bin/bash -c' "$repo_root/rootfs/home/cloud-compose/run.sh"; then
  fail "privilege-drop helper still synthesizes a shell program through su"
fi
grep -Fq 'run_compose_lifecycle_executor "$lifecycle" "$command"' \
  "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" || \
  fail "Compose lifecycle entries do not pass through the checked executor"
grep -Fq 'readonly COMPOSE_LIFECYCLE_EXECUTOR="/etc/cloud-compose/libexec/run-lifecycle-program.sh"' \
  "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" || \
  fail "Compose lifecycle entries do not use the canonical checked executor path"
grep -Fq '"$COMPOSE_LIFECYCLE_EXECUTOR" "$@"' \
  "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" || \
  fail "Compose lifecycle executor wrapper does not invoke the canonical checked program"
grep -Fq 'run_compose_lifecycle_executor --validate "$lifecycle" "$command" || return 1' \
  "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" || \
  fail "Compose lifecycle program sets are not validated before execution"
if grep -Fq 'bash -c "$command"' "$repo_root/rootfs/home/cloud-compose/compose-apps.sh"; then
  fail "Compose lifecycle entries still execute as shell strings"
fi

export COMPOSE_PROJECTS_FILE="$tmp/compose-projects.json"
export COMPOSE_APPS_ENV_DIR="$tmp/apps"
export COMPOSE_APPS_STATE_DIR="$tmp/state"
export CLOUD_COMPOSE_DATA_ROOT="$tmp/data"
mkdir -p "$CLOUD_COMPOSE_DATA_ROOT/project"

# shellcheck disable=SC1091
source "$repo_root/rootfs/home/cloud-compose/compose-apps.sh"

# Exercise the checked-in executor while retaining the immutable production
# path contract above. The production image installs the same file at the
# canonical /etc location.
run_compose_lifecycle_executor() {
  "$repo_root/rootfs/etc/cloud-compose/libexec/run-lifecycle-program.sh" "$@"
}

cat >"$CLOUD_COMPOSE_DATA_ROOT/project/compose.yaml" <<'EOF'
secrets:
  DB_ROOT_PASSWORD:
    file: ./secrets/DB_ROOT_PASSWORD
  WORDPRESS_DB_PASSWORD:
    file: ./secrets/WORDPRESS_DB_PASSWORD
EOF
mapfile -t compose_secrets < <(
  cd "$CLOUD_COMPOSE_DATA_ROOT/project"
  compose_secret_files
)
[[ "${compose_secrets[*]}" == "./secrets/DB_ROOT_PASSWORD ./secrets/WORDPRESS_DB_PASSWORD" ]] || \
  fail "Compose Specification compose.yaml secret files were not discovered"

jq -n \
  --arg project_dir "$CLOUD_COMPOSE_DATA_ROOT/project" \
  --arg trailing_command $'printf "trailing newline preserved"\n' '{
  app: {
    docker_compose_repo: "https://github.com/libops/wp.git",
    docker_compose_branch: "main",
    project_dir: $project_dir,
    compose_project_name: "app",
    sitectl_verify_args: ["--label", "value with spaces"],
    ingress: {trusted_ips: ["192.0.2.1/32"]},
    init_commands: ["printf \"line one\\nline two\\n\"", $trailing_command],
    up_commands: [],
    down_commands: [],
    rollout_commands: []
  }
}' >"$COMPOSE_PROJECTS_FILE"

apps=()
compose_app_names_array apps
[[ "${apps[*]}" == "app" ]] || fail "valid app names did not materialize"
commands=()
compose_app_array_values app init_commands commands
[[ "${#commands[@]}" == 2 && "${commands[0]}" == *'line one\nline two'* ]] || \
  fail "lifecycle command boundaries were not preserved"
[[ "${commands[1]}" == $'printf "trailing newline preserved"\n' ]] || \
  fail "a trailing lifecycle-command newline was normalized"
write_compose_app_env app
[[ -f "$COMPOSE_APPS_ENV_DIR/app.env" ]] || fail "validated app env was not written"

printf '{' >"$COMPOSE_PROJECTS_FILE"
if compose_app_names_array apps >/dev/null 2>&1; then
  fail "malformed JSON was accepted"
fi

jq -n --arg project_dir "$CLOUD_COMPOSE_DATA_ROOT/project" '{"../escape": {
  docker_compose_repo: "https://github.com/libops/wp.git",
  docker_compose_branch: "main",
  project_dir: $project_dir,
  compose_project_name: "escape"
}}' >"$COMPOSE_PROJECTS_FILE"
if compose_app_names_array apps >/dev/null 2>&1; then
  fail "path-traversing app name was accepted"
fi
[[ ! -e "$tmp/escape.env" ]] || fail "invalid app name escaped the app env directory"

for unsafe_app_json in \
  '{"app\n":{"docker_compose_repo":"https://github.com/libops/wp.git","docker_compose_branch":"main","project_dir":"PROJECT_DIR","compose_project_name":"app"}}' \
  '{"app\u0000":{"docker_compose_repo":"https://github.com/libops/wp.git","docker_compose_branch":"main","project_dir":"PROJECT_DIR","compose_project_name":"app"}}'; do
  printf '%s' "${unsafe_app_json//PROJECT_DIR/$CLOUD_COMPOSE_DATA_ROOT\/project}" >"$COMPOSE_PROJECTS_FILE"
  if compose_app_names_array apps >/dev/null 2>&1; then
    fail "control-character app name was accepted"
  fi
done

jq -n --arg project_dir "$CLOUD_COMPOSE_DATA_ROOT/project" '{app: {
  docker_compose_repo: "https://github.com/libops/wp.git",
  docker_compose_branch: "main",
  project_dir: $project_dir,
  compose_project_name: "app",
  up_commands: "not-an-array"
}}' >"$COMPOSE_PROJECTS_FILE"
if compose_app_names_array apps >/dev/null 2>&1; then
  fail "invalid lifecycle command type was accepted"
fi

for unsafe_project_dir in "/" "/etc" "$CLOUD_COMPOSE_DATA_ROOT" "$CLOUD_COMPOSE_DATA_ROOT/../escape" "$CLOUD_COMPOSE_DATA_ROOT//escape" "$CLOUD_COMPOSE_DATA_ROOT/project"$'\n'; do
  jq -n --arg project_dir "$unsafe_project_dir" '{app: {
    docker_compose_repo: "https://github.com/libops/wp.git",
    docker_compose_branch: "main",
    project_dir: $project_dir,
    compose_project_name: "app"
  }}' >"$COMPOSE_PROJECTS_FILE"
  if compose_app_names_array apps >/dev/null 2>&1; then
    fail "unsafe project directory was accepted: $unsafe_project_dir"
  fi
done

ln -s "$tmp" "$CLOUD_COMPOSE_DATA_ROOT/outside-link"
jq -n --arg project_dir "$CLOUD_COMPOSE_DATA_ROOT/outside-link/escape" '{app: {
  docker_compose_repo: "https://github.com/libops/wp.git",
  docker_compose_branch: "main",
  project_dir: $project_dir,
  compose_project_name: "app"
}}' >"$COMPOSE_PROJECTS_FILE"
if compose_app_names_array apps >/dev/null 2>&1; then
  fail "symlink-escaping project directory was accepted"
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_COMPOSE_CONFIG:?}"
EOF
chmod +x "$tmp/bin/docker"
PATH="$tmp/bin:$PATH"
export PATH CLOUD_COMPOSE_PROVIDER=gcp
FAKE_COMPOSE_CONFIG="$(jq -cn '{services:{web:{network_mode:"host"}}}')"
export FAKE_COMPOSE_CONFIG
if reject_host_network_compose_services >/dev/null 2>&1; then
  fail "GCP host-network Compose service was accepted"
fi
FAKE_COMPOSE_CONFIG="$(jq -cn '{services:{web:{network_mode:"default"}}}')"
export FAKE_COMPOSE_CONFIG
reject_host_network_compose_services

FAKE_COMPOSE_CONFIG="$(jq -cn '{services:{web:{build:{context:".",network:"host"}}}}')"
export FAKE_COMPOSE_CONFIG
if reject_host_network_compose_services >/dev/null 2>&1; then
  fail "GCP host-network Compose build was accepted"
fi

FAKE_COMPOSE_CONFIG="$(jq -cn '{services:{web:{build:{context:".",entitlements:["network.host"]}}}}')"
export FAKE_COMPOSE_CONFIG
if reject_host_network_compose_services >/dev/null 2>&1; then
  fail "GCP host-network BuildKit entitlement was accepted"
fi

FAKE_COMPOSE_CONFIG="$(jq -cn '{services:{web:{build:{context:".",network:"default"}}}}')"
export FAKE_COMPOSE_CONFIG
reject_host_network_compose_services

# Preserve list(string) verify arguments as argv. A value containing spaces is
# one argument, not an unquoted scalar split by the lifecycle shell.
jq -n \
  --arg project_dir "$CLOUD_COMPOSE_DATA_ROOT/project" \
  --arg up_program "$repo_root/ci/fixtures/lifecycle.d/default-up" '{app: {
  docker_compose_repo: "https://github.com/libops/wp.git",
  docker_compose_branch: "main",
  project_dir: $project_dir,
  compose_project_name: "app",
  sitectl_context_name: "app",
  sitectl_environment: "preview",
  sitectl_verify_args: ["--label", "value with spaces"],
  up_commands: [$up_program],
  init_commands: [], down_commands: [], rollout_commands: []
}}' >"$COMPOSE_PROJECTS_FILE"
ln -s "$repo_root/ci/fixtures/sitectl-argv-log.sh" "$tmp/bin/sitectl"
export SITECTL_ARGV_LOG="$tmp/sitectl.argv"
export CLOUD_COMPOSE_LIFECYCLE_PROGRAM_DIR="$repo_root/ci/fixtures/lifecycle.d"
export CLOUD_COMPOSE_SITECTL_VERIFY_ARGS_PROGRAM="$repo_root/rootfs/etc/cloud-compose/jq/sitectl-verify-args.jq"
clone_or_update_compose_app() { source_compose_app_env "$1"; }
record_compose_app_head() { return 0; }
CLOUD_COMPOSE_PROVIDER=linode
run_compose_app_lifecycle app up
cat >"$tmp/expected.argv" <<'EOF'
<compose>
<--context>
<app>
<up>
<-d>
<--remove-orphans>
<healthcheck>
<--context>
<app>
<--persist>
<verify>
<--context>
<app>
<--label>
<value with spaces>
EOF
cmp -s "$tmp/expected.argv" "$SITECTL_ARGV_LOG" || fail "sitectl verify argument boundaries were lost"

echo "Compose runtime contract passed"
