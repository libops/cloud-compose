#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "app filesystem convergence contract: $*" >&2
  exit 1
}

export COMPOSE_PROJECTS_FILE="$tmp/compose-projects.json"
export COMPOSE_APPS_ENV_DIR="$tmp/apps"
export COMPOSE_APPS_STATE_DIR="$tmp/state"
export CLOUD_COMPOSE_DATA_ROOT="$tmp/data"
fixture_project_dir="$CLOUD_COMPOSE_DATA_ROOT/repository/app"
mkdir -p "$fixture_project_dir"

write_manifest() {
  local path="$1"

  jq -n --arg project_dir "$path" '{app: {
    docker_compose_repo: "https://github.com/libops/wp.git",
    docker_compose_branch: "main",
    project_dir: $project_dir,
    compose_project_name: "app"
  }}' >"$COMPOSE_PROJECTS_FILE"
}

# shellcheck disable=SC1091
source "$repo_root/rootfs/home/cloud-compose/compose-apps.sh"

write_manifest "$fixture_project_dir"
printf 'PRESERVED=value\n' >"$fixture_project_dir/.env"
chmod 0400 "$fixture_project_dir/.env"
original_inode="$(stat -c '%d:%i' "$fixture_project_dir/.env")"
runtime_uid="$(id -u)"
runtime_gid="$(id -g)"
_converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid"

[[ "$(<"$fixture_project_dir/.env")" == "PRESERVED=value" ]] ||
  fail "environment contents changed during metadata repair"
[[ "$(stat -c '%d:%i' "$fixture_project_dir/.env")" == "$original_inode" ]] ||
  fail "environment metadata repair replaced the file"
[[ "$(stat -c '%u:%g:%a:%h' "$fixture_project_dir/.env")" == "${runtime_uid}:${runtime_gid}:640:1" ]] ||
  fail "environment metadata did not converge"
[[ "$(stat -c '%u:%g:%a' "$fixture_project_dir")" == "${runtime_uid}:${runtime_gid}:775" ]] ||
  fail "exact manifest project directory metadata did not converge"

# Convergence is idempotent and does not traverse application content.
mkdir -p "$fixture_project_dir/preserved"
printf 'unchanged\n' >"$fixture_project_dir/preserved/file"
chmod 0600 "$fixture_project_dir/preserved/file"
preserved_metadata="$(stat -c '%u:%g:%a:%i' "$fixture_project_dir/preserved/file")"
_converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid"
[[ "$(stat -c '%u:%g:%a:%i' "$fixture_project_dir/preserved/file")" == "$preserved_metadata" ]] ||
  fail "convergence changed a descendant outside the .env contract"

# Hold convergence after its final read-only ownership transition while an
# adversary tries to replace .env with a symlink. The attempted rename must be
# denied, and the outside target must retain its original metadata and bytes.
mkdir -p "$tmp/bin"
real_chmod="$(command -v chmod)"
export REAL_CHMOD="$real_chmod"
export CONVERGENCE_CHMOD_COUNT="$tmp/chmod-count"
export CONVERGENCE_FROZEN="$tmp/frozen"
export CONVERGENCE_RELEASE="$tmp/release"
cat >"$tmp/bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_CHMOD" "$@"
if [[ "${1:-}" == "0555" ]]; then
  count=0
  [[ ! -f "$CONVERGENCE_CHMOD_COUNT" ]] || count="$(<"$CONVERGENCE_CHMOD_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$CONVERGENCE_CHMOD_COUNT"
  if [[ "$count" -eq 2 ]]; then
    : >"$CONVERGENCE_FROZEN"
    while [[ ! -f "$CONVERGENCE_RELEASE" ]]; do
      sleep 0.01
    done
  fi
fi
EOF
chmod +x "$tmp/bin/chmod"
PATH="$tmp/bin:$PATH"
export PATH

outside_target="$tmp/outside-target"
printf 'outside-preserved\n' >"$outside_target"
outside_metadata="$(stat -c '%u:%g:%a:%i' "$outside_target")"
_converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" &
convergence_pid=$!
for _ in $(seq 1 500); do
  [[ -f "$CONVERGENCE_FROZEN" ]] && break
  sleep 0.01
done
[[ -f "$CONVERGENCE_FROZEN" ]] || fail "convergence did not reach its frozen-directory state"
if mv "$fixture_project_dir/.env" "$fixture_project_dir/.env.raced" 2>/dev/null; then
  ln -s "$outside_target" "$fixture_project_dir/.env"
  : >"$tmp/adversary-swapped"
fi
: >"$CONVERGENCE_RELEASE"
wait "$convergence_pid"
[[ ! -e "$tmp/adversary-swapped" ]] ||
  fail "an adversary replaced .env after the directory was frozen"
[[ "$(<"$outside_target")" == "outside-preserved" ]] ||
  fail "adversarial symlink target contents changed"
[[ "$(stat -c '%u:%g:%a:%i' "$outside_target")" == "$outside_metadata" ]] ||
  fail "adversarial symlink target metadata changed"

PATH="${PATH#"$tmp/bin:"}"
export PATH

mv "$fixture_project_dir/.env" "$fixture_project_dir/.env.regular"
ln -s "$fixture_project_dir/.env.regular" "$fixture_project_dir/.env"
if _converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" >/dev/null 2>&1; then
  fail "symbolic-link environment file was accepted"
fi
chmod 0775 "$fixture_project_dir"
rm "$fixture_project_dir/.env"

mkdir "$fixture_project_dir/.env"
if _converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" >/dev/null 2>&1; then
  fail "non-regular environment path was accepted"
fi
chmod 0775 "$fixture_project_dir"
rmdir "$fixture_project_dir/.env"

ln "$fixture_project_dir/.env.regular" "$fixture_project_dir/.env"
if _converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" >/dev/null 2>&1; then
  fail "hard-linked environment file was accepted"
fi
chmod 0775 "$fixture_project_dir"
rm "$fixture_project_dir/.env"

outside_project="$tmp/outside-project"
mkdir "$outside_project"
write_manifest "$outside_project"
if _converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" >/dev/null 2>&1; then
  fail "project outside the managed data boundary was accepted"
fi

inside_target="$CLOUD_COMPOSE_DATA_ROOT/inside-target"
mkdir "$inside_target"
ln -s "$inside_target" "$CLOUD_COMPOSE_DATA_ROOT/linked-project"
write_manifest "$CLOUD_COMPOSE_DATA_ROOT/linked-project"
if _converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid" >/dev/null 2>&1; then
  fail "symbolic-link project directory was accepted"
fi

missing_project="$CLOUD_COMPOSE_DATA_ROOT/missing/app"
write_manifest "$missing_project"
_converge_compose_app_filesystem_for_ids app "$runtime_uid" "$runtime_gid"
[[ ! -e "$missing_project" ]] ||
  fail "convergence created a checkout before unprivileged source preparation"

converge_line="$(grep -nF 'bash /home/cloud-compose/converge-app-filesystems.sh' \
  "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
source_line="$(grep -nF 'run_as_cloud_compose bash /home/cloud-compose/prepare-app-sources.sh' \
  "$repo_root/rootfs/home/cloud-compose/run.sh" | cut -d: -f1)"
[[ -n "$converge_line" && -n "$source_line" && "$converge_line" -lt "$source_line" ]] ||
  fail "filesystem convergence does not precede unprivileged source preparation"

echo "App filesystem convergence contract passed"
