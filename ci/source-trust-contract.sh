#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "source trust contract: $*" >&2
  exit 1
}

debian_installer="$repo_root/rootfs/home/cloud-compose/install-dependencies-debian.sh"
cos_installer="$repo_root/rootfs/home/cloud-compose/install-dependencies-cos.sh"
host_conf="$repo_root/rootfs/home/cloud-compose/host-conf.sh"
installer="$repo_root/rootfs/etc/cloud-compose/libexec/install-rootfs.py"
linux_runtime="$repo_root/modules/linux-vm-runtime/main.tf"
linux_cloud_init="$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml"
gcp_module="$repo_root/modules/gcp/main.tf"
gcp_cloud_init="$repo_root/templates/cloud-init.yml"

grep -Eq '^[[:space:]]+openssl([[:space:]\\]|$)' "$debian_installer" ||
  fail "Debian bootstrap does not install openssl"
grep -Fq 'command -v openssl' "$cos_installer" ||
  fail "COS bootstrap does not require openssl"

dependencies_line="$(grep -nF 'bash /home/cloud-compose/install-dependencies.sh' "$host_conf" | cut -d: -f1)"
managed_runtime_line="$(grep -nF '"$sitectl" host runtime install' "$host_conf" | cut -d: -f1)"
[[ -n "$dependencies_line" && -n "$managed_runtime_line" && "$dependencies_line" -lt "$managed_runtime_line" ]] ||
  fail "verified sitectl installation must follow OS dependency installation"

grep -Fq 'libops/.github/.github/workflows/bump-release.yaml@8dfaf9c854df71d9bbffde48c5676ff07c543c51' \
  "$repo_root/.github/workflows/github-release.yaml" ||
  fail "write-capable release workflow is not pinned"
grep -Eq 'source = "https://github\.com/libops/terraform-cloudrun-v2/archive/[0-9a-f]{40}\.zip//terraform-cloudrun-v2-[0-9a-f]{40}"' \
  "$gcp_module" || fail "GCP Terraform dependency is not pinned to a commit"

for module in "$linux_runtime" "$gcp_module"; do
  grep -Fq 'rootfs_bundle_content = jsonencode({' "$module" ||
    fail "$module does not build the checked rootfs bundle"
  grep -Fq 'base64gzip(local.rootfs_bundle_content)' "$module" ||
    fail "$module does not compress the checked rootfs bundle"
done
for template in "$linux_cloud_init" "$gcp_cloud_init"; do
  grep -Fq '/var/lib/cloud-compose/bootstrap/install-rootfs.py' "$template" ||
    fail "$template does not install the checked rootfs installer"
  grep -Fq '/var/lib/cloud-compose/bootstrap/rootfs.json' "$template" ||
    fail "$template does not install the checked rootfs bundle"
done

grep -Fq 'SAFE_PATH = re.compile' "$installer" ||
  fail "rootfs installer does not constrain paths"
grep -Fq 'if any(part in ("", ".", "..")' "$installer" ||
  fail "rootfs installer does not reject path traversal"
grep -Fq 'stat.S_ISLNK' "$installer" ||
  fail "rootfs installer does not reject symlinks"
grep -Fq 'os.replace(temporary, path)' "$installer" ||
  fail "rootfs installer does not publish files atomically"

archive_variable='rootfs''_archive'
archive_program='rootfs''-archive'
if rg -n -i "${archive_variable}|${archive_program}" "$repo_root" \
  --hidden --glob '!**/.terraform/**' --glob '!**/.git/**' >/dev/null; then
  fail "retired rootfs transport machinery remains"
fi
