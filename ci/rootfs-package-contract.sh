#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bash "$script_dir/package-rootfs.sh" "$tmp/one"
bash "$script_dir/package-rootfs.sh" "$tmp/two"
cmp "$tmp/one/cloud-compose-rootfs.tar.gz" "$tmp/two/cloud-compose-rootfs.tar.gz"
cmp "$tmp/one/cloud-compose-rootfs.tar.gz.sha256" "$tmp/two/cloud-compose-rootfs.tar.gz.sha256"
(
    cd "$tmp/one"
    sha256sum -c cloud-compose-rootfs.tar.gz.sha256
)
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | awk '
    $0 !~ /^rootfs\// { bad = 1 }
    /(^|\/)\.\.($|\/)/ { bad = 1 }
    END { exit bad }
'
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | grep -Fx 'rootfs/home/cloud-compose/run.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/usr/local/libexec/cloud-compose/run-bootstrap.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/usr/local/libexec/cloud-compose/run-root-program.sh' >/dev/null
tar -tzf "$tmp/one/cloud-compose-rootfs.tar.gz" | \
    grep -Fx 'rootfs/usr/local/share/cloud-compose/jq/offhost-validate-manifest.jq' >/dev/null

echo "Rootfs package contract passed"
