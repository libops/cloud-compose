#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "host runtime security: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

profile="$repo_root/rootfs/home/cloud-compose/profile.sh"
hardener="$repo_root/rootfs/etc/cloud-compose/libexec/harden-bootstrap-paths.sh"
installer="$repo_root/rootfs/etc/cloud-compose/libexec/install-rootfs.py"
launcher="$repo_root/rootfs/etc/cloud-compose/libexec/sitectl-host.sh"
diagnostics="$repo_root/rootfs/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"

assert_contains "$profile" 'decode_runtime_env_value() {'
assert_contains "$repo_root/rootfs/home/cloud-compose/host-conf.sh" 'host runtime install'
sitectl_bootstrap="$repo_root/rootfs/etc/cloud-compose/libexec/bootstrap-sitectl.sh"
assert_contains "$sitectl_bootstrap" "sha256sum -c -"
assert_contains "$sitectl_bootstrap" '[[ "$entry" == sitectl ]]'
assert_contains "$sitectl_bootstrap" '[[ "$sitectl_entries" -eq 1 ]]'
assert_contains "$sitectl_bootstrap" 'tar -xzf "$tmp/$archive" -C "$tmp" -- sitectl'
assert_contains "$sitectl_bootstrap" '"regular file:1"'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh" \
  '"$sitectl" host filesystems'
assert_contains "$repo_root/rootfs/home/cloud-compose/install-docker-plugins.sh" 'host docker-plugins'
assert_contains "$launcher" 'source /home/cloud-compose/profile.sh'
assert_contains "$launcher" 'exec "$sitectl" host "$@"'
assert_contains "$diagnostics" 'exec /etc/cloud-compose/libexec/sitectl-host.sh diagnostics "$@"'

assert_contains "$hardener" 'host security secure-runtime'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh" \
  '/etc/cloud-compose/libexec/harden-bootstrap-paths.sh'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh" \
  '/etc/cloud-compose/libexec/harden-bootstrap-paths.sh'

assert_contains "$installer" 'if os.geteuid() != 0'
assert_contains "$installer" 'SAFE_MODES = {"0644", "0755"}'
assert_contains "$installer" 'stat.S_ISLNK(metadata.st_mode)'
assert_contains "$installer" 'os.fsync(output.fileno())'
assert_contains "$installer" 'pwd.getpwnam("cloud-compose")'
assert_contains "$installer" 'os.O_DIRECTORY | os.O_NOFOLLOW'
assert_contains "$installer" 'os.fchown(descriptor, 0, 0)'

for retired in \
  "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" \
  "$repo_root/rootfs/home/cloud-compose/default-lifecycle.sh" \
  "$repo_root/rootfs/home/cloud-compose/rotate-keys.sh" \
  "$repo_root/rootfs/etc/cloud-compose/libexec/rootfs"'-archive.sh'; do
  test ! -e "$retired" || fail "retired privileged runtime remains: $retired"
done
