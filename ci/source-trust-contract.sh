#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "source trust contract: $*" >&2
  exit 1
}

assert_head() {
  local repo="$1" expected="$2"
  local actual

  actual="$(git -C "$repo" rev-parse --verify HEAD)"
  [[ "$actual" == "$expected" ]] || fail "expected $repo at $expected, found $actual"
}

write_project() {
  local name="$1" ref="$2" checkout="$3"

  jq -n \
    --arg name "$name" \
    --arg repo "$remote" \
    --arg ref "$ref" \
    --arg checkout "$checkout" \
    '{($name): {
      docker_compose_repo: $repo,
      docker_compose_branch: $ref,
      project_dir: $checkout,
      compose_project_name: $name
    }}' > "$projects_file"
}

export HOME="$tmp/home"
mkdir -p "$HOME"

remote="$tmp/remote.git"
source_repo="$tmp/source"
git init --bare --initial-branch=main "$remote" >/dev/null
git init --initial-branch=main "$source_repo" >/dev/null
git -C "$source_repo" config user.name "Cloud Compose Contract"
git -C "$source_repo" config user.email "cloud-compose-contract@example.invalid"
printf 'one\n' > "$source_repo/version.txt"
git -C "$source_repo" add version.txt
git -C "$source_repo" commit -m one >/dev/null
commit_one="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" tag release-one
printf 'two\n' > "$source_repo/version.txt"
git -C "$source_repo" commit -am two >/dev/null
git -C "$source_repo" remote add origin "$remote"
git -C "$source_repo" push --set-upstream origin main --tags >/dev/null

projects_file="$tmp/compose-projects.json"
export COMPOSE_PROJECTS_FILE="$projects_file"
export COMPOSE_APPS_ENV_DIR="$tmp/apps"
export COMPOSE_APPS_STATE_DIR="$tmp/state"
export CLOUD_COMPOSE_DATA_ROOT="$tmp"

retry_until_success() {
  "$@"
}

# shellcheck disable=SC1091
source "$repo_root/rootfs/home/cloud-compose/compose-apps.sh"

pinned_checkout="$tmp/pinned"
write_project pinned "$commit_one" "$pinned_checkout"
clone_or_update_compose_app pinned
assert_head "$pinned_checkout" "$commit_one"
if git -C "$pinned_checkout" symbolic-ref -q HEAD >/dev/null; then
  fail "full commit checkout did not use detached HEAD"
fi
[[ ! -e "$COMPOSE_APPS_STATE_DIR/pinned.deployed-head" ]] || \
  fail "checkout was recorded as deployed before its lifecycle succeeded"
run_compose_app_lifecycle pinned init
[[ "$(<"$COMPOSE_APPS_STATE_DIR/pinned.deployed-head")" == "$commit_one" ]] || \
  fail "pinned deployed HEAD was not recorded"

printf 'three\n' > "$source_repo/version.txt"
git -C "$source_repo" commit -am three >/dev/null
commit_three="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" push origin main >/dev/null
clone_or_update_compose_app pinned
assert_head "$pinned_checkout" "$commit_one"

branch_checkout="$tmp/branch"
write_project branch main "$branch_checkout"
clone_or_update_compose_app branch
assert_head "$branch_checkout" "$commit_three"
run_compose_app_lifecycle branch init
printf 'four\n' > "$source_repo/version.txt"
git -C "$source_repo" commit -am four >/dev/null
commit_four="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" push origin main >/dev/null
clone_or_update_compose_app branch
assert_head "$branch_checkout" "$commit_four"
[[ "$(<"$COMPOSE_APPS_STATE_DIR/branch.deployed-head")" == "$commit_three" ]] || \
  fail "source update changed deployed state before lifecycle success"
run_compose_app_lifecycle branch init
[[ "$(<"$COMPOSE_APPS_STATE_DIR/branch.deployed-head")" == "$commit_four" ]] || \
  fail "moving branch deployed HEAD was not recorded"

# A rollout may deliberately deploy a feature or provider-specific ref that is
# not an ancestor of the configured baseline branch. Ordinary service starts
# must preserve that deployed revision, and a later rollout must remain able to
# move back to the baseline instead of failing before its rollout command runs.
git -C "$source_repo" checkout -b feature >/dev/null
printf 'feature\n' >"$source_repo/feature.txt"
git -C "$source_repo" add feature.txt
git -C "$source_repo" commit -m feature >/dev/null
feature_commit="$(git -C "$source_repo" rev-parse HEAD)"
git -C "$source_repo" push origin feature >/dev/null
git -C "$source_repo" checkout main >/dev/null
jq '.branch.rollout_commands = [
      "git fetch -- origin feature",
      "git checkout --detach FETCH_HEAD"
    ] | .branch.up_commands = ["true"]' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
run_compose_app_lifecycle branch rollout
assert_head "$branch_checkout" "$feature_commit"
[[ "$(<"$COMPOSE_APPS_STATE_DIR/branch.deployed-head")" == "$feature_commit" ]] || \
  fail "feature rollout HEAD was not recorded"
run_compose_app_lifecycle branch up
assert_head "$branch_checkout" "$feature_commit"
jq '.branch.rollout_commands = [
      "git fetch -- origin main",
      "git checkout --detach FETCH_HEAD"
    ]' "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
run_compose_app_lifecycle branch rollout
assert_head "$branch_checkout" "$commit_four"

# Full bootstrap/source preparation may restore the configured baseline after
# a recorded rollout. It must not grant the same reset authority to an
# unrecorded local-ahead commit.
jq '.branch.rollout_commands = [
      "git fetch -- origin feature",
      "git checkout --detach FETCH_HEAD"
    ]' "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
run_compose_app_lifecycle branch rollout
assert_head "$branch_checkout" "$feature_commit"
clone_or_update_compose_app branch
assert_head "$branch_checkout" "$commit_four"

# A local commit must never be treated as an already-up-to-date moving branch.
# Deployment state must converge exactly to the fetched remote object.
git -C "$branch_checkout" config user.name "Cloud Compose Contract"
git -C "$branch_checkout" config user.email "cloud-compose-contract@example.invalid"
printf 'local-ahead\n' >"$branch_checkout/local-only.txt"
git -C "$branch_checkout" add local-only.txt
git -C "$branch_checkout" commit -m local-ahead >/dev/null
local_ahead_commit="$(git -C "$branch_checkout" rev-parse HEAD)"
if clone_or_update_compose_app branch >/dev/null 2>&1; then
  fail "moving branch accepted a local-ahead checkout"
fi
assert_head "$branch_checkout" "$local_ahead_commit"

tag_checkout="$tmp/tag"
write_project tag release-one "$tag_checkout"
clone_or_update_compose_app tag
assert_head "$tag_checkout" "$commit_one"

printf 'dirty-tracked\n' >"$tag_checkout/version.txt"
if clone_or_update_compose_app tag >/dev/null 2>&1; then
  fail "pinned checkout accepted a tracked worktree modification"
fi
git -C "$tag_checkout" restore -- version.txt
printf 'staged\n' >"$tag_checkout/staged.txt"
git -C "$tag_checkout" add staged.txt
if clone_or_update_compose_app tag >/dev/null 2>&1; then
  fail "pinned checkout accepted a staged worktree modification"
fi
git -C "$tag_checkout" restore --staged -- staged.txt
rm -f -- "$tag_checkout/staged.txt"
printf 'services: {}\n' >"$tag_checkout/compose.override.yaml"
if clone_or_update_compose_app tag >/dev/null 2>&1; then
  fail "pinned checkout accepted an untracked Compose override"
fi
rm -f -- "$tag_checkout/compose.override.yaml"
clone_or_update_compose_app tag
assert_head "$tag_checkout" "$commit_one"
run_compose_app_lifecycle tag init
[[ "$(<"$COMPOSE_APPS_STATE_DIR/tag.deployed-head")" == "$commit_one" ]] || \
  fail "tag deployed HEAD was not recorded"
clone_or_update_compose_app tag
assert_head "$tag_checkout" "$commit_one"

origin_checkout="$tmp/origin-mismatch"
write_project origin main "$origin_checkout"
clone_or_update_compose_app origin
git -C "$origin_checkout" remote set-url origin "$tmp/not-the-configured-origin.git"
if clone_or_update_compose_app origin >/dev/null 2>&1; then
  fail "existing checkout accepted an origin that did not match the configured repository"
fi

failure_checkout="$tmp/lifecycle-failure"
write_project failure "$commit_one" "$failure_checkout"
jq '.failure.init_commands = ["false"]' "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
if run_compose_app_lifecycle failure init >/dev/null 2>&1; then
  fail "failing lifecycle command unexpectedly succeeded"
fi
[[ ! -e "$COMPOSE_APPS_STATE_DIR/failure.deployed-head" ]] || \
  fail "failing lifecycle was recorded as deployed"

unsafe_ref_checkout="$tmp/unsafe-ref"
write_project unsafe-ref '--upload-pack=/tmp/not-a-command' "$unsafe_ref_checkout"
if clone_or_update_compose_app unsafe-ref >/dev/null 2>&1; then
  fail "unsafe Git ref was accepted as a fetch option"
fi
[[ ! -e "$unsafe_ref_checkout" ]] || fail "unsafe Git ref mutated the checkout path"

unsafe_repo_checkout="$tmp/unsafe-repo"
write_project unsafe-repo main "$unsafe_repo_checkout"
jq '."unsafe-repo".docker_compose_repo = "--upload-pack=/tmp/not-a-command"' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
if clone_or_update_compose_app unsafe-repo >/dev/null 2>&1; then
  fail "unsafe repository location was accepted as a Git option"
fi
[[ ! -e "$unsafe_repo_checkout" ]] || fail "unsafe repository location mutated the checkout path"

coreos_installer="$repo_root/rootfs/home/cloud-compose/install-dependencies-coreos.sh"
grep -Fq 'for package in git jq make openssl; do' "$coreos_installer" || \
  fail "CoreOS base dependency set changed unexpectedly"
if grep -Eq 'packages\.libops\.io|sitectl\.repo|SITECTL_PACKAGES' "$coreos_installer"; then
  fail "CoreOS bootstrap still has a redundant sitectl RPM ownership path"
fi

grep -Eq '^[[:space:]]+openssl([[:space:]\\]|$)' \
  "$repo_root/rootfs/home/cloud-compose/install-dependencies-debian.sh" || \
  fail "Debian bootstrap does not install the explicit openssl runtime dependency"
grep -Fq 'command -v openssl' "$repo_root/rootfs/home/cloud-compose/install-dependencies-cos.sh" || \
  fail "COS bootstrap does not fail closed when openssl is unavailable"
grep -Fq -- '- openssl' "$repo_root/ansible/roles/cloud_compose/tasks/main.yml" || \
  fail "Ansible bootstrap does not install the explicit openssl runtime dependency"
grep -Fq -- '- openssl' "$repo_root/salt/cloud-compose/init.sls" || \
  fail "Salt bootstrap does not install the explicit openssl runtime dependency"

host_conf="$repo_root/rootfs/home/cloud-compose/host-conf.sh"
dependencies_line="$(grep -nF 'bash /home/cloud-compose/install-dependencies.sh' "$host_conf" | cut -d: -f1)"
managed_runtime_line="$(grep -nF 'bash /home/cloud-compose/libops-managed-runtime.sh install-tools' "$host_conf" | cut -d: -f1)"
[[ -n "$dependencies_line" && -n "$managed_runtime_line" && "$dependencies_line" -lt "$managed_runtime_line" ]] || \
  fail "verified managed-runtime package installation does not follow OS dependency installation"

release_workflow="$repo_root/.github/workflows/github-release.yaml"
grep -Fq 'libops/.github/.github/workflows/bump-release.yaml@8dfaf9c854df71d9bbffde48c5676ff07c543c51' "$release_workflow" || \
  fail "write-capable release workflow is not pinned to the approved commit"

gcp_module="$repo_root/modules/gcp/main.tf"
grep -Eq 'source = "https://github\.com/libops/terraform-cloudrun-v2/archive/[0-9a-f]{40}\.zip//terraform-cloudrun-v2-[0-9a-f]{40}"' \
  "$gcp_module" || fail "GCP power-button Terraform dependency is not pinned to a full commit"
if grep -Eq 'source = "https://github\.com/.*/archive/(refs/)?(heads|tags)/' "$gcp_module"; then
  fail "GCP module still consumes a mutable or unverified GitHub archive source"
fi

linux_runtime="$repo_root/modules/linux-vm-runtime/main.tf"
grep -Fq "archive_url_b64='\${base64encode(local.rootfs_archive_url)}'" "$linux_runtime" || \
  fail "Linux rootfs archive URL is not rendered as base64 shell data"
if grep -Fq 'archive_url=${jsonencode(local.rootfs_archive_url)}' "$linux_runtime"; then
  fail "Linux rootfs archive URL is still rendered as executable shell syntax"
fi
grep -Fq 'archive_additional_rootfs_commands' "$linux_runtime" || \
  fail "Additional rootfs content is not reapplied after archive extraction"
for runtime_module in "$linux_runtime" "$gcp_module"; do
  grep -Fq -- "curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2" "$runtime_module" || \
    fail "rootfs archive download is not restricted to HTTPS with TLS 1.2 or newer in $runtime_module"
  grep -Fq -- '--connect-timeout 10 --max-time 300 -o "$tmp/rootfs.tar.gz" -- "$archive_url"' "$runtime_module" || \
    fail "rootfs archive download is not bounded or separated from curl options in $runtime_module"
  grep -Fq 'rootfs_dir="$(find "$tmp" -mindepth 1 -maxdepth 3 -type d -name rootfs -print -quit)"' "$runtime_module" || \
    fail "rootfs archive discovery does not accept the documented depth range in $runtime_module"
done

rollout_installer="$repo_root/rootfs/home/cloud-compose/deploy-rollout.sh"
grep -Fq 'ROLLOUT_DOWNLOAD_URL must be an HTTPS URL without whitespace' "$rollout_installer" || \
  fail "rollout installer does not require HTTPS"
grep -Fq -- "curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2" "$rollout_installer" || \
  fail "rollout download is not restricted to HTTPS with TLS 1.2 or newer"
grep -Fq -- '--connect-timeout 10 --max-time 300 -o "$tmp" -- "$ROLLOUT_DOWNLOAD_URL"' "$rollout_installer" || \
  fail "rollout download is not bounded or separated from curl options"
grep -Fq 'mv -f -- "$install_tmp" /usr/local/bin/cloud-compose-rollout' "$rollout_installer" || \
  fail "rollout binary is not promoted atomically"

for smoke_script in \
  "$repo_root/ci/config-management-smoke.sh" \
  "$repo_root/ci/config-management-cloud-smoke.sh"; do
  grep -Eq 'CONFIG_MANAGEMENT_IMAGE_DEFAULT="python:[^@"]+@sha256:[0-9a-f]{64}"' "$smoke_script" || \
    fail "configuration-management test image is not digest pinned in $smoke_script"
done

echo "Source trust contracts passed"
