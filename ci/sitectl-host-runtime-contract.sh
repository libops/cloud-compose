#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$repo_root/rootfs/home/cloud-compose"
debian_installer="$runtime/install-dependencies-debian.sh"
shell_lines=0
while IFS= read -r -d '' program; do
  lines="$(wc -l <"$program")"
  shell_lines=$((shell_lines + lines))
done < <(find "$repo_root/rootfs" -type f \( -name '*.sh' -o -name '*.bash' \) -print0)
((shell_lines <= 1000)) || {
  echo "rootfs shell budget exceeded: ${shell_lines} lines (maximum 1000)" >&2
  exit 1
}

grep -Fq 'exec sitectl host keys app "${1:-rotate}"' "$runtime/rotate-keys-app.sh"
grep -Fq 'exec sitectl host apps lifecycle "$lifecycle"' "$runtime/lifecycle-entrypoint.sh"
grep -Fq 'exec /etc/cloud-compose/libexec/sitectl-host.sh diagnostics "$@"' \
  "$repo_root/rootfs/etc/cloud-compose/bin/cloud-compose-diagnostics.sh"
grep -Fq '"$sitectl" host apps converge-filesystems' "$runtime/run.sh"
grep -Fq 'run_as_cloud_compose "$managed_sitectl" host apps prepare' "$runtime/run.sh"
grep -Fq 'run_as_cloud_compose "$managed_sitectl" host apps lifecycle init' "$runtime/run.sh"
grep -Fq 'PATH="/home/cloud-compose/bin:$PATH"' "$runtime/run.sh"
grep -Fq '/home/cloud-compose/bin/sitectl --version' "$repo_root/ci/cloud-smoke.sh"
grep -Fq '/home/cloud-compose/bin/sitectl --version' "$repo_root/ci/remote/config-management-verify.sh"
grep -Fq '"$sitectl" host runtime install' "$runtime/host-conf.sh"
grep -Fq 'exec "$sitectl" host "$@"' \
  "$repo_root/rootfs/etc/cloud-compose/libexec/sitectl-host.sh"
grep -Fq 'if ! command -v docker >/dev/null 2>&1; then' "$debian_installer"
grep -Fq 'packages+=(docker.io)' "$debian_installer"
grep -Fq 'retry_until_success apt-get install -y "${packages[@]}"' "$debian_installer"

for retired in \
  app-init.sh \
  app-rollout.sh \
  compose-apps.sh \
  compose-dispatch.sh \
  configure-metadata-firewall.sh \
  converge-app-filesystems.sh \
  default-lifecycle.sh \
  disaster-recovery-lib.sh \
  docker-prune.sh \
  host-init.sh \
  libops-managed-runtime.sh \
  mariadb-backup.sh \
  migrate-legacy-systemd-units.sh \
  mount-overlays.sh \
  offhost-backup.sh \
  prepare-app-sources.sh \
  prepare-filesystem.sh \
  persist-filesystems.sh \
  restore-test.sh \
  rotate-keys-daily.sh \
  rotate-keys-internal.sh \
  run-bootstrap.sh \
  run-rollout-service.sh \
  start-cloud-compose-bootstrap.sh \
  vault-agent-init.sh \
  vault-agent-readiness.sh \
  assert-app-initialized.sh \
  assert-vault-ready.sh \
  rotate-keys.sh; do
  test ! -e "$runtime/$retired" || {
    echo "retired shell implementation still exists: $retired" >&2
    exit 1
  }
done
