#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bash "$script_dir/package-rootfs.sh" "$tmp/one"
bash "$script_dir/package-rootfs.sh" "$tmp/two"
cmp "$tmp/one/cloud-compose-rootfs.tar.gz" "$tmp/two/cloud-compose-rootfs.tar.gz"
cmp "$tmp/one/cloud-compose-rootfs.tar.gz.sha256" "$tmp/two/cloud-compose-rootfs.tar.gz.sha256"
cmp "$tmp/one/cloud-compose-rootfs.contract.sha256" "$tmp/two/cloud-compose-rootfs.contract.sha256"
(
    cd "$tmp/one"
    sha256sum -c cloud-compose-rootfs.tar.gz.sha256
)
contract_sha256="$(<"$tmp/one/cloud-compose-rootfs.contract.sha256")"
[[ "$contract_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Rootfs contract sidecar is not one lowercase SHA-256 digest" >&2
    exit 1
}
mkdir "$tmp/extracted"
tar -xzf "$tmp/one/cloud-compose-rootfs.tar.gz" -C "$tmp/extracted"
actual_contract_sha256="$(
    bash "$script_dir/../rootfs/etc/cloud-compose/libexec/rootfs-archive.sh" \
        contract "$tmp/extracted/rootfs"
)"
[[ "$actual_contract_sha256" == "$contract_sha256" ]] || {
    echo "Rootfs contract sidecar does not match the packaged rootfs" >&2
    exit 1
}
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    awk -f "$script_dir/rootfs-archive-path-contract.awk"
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/home/cloud-compose/run.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/home/cloud-compose/default-lifecycle.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/home/cloud-compose/lifecycle-entrypoint.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/jq/sitectl-verify-args.jq' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/jq/compose-validate-projects.jq' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/jq/rotation-validate-state.jq' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/awk/reconcile-fstab.awk' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/awk/release-checksum.awk' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/awk/compose-secret-files.awk' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/etc/cloud-compose/libexec/checked-programs.bash' >/dev/null
for bootstrap_program in \
    gcp-cloud-init-finalize.sh \
    gcp-cloud-init-post-bootstrap.sh \
    gcp-filesystem-boot.sh \
    linux-vm-cloud-init.sh \
    rootfs-archive.sh \
    run-lifecycle-program.sh; do
    tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
        grep -Fx "rootfs/etc/cloud-compose/libexec/$bootstrap_program" >/dev/null
done
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/libexec/run-bootstrap.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/libexec/run-root-program.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/libexec/build-cos-make.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/libexec/harden-bootstrap-paths.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/jq/offhost-validate-manifest.jq' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/etc/cloud-compose/bin/cloud-compose-diagnostics.sh' >/dev/null
if tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -E '^rootfs/usr/' >/dev/null; then
    echo "Rootfs package contains a Cloud Compose-owned immutable /usr path" >&2
    exit 1
fi

echo "Rootfs package contract passed"
