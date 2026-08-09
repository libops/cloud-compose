#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "host runtime security contract: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

mkdir -p "$tmp/bin"

cat >"$tmp/profile.sh" <<'EOF'
#!/usr/bin/env bash
export CLOUD_COMPOSE_PROVIDER="${TEST_PROVIDER:-}"
EOF

cat >"$tmp/bin/iptables" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${IPTABLES_LOG:?}"
printf '%q ' "$@" >>"$IPTABLES_LOG.calls"
printf '\n' >>"$IPTABLES_LOG.calls"

table=filter
if [[ "$1" == "-t" ]]; then
  table="$2"
  shift 2
fi

if [[ "$1" == "-nL" ]]; then
  [[ "${IPTABLES_DOCKER_USER_MISSING:-false}" != "true" && "$2" == "DOCKER-USER" ]]
  exit
fi

operation="$1"
chain="$2"
shift 2
if [[ "$operation" == "-I" ]]; then
  shift
fi
rule_prefix=""
if [[ "$table" != "filter" ]]; then
  rule_prefix="${table} "
fi
rule="${rule_prefix}${chain} $*"

case "$operation" in
  -C)
    grep -Fxq -- "$rule" "$IPTABLES_LOG"
    ;;
  -I)
    {
      printf '%s\n' "$rule"
      cat "$IPTABLES_LOG"
    } >"${IPTABLES_LOG}.tmp"
    mv -f "${IPTABLES_LOG}.tmp" "$IPTABLES_LOG"
    ;;
  *)
    echo "unexpected fake iptables operation: $operation" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$tmp/bin/iptables"

firewall_script="$repo_root/rootfs/home/cloud-compose/configure-metadata-firewall.sh"
firewall_log="$tmp/iptables.rules"
: >"$firewall_log"
: >"$firewall_log.calls"

for _ in 1 2; do
  TEST_PROVIDER=gcp \
  CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
  IPTABLES_LOG="$firewall_log" \
  PATH="$tmp/bin:$PATH" \
    bash "$firewall_script"
done

expected_rules="$tmp/expected.rules"
cat >"$expected_rules" <<'EOF'
FORWARD -d 169.254.169.254/32 -p udp --dport 53 -j ACCEPT
FORWARD -d 169.254.169.254/32 -p tcp --dport 53 -j ACCEPT
FORWARD -d 169.254.169.254/32 -j DROP
DOCKER-USER -d 169.254.169.254/32 -p udp --dport 53 -j ACCEPT
DOCKER-USER -d 169.254.169.254/32 -p tcp --dport 53 -j ACCEPT
DOCKER-USER -d 169.254.169.254/32 -j DROP
OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254/32 -p tcp --dport 443 -j DROP
OUTPUT -m owner ! --uid-owner 0 -d 169.254.169.254/32 -p tcp --dport 80 -j DROP
mangle PREROUTING -d 169.254.169.254/32 -p udp --dport 53 -j ACCEPT
mangle PREROUTING -d 169.254.169.254/32 -p tcp --dport 53 -j ACCEPT
mangle PREROUTING -d 169.254.169.254/32 -j DROP
EOF
cmp -s "$expected_rules" "$firewall_log" || fail "metadata firewall rules are incomplete or not idempotent"

pre_firewall_log="$tmp/pre-docker.rules"
: >"$pre_firewall_log"
: >"$pre_firewall_log.calls"
TEST_PROVIDER=gcp \
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
IPTABLES_LOG="$pre_firewall_log" \
IPTABLES_DOCKER_USER_MISSING=true \
PATH="$tmp/bin:$PATH" \
  bash "$firewall_script" pre-docker
awk '$1 == "OUTPUT" || $1 == "mangle"' "$expected_rules" | cmp -s - "$pre_firewall_log" || \
  fail "pre-Docker metadata firewall does not protect containers and unprivileged host processes"

calls_before="$(wc -l <"$firewall_log.calls")"
TEST_PROVIDER=linode \
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
IPTABLES_LOG="$firewall_log" \
PATH="$tmp/bin:$PATH" \
  bash "$firewall_script"
calls_after="$(wc -l <"$firewall_log.calls")"
[[ "$calls_before" == "$calls_after" ]] || fail "non-GCP metadata policy invoked iptables"

if TEST_PROVIDER='' CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" IPTABLES_LOG="$firewall_log" PATH="$tmp/bin:$PATH" \
  bash "$firewall_script" >/dev/null 2>&1; then
  fail "metadata policy accepted a missing provider"
fi

if TEST_PROVIDER=gcp CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" IPTABLES_LOG="$firewall_log" \
  IPTABLES_DOCKER_USER_MISSING=true PATH="$tmp/bin:$PATH" bash "$firewall_script" >/dev/null 2>&1; then
  fail "metadata policy accepted a missing DOCKER-USER chain"
fi

host_conf="$repo_root/rootfs/home/cloud-compose/host-conf.sh"
assert_contains "$host_conf" 'systemctl enable --now cloud-compose-metadata-firewall-pre.service'
assert_contains "$host_conf" 'systemctl enable --now cloud-compose-metadata-firewall.service'
docker_restart_line="$(grep -nF 'systemctl restart docker' "$host_conf" | head -n1 | cut -d: -f1)"
early_firewall_line="$(grep -nF 'bash /home/cloud-compose/configure-metadata-firewall.sh' "$host_conf" | head -n1 | cut -d: -f1)"
late_firewall_line="$(grep -nF 'bash /home/cloud-compose/configure-metadata-firewall.sh' "$host_conf" | tail -n1 | cut -d: -f1)"
dependency_line="$(grep -nF 'bash /home/cloud-compose/install-dependencies.sh' "$host_conf" | head -n1 | cut -d: -f1)"
[[ -n "$early_firewall_line" && -n "$docker_restart_line" && -n "$late_firewall_line" &&
  -n "$dependency_line" && "$early_firewall_line" -lt "$dependency_line" &&
  "$dependency_line" -lt "$docker_restart_line" &&
  "$docker_restart_line" -lt "$late_firewall_line" ]] || \
  fail "GCP metadata isolation is not converged before and after Docker bootstrap"
if grep -Eq '8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1' \
  "$host_conf" "$repo_root/rootfs/home/cloud-compose/install-dependencies-cos.sh"; then
  fail "GCP runtime bypasses Compute Engine and private-zone DNS"
fi
if grep -Fq -- '-i docker0' "$host_conf"; then
  fail "metadata policy still depends on docker0"
fi
assert_contains "$repo_root/rootfs/etc/systemd/system/cloud-compose-metadata-firewall.service" 'After=docker.service'
assert_contains "$repo_root/rootfs/etc/systemd/system/cloud-compose-metadata-firewall.service" 'PartOf=docker.service'
assert_contains "$repo_root/rootfs/etc/systemd/system/cloud-compose-metadata-firewall-pre.service" 'Before=docker.service'
assert_contains "$repo_root/rootfs/etc/systemd/system/cloud-compose-metadata-firewall-pre.service" 'WantedBy=multi-user.target'
assert_contains "$repo_root/rootfs/etc/systemd/system/docker.service.d/cloud-compose-metadata-firewall.conf" 'Requires=cloud-compose-metadata-firewall-pre.service'
assert_contains "$repo_root/docs/runtime-contracts.md" 'COS reconstructs `/etc` after networking'

profile_script="$repo_root/rootfs/home/cloud-compose/profile.sh"
assert_contains "$profile_script" 'if ((EUID == 0)); then'
assert_contains "$profile_script" 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
tmpfiles_conf="$repo_root/rootfs/etc/tmpfiles.d/cloud-compose.conf"
assert_contains "$tmpfiles_conf" 'd /run/lock/cloud-compose 0750 root cloud-compose -'
assert_contains "$tmpfiles_conf" 'f /run/lock/cloud-compose/lifecycle.lock 0660 root cloud-compose -'
assert_contains "$tmpfiles_conf" 'd /var/lib/cloud-compose 0755 root root -'
assert_contains "$tmpfiles_conf" 'd /home/cloud-compose 0755 root root -'
host_init="$repo_root/rootfs/home/cloud-compose/host-init.sh"
if grep -Eq 'chown[[:space:]]+-R[[:space:]]+cloud-compose[^[:space:]]*[[:space:]]+/home/cloud-compose' "$host_init"; then
  fail "host initialization gives the app account recursive ownership of root-executed code"
fi
if grep -Eq 'chown[[:space:]]+-R[[:space:]]+cloud-compose[^[:space:]]*[[:space:]]+/mnt/disks' "$host_init"; then
  fail "host initialization recursively changes ownership of persistent data"
fi
assert_contains "$host_init" 'chown root:root /home/cloud-compose'
assert_contains "$host_init" "-exec chown root:root {} +"
assert_contains "$host_init" 'Unsafe Cloud Compose lifecycle dispatcher:'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/bootstrap-security.sh" \
  'Cloud Compose control input is not root-controlled'
assert_contains "$host_init" '/home/cloud-compose/.sitectl \'
assert_contains "$host_init" 'install -d -m 0750 -o cloud-compose -g cloud-compose "$mutable_dir"'
assert_contains "$host_init" 'Managed command directory was not secured by the runtime installer'
if sed -n '/for mutable_dir in/,/done/p' "$host_init" | grep -Fq '/home/cloud-compose/bin'; then
  fail "host initialization leaves the privileged published command directory app-writable"
fi
assert_contains "$host_init" 'install -d -m 1775 -o root -g cloud-compose /mnt/disks/data'
assert_contains "$host_init" 'install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/volumes'
assert_contains "$host_init" 'install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/data/libops'
managed_runtime="$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
assert_contains "$managed_runtime" 'prepare_managed_runtime_directory'
assert_contains "$managed_runtime" 'validate_published_bin_directory'
assert_contains "$managed_runtime" '$STATE_DIR:0755:false'
assert_contains "$managed_runtime" '$PUBLISHED_BIN_DIR:0755:true'
assert_contains "$managed_runtime" 'managed runtime updates must run as root'
assert_contains "$managed_runtime" 'production managed runtime directories require a root updater'
if grep -A12 -F 'source_compose_app_env()' "$repo_root/rootfs/home/cloud-compose/compose-apps.sh" | \
    grep -Eq 'source[[:space:]]+.*COMPOSE_APPS_ENV_DIR'; then
  fail "privileged Compose manifest loading still sources an app-writable shell file"
fi

curl_marker="$tmp/curl.called"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CURL_MARKER:?}"
touch "$CURL_MARKER"
exit 22
EOF
chmod +x "$tmp/bin/curl"

daily_script="$repo_root/rootfs/home/cloud-compose/rotate-keys-daily.sh"
TEST_PROVIDER=linode \
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
CURL_MARKER="$curl_marker" \
PATH="$tmp/bin:$PATH" \
  bash "$daily_script"
[[ ! -e "$curl_marker" ]] || fail "non-GCP rotation contacted a GCP endpoint"

if TEST_PROVIDER='' CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" CURL_MARKER="$curl_marker" PATH="$tmp/bin:$PATH" \
  bash "$daily_script" >/dev/null 2>&1; then
  fail "rotation accepted a missing provider"
fi

rotate_script="$repo_root/rootfs/home/cloud-compose/rotate-keys.sh"
if TEST_PROVIDER=gcp CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" CURL_MARKER="$curl_marker" PATH="$tmp/bin:$PATH" \
  bash "$rotate_script" prepare app@example.invalid test-project "$tmp/credentials.json" >/dev/null 2>&1; then
  fail "rotation masked an unavailable metadata endpoint"
fi

assert_contains "$rotate_script" 'prepare|status|audit|recover|authenticate|ready|commit|rollback|rollback-ready'
assert_contains "$rotate_script" 'ROTATION_DISABLE_GRACE_SECONDS'
assert_contains "$rotate_script" 'https://oauth2.googleapis.com/token'
assert_contains "$rotate_script" 'KEY_OPERATION_RESULT=absent'

run_script="$repo_root/rootfs/home/cloud-compose/run.sh"
assert_contains "$run_script" 'systemctl enable --now cloud-compose-key-rotation.timer'
if grep -Eq 'rotate-keys[^[:space:]]*\.sh[[:space:]]*\|\|[[:space:]]*true' "$run_script"; then
  fail "GCP key-rotation failures are still masked during bootstrap"
fi
if grep -Fq 'rotate-keys' "$repo_root/rootfs/home/cloud-compose/docker-prune.sh"; then
  fail "provider-neutral Docker prune still invokes GCP key rotation"
fi

archive_source="$repo_root/rootfs/etc/cloud-compose/libexec/rootfs-archive.sh"
verify_line="$(grep -n 'sha256sum -c -' "$archive_source" | head -n 1 | cut -d: -f1)"
members_line="$(grep -n 'validate_rootfs_archive "\$stage_root/rootfs.tar.gz"' "$archive_source" | head -n 1 | cut -d: -f1)"
extract_line="$(grep -n 'tar --no-same-owner --same-permissions -xzf "\$stage_root/rootfs.tar.gz"' "$archive_source" | head -n 1 | cut -d: -f1)"
contract_line="$(grep -n 'rootfs archive paths, bytes, or canonical metadata do not match this cloud-compose module source' "$archive_source" | head -n 1 | cut -d: -f1)"
copy_line="$(grep -n 'cp -a "\$staged_rootfs"/. /' "$archive_source" | head -n 1 | cut -d: -f1)"
[[ -n "$verify_line" && -n "$members_line" && -n "$extract_line" && -n "$contract_line" && -n "$copy_line" &&
  "$verify_line" -lt "$members_line" && "$members_line" -lt "$extract_line" &&
  "$extract_line" -lt "$contract_line" && "$contract_line" -lt "$copy_line" ]] || \
  fail "$archive_source does not verify archive bytes and canonical rootfs metadata before installation"
assert_contains "$archive_source" "stat -c '%a:%h:%F'"
assert_contains "$archive_source" '[[ "$metadata" == "${expected_mode}:1:regular file" ]]'
assert_contains "$archive_source" '[[ "$require_root_owner" != "true" || "$owner" == "0:0" ]]'

if [[ -n "$(git -C "$repo_root" ls-files 'rootfs/usr/**')" ]]; then
  fail "Cloud Compose-owned rootfs programs still target immutable /usr"
fi
for trusted_program in \
  rootfs/etc/cloud-compose/bin/cloud-compose-diagnostics.sh \
  rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh \
  rootfs/etc/cloud-compose/libexec/gcp-cloud-init-post-bootstrap.sh \
  rootfs/etc/cloud-compose/libexec/gcp-filesystem-boot.sh \
  rootfs/etc/cloud-compose/libexec/harden-bootstrap-paths.sh \
  rootfs/etc/cloud-compose/libexec/build-cos-make.sh \
  rootfs/etc/cloud-compose/libexec/bootstrap-security.sh \
  rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh \
  rootfs/etc/cloud-compose/libexec/rootfs-archive.sh \
  rootfs/etc/cloud-compose/libexec/run-lifecycle-program.sh \
  rootfs/etc/cloud-compose/libexec/run-bootstrap.sh \
  rootfs/etc/cloud-compose/libexec/run-root-program.sh \
  rootfs/etc/cloud-compose/jq/offhost-validate-manifest.jq \
  rootfs/etc/cloud-compose/jq/sitectl-verify-args.jq; do
  [[ -f "$repo_root/$trusted_program" ]] || fail "COS-safe trusted program is missing: $trusted_program"
done

assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh" \
  '/etc/cloud-compose/libexec/harden-bootstrap-paths.sh'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh" \
  '/etc/cloud-compose/libexec/harden-bootstrap-paths.sh'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/harden-bootstrap-paths.sh" \
  'chown root:root "$cloud_compose_home"'
assert_contains "$repo_root/rootfs/etc/cloud-compose/libexec/harden-bootstrap-paths.sh" \
  "0:1:regular file"
for cloud_init_program in \
  "$repo_root/rootfs/etc/cloud-compose/libexec/gcp-cloud-init-finalize.sh" \
  "$repo_root/rootfs/etc/cloud-compose/libexec/linux-vm-cloud-init.sh"; do
  assert_contains "$cloud_init_program" 'install-diagnostics "$diagnostics_sha256"'
  if grep -Eq 'install -d[^#]* /usr/local' "$cloud_init_program"; then
    fail "$cloud_init_program writes Cloud Compose-owned programs beneath immutable /usr"
  fi
done

for variables_file in \
  "$repo_root/variables.tf" \
  "$repo_root/modules/digitalocean/variables.tf" \
  "$repo_root/modules/linode/variables.tf" \
  "$repo_root/providers/gcp/variables.tf" \
  "$repo_root/providers/do/variables.tf" \
  "$repo_root/providers/linode/variables.tf"; do
  assert_contains "$variables_file" 'runtime.rootfs_archive_url and a 64-character runtime.rootfs_archive_sha256 must be supplied together.'
done

gcp_module="$repo_root/modules/gcp/main.tf"
assert_contains "$gcp_module" 'internal_services_enabled          = var.libops_internal_services_enabled || var.power_management_enabled'
assert_contains "$gcp_module" 'count      = local.internal_services_enabled ? 1 : 0'
assert_contains "$gcp_module" 'count = var.power_management_enabled ? 1 : 0'
assert_contains "$repo_root/modules/gcp/outputs.tf" '} : null'
assert_contains "$daily_script" 'case "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" in'
assert_contains "$daily_script" 'true) bash "$script_dir/rotate-keys-internal.sh" ;;'
assert_contains "$daily_script" 'bash "$script_dir/rotate-keys-app.sh"'
assert_contains "$repo_root/rootfs/home/cloud-compose/run.sh" 'runtime_enabled "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}"'
assert_contains "$repo_root/rootfs/home/cloud-compose/run.sh" 'systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service'

managed_services_dir="$tmp/internal-services"
managed_services_log="$tmp/internal-services.log"
mkdir -p "$managed_services_dir"
: >"$managed_services_dir/docker-compose.yaml"
: >"$managed_services_log"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${MANAGED_SERVICES_LOG:?}"
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"${MANAGED_SERVICES_LOG:?}"
if [[ "${1:-}" == "is-active" ]]; then
  [[ "${MANAGED_SERVICE_ACTIVE:-false}" == "true" ]]
fi
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/systemctl"

(
  export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
  export LIBOPS_INTERNAL_SERVICES_DIR="$managed_services_dir"
  export LIBOPS_INTERNAL_SERVICES_ENABLED=false
  export LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE=true
  export MANAGED_SERVICES_LOG="$managed_services_log"
  export PATH="$tmp/bin:$PATH"
  # shellcheck disable=SC1090
  source "$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
  retry_until_success() { "$@"; }
  update_internal_services
)
[[ ! -s "$managed_services_log" ]] || fail "disabled internal services invoked Docker or systemd during auto-update"

(
  export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
  export LIBOPS_INTERNAL_SERVICES_DIR="$managed_services_dir"
  export LIBOPS_INTERNAL_SERVICES_ENABLED=true
  export LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE=true
  export MANAGED_SERVICES_LOG="$managed_services_log"
  export PATH="$tmp/bin:$PATH"
  # shellcheck disable=SC1090
  source "$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
  retry_until_success() { "$@"; }
  update_internal_services
)
grep -Fq 'docker compose pull' "$managed_services_log" || fail "enabled internal service update did not pull"
if grep -Eq 'docker compose up|systemctl restart' "$managed_services_log"; then
  fail "auto-update started or restarted inactive internal services"
fi

: >"$managed_services_log"
(
  export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
  export LIBOPS_INTERNAL_SERVICES_DIR="$managed_services_dir"
  export LIBOPS_INTERNAL_SERVICES_ENABLED=true
  export LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE=true
  export MANAGED_SERVICE_ACTIVE=true
  export MANAGED_SERVICES_LOG="$managed_services_log"
  export PATH="$tmp/bin:$PATH"
  # shellcheck disable=SC1090
  source "$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
  retry_until_success() { "$@"; }
  update_internal_services
)
grep -Fq 'docker compose pull' "$managed_services_log" || fail "active internal service update did not pull"
grep -Fq 'systemctl restart cloud-compose-internal-services.service' "$managed_services_log" || \
  fail "active internal service update did not restart its existing unit"

echo "Host runtime security contracts passed"
