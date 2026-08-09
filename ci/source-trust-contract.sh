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
git -C "$source_repo" tag -a -m 'release one' release-one
printf 'two\n' > "$source_repo/version.txt"
git -C "$source_repo" commit -am two >/dev/null
git -C "$source_repo" remote add origin "$remote"
git -C "$source_repo" push --set-upstream origin main --tags >/dev/null

projects_file="$tmp/compose-projects.json"
export COMPOSE_PROJECTS_FILE="$projects_file"
export COMPOSE_APPS_ENV_DIR="$tmp/apps"
export COMPOSE_APPS_STATE_DIR="$tmp/state"
export CLOUD_COMPOSE_DATA_ROOT="$tmp"
export CLOUD_COMPOSE_LIFECYCLE_PROGRAM_DIR="$repo_root/ci/fixtures"
readonly source_trust_rollout_program="$repo_root/ci/fixtures/source-trust-rollout.sh"

retry_until_success() {
  "$@"
}

# shellcheck disable=SC1091
source "$repo_root/rootfs/home/cloud-compose/compose-apps.sh"
export CLOUD_COMPOSE_TEST_LIFECYCLE_EXECUTOR="$repo_root/rootfs/etc/cloud-compose/libexec/run-lifecycle-program.sh"
# shellcheck disable=SC1091
source "$repo_root/ci/fixtures/checked-lifecycle-executor.sh"

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

# A reconstructed host reuses the persistent application-data disk. Changing
# the configured ref must reconcile that existing checkout in place instead of
# selecting a ref-derived directory and abandoning the prior workspace.
branch_checkout_inode="$(stat -c %i "$branch_checkout")"
printf 'persistent host data\n' >"$branch_checkout/host-data.keep"
jq '.branch.docker_compose_branch = "release-one"' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
clone_or_update_compose_app branch
assert_head "$branch_checkout" "$commit_one"
[[ "$(stat -c %i "$branch_checkout")" == "$branch_checkout_inode" ]] || \
  fail "configured-ref migration replaced the persistent checkout directory"
[[ -f "$branch_checkout/host-data.keep" ]] || \
  fail "configured-ref migration discarded persistent checkout data"
jq '.branch.docker_compose_branch = "main"' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
clone_or_update_compose_app branch
assert_head "$branch_checkout" "$commit_four"

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
jq --arg rollout_program "$source_trust_rollout_program" \
  '.branch.rollout_commands = [$rollout_program] | .branch.up_commands = ["true"]' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
export SOURCE_TRUST_ROLLOUT_REF=feature
run_compose_app_lifecycle branch rollout
assert_head "$branch_checkout" "$feature_commit"
[[ "$(<"$COMPOSE_APPS_STATE_DIR/branch.deployed-head")" == "$feature_commit" ]] || \
  fail "feature rollout HEAD was not recorded"
run_compose_app_lifecycle branch up
assert_head "$branch_checkout" "$feature_commit"
jq --arg rollout_program "$source_trust_rollout_program" \
  '.branch.rollout_commands = [$rollout_program]' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
export SOURCE_TRUST_ROLLOUT_REF=main
run_compose_app_lifecycle branch rollout
assert_head "$branch_checkout" "$commit_four"

# Full bootstrap/source preparation may restore the configured baseline after
# a recorded rollout. It must not grant the same reset authority to an
# unrecorded local-ahead commit.
jq --arg rollout_program "$source_trust_rollout_program" \
  '.branch.rollout_commands = [$rollout_program]' \
  "$projects_file" >"$projects_file.tmp"
mv "$projects_file.tmp" "$projects_file"
export SOURCE_TRUST_ROLLOUT_REF=feature
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
linux_runtime_outputs="$repo_root/modules/linux-vm-runtime/outputs.tf"
linux_runtime_variables="$repo_root/modules/linux-vm-runtime/variables.tf"
linux_runtime_tests="$repo_root/modules/linux-vm-runtime/runtime_inputs.tftest.hcl"
gcp_cloud_init="$repo_root/templates/cloud-init.yml"
linux_cloud_init="$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml"
archive_program="$repo_root/rootfs/etc/cloud-compose/libexec/rootfs-archive.sh"

grep -Eq 'ROOTFS_ARCHIVE_URL_B64[[:space:]]*=[[:space:]]*base64encode\(local\.rootfs_archive_url\)' "$linux_runtime" || \
  fail "Linux rootfs archive URL is not transported as base64 data"
grep -Fq 'count = local.rootfs_archive_url != "" && local.rootfs_test_source_archive_prefix == "" ? 1 : 0' "$linux_runtime" || \
  fail "Linux production archive mode does not keep the release sidecar mandatory"
grep -Fq 'variable "rootfs_test_source_archive_prefix"' "$linux_runtime_variables" || \
  fail "Linux hosted smoke source mode is not unmistakably test-only"
grep -Fq 'regex("^cloud-compose-[0-9a-f]{40}$"' "$linux_runtime_variables" || \
  fail "Linux hosted smoke source mode does not require one exact lowercase commit SHA"
grep -Fq 'https://github.com/libops/cloud-compose/archive/${trimprefix(local.rootfs_test_source_archive_prefix, "cloud-compose-")}.tar.gz' "$linux_runtime_outputs" || \
  fail "Linux hosted smoke source mode does not bind its URL to the exact prefix commit"
for negative_contract in \
  rejects_source_archive_from_another_commit \
  rejects_tag_named_source_archive_prefix \
  rejects_arbitrary_test_source_archive_url; do
  grep -Fq "run \"${negative_contract}\"" "$linux_runtime_tests" || \
    fail "Linux hosted smoke source mode lacks ${negative_contract} coverage"
done
for production_surface in \
  "$repo_root/variables.tf" \
  "$repo_root/modules/gcp/variables.tf" \
  "$repo_root/providers/gcp/variables.tf" \
  "$repo_root/providers/do/variables.tf" \
  "$repo_root/providers/linode/variables.tf"; do
  if grep -Fq 'rootfs_test_source_archive_prefix' "$production_surface"; then
    fail "$production_surface exposes the test-only hosted source mode"
  fi
done
grep -Fq 'ROOTFS_ARCHIVE_URL_B64' "$linux_cloud_init" || \
  fail "Linux cloud-init does not pass rootfs archive URL data to its checked-in entrypoint"
grep -Fq 'prepare-linux-test-source' "$linux_cloud_init" || \
  fail "Linux hosted smoke cannot invoke the checked source-archive fixture path"
grep -Fq 'rootfs_overlay_staging_path' "$linux_runtime" || \
  fail "Additional rootfs content is not staged for reapplication after archive extraction"
for runtime_module in "$linux_runtime" "$gcp_module"; do
  grep -Fq 'ROOTFS_ARCHIVE_SCRIPT_B64' "$runtime_module" || \
    fail "$runtime_module does not transfer the checked-in rootfs archive program"
  grep -Fq 'rootfs_contract_sha256 = sha256(join("", [' "$runtime_module" || \
    fail "$runtime_module does not bind archive contents to its exact bundled rootfs"
  grep -Fq 'cloud-compose-rootfs.contract.sha256' "$runtime_module" || \
    fail "$runtime_module does not derive the immutable rootfs contract sidecar"
  grep -Fq 'data "http" "rootfs_contract"' "$runtime_module" || \
    fail "$runtime_module does not verify the release contract during planning"
  if grep -Fq -- "curl -fsSL --proto '=https'" "$runtime_module"; then
    fail "$runtime_module still embeds the rootfs archive shell implementation"
  fi
done
for cloud_init_template in "$linux_cloud_init" "$gcp_cloud_init"; do
  grep -Fq '/var/lib/cloud-compose/bootstrap/rootfs-archive.sh' "$cloud_init_template" || \
    fail "$cloud_init_template does not install or invoke the checked-in rootfs archive program"
done
grep -Fq -- "curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2" "$archive_program" || \
  fail "rootfs archive download is not restricted to HTTPS with TLS 1.2 or newer"
grep -Fq -- '--connect-timeout 10 --max-time 300' "$archive_program" || \
  fail "rootfs archive download is not bounded"
grep -Fq -- '-o "$stage_root/rootfs.tar.gz" -- "$archive_url"' "$archive_program" || \
  fail "rootfs archive URL is not separated from curl options"
grep -Fq 'validate_rootfs_archive "$stage_root/rootfs.tar.gz"' "$archive_program" || \
  fail "rootfs archive members are not validated before extraction"
grep -Fq 'validate_rootfs_test_source_archive "$stage_root/rootfs.tar.gz" "$test_source_prefix"' "$archive_program" || \
  fail "hosted smoke source-archive members are not validated before extraction"
grep -Fq 'https://github.com/libops/cloud-compose/archive/${source_commit}.tar.gz' "$archive_program" || \
  fail "hosted smoke source archives are not tied to one exact libops/cloud-compose commit"
grep -Fq '[[ "$member_type" == "-" || "$member_type" == "d" ]]' "$archive_program" || \
  fail "rootfs archive validation does not reject links before extraction"
grep -Fq 'rootfs archive paths, bytes, or canonical metadata do not match this cloud-compose module source' "$archive_program" || \
  fail "rootfs archive extraction does not reject module/archive content mismatches"
grep -Fq "stat -c '%a:%h:%F'" "$archive_program" || \
  fail "rootfs archive contract does not reject noncanonical modes or hard links"
for embedded_source in "$linux_runtime" "$gcp_module" "$linux_cloud_init" "$gcp_cloud_init"; do
  if grep -Eq 'sha256sum -c -|tar --no-same-owner|rootfs_dir=\"\$\(find' "$embedded_source"; then
    fail "$embedded_source still embeds the substantive rootfs archive program"
  fi
done

cloud_smoke="$repo_root/ci/cloud-smoke.sh"
cloud_smoke_workflow="$repo_root/.github/workflows/cloud-smoke.yml"
for fixture in "$repo_root/tests/smoke/do/main.tf" "$repo_root/tests/smoke/linode/main.tf"; do
  grep -Fq 'rootfs_test_source_archive_prefix = "cloud-compose-${var.cloud_compose_source_ref}"' "$fixture" || \
    fail "$fixture does not select the explicit exact-commit source-archive fixture mode"
done
grep -Fq 'source = "../../../modules/digitalocean"' "$repo_root/tests/smoke/do/main.tf" || \
  fail "DigitalOcean hosted smoke does not keep source-archive mode below the public provider entrypoint"
grep -Fq 'source = "../../../modules/linode"' "$repo_root/tests/smoke/linode/main.tf" || \
  fail "Linode hosted smoke does not keep source-archive mode below the public provider entrypoint"
for example_name in digitalocean linode; do
  example_main="$repo_root/examples/$example_name/main.tf"
  example_variables="$repo_root/examples/$example_name/variables.tf"
  source_ref_block="$(sed -n '/^variable "cloud_compose_source_ref" {/,/^}/p' "$example_variables")"
  source_sha_block="$(sed -n '/^variable "cloud_compose_source_sha256" {/,/^}/p' "$example_variables")"
  if grep -Fq 'default' <<<"$source_ref_block" || grep -Fq 'default' <<<"$source_sha_block"; then
    fail "$example_name runnable example still defaults to an obsolete cloud-compose release"
  fi
  grep -Fq 'releases/download/${var.cloud_compose_source_ref}/cloud-compose-rootfs.tar.gz' "$example_main" || \
    fail "$example_name runnable example does not derive its canonical archive from the required exact release"
  grep -Fq 'rootfs_archive_sha256 = var.cloud_compose_source_sha256' "$example_main" || \
    fail "$example_name runnable example does not require the matching archive checksum"
done
grep -Fq 'run "rejects_rootfs_release_from_another_module_version"' "$linux_runtime_tests" || \
  fail "runnable provider examples lack plan-time module/archive mismatch coverage"
grep -Fq '"$source_ref" != "$checkout_sha"' "$cloud_smoke" || \
  fail "hosted smoke does not bind its downloadable source archive to the checked-out commit"
grep -Fq 'CLOUD_COMPOSE_SOURCE_REF: ${{ github.sha }}' "$cloud_smoke_workflow" || \
  fail "hosted smoke does not select the exact tested merge commit"
grep -Fq 'contents: read' "$cloud_smoke_workflow" || \
  fail "hosted smoke lacks read-only repository permission"
if grep -Fq 'contents: write' "$cloud_smoke_workflow"; then
  fail "untrusted pull-request smoke code has repository write permission"
fi
for cloud_init_template in "$linux_cloud_init" "$gcp_cloud_init"; do
  if grep -Eq '^[[:space:]]*-[[:space:]]*[|>][+-]?[[:space:]]*$' "$cloud_init_template"; then
    fail "$cloud_init_template still embeds a shell program instead of invoking a checked-in file"
  fi
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
