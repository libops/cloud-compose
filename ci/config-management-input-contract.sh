#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/ansible/roles/cloud_compose/files/validate-runtime-inputs.py"
salt_validator="$repo_root/salt/cloud-compose/files/validate-runtime-inputs.py"

cmp -s "$validator" "$salt_validator" || {
  echo "config-management input contract: Ansible and Salt validators diverged" >&2
  exit 1
}

ansible_tasks="$repo_root/ansible/roles/cloud_compose/tasks/main.yml"
salt_state="$repo_root/salt/cloud-compose/init.sls"
rollout_runner="bash /home/cloud-compose/deploy-rollout.sh"

contract_fail() {
  echo "config-management input contract: $1" >&2
  exit 1
}

grep -Fq "cmd: $rollout_runner" "$ansible_tasks" || \
  contract_fail "Ansible rollout does not invoke the hardened rollout program"
grep -Fq 'cmd: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh' "$ansible_tasks" || \
  contract_fail "Ansible does not apply the shared bootstrap path hardener"
grep -Fq -- '- name: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh' "$salt_state" || \
  contract_fail "Salt does not apply the shared bootstrap path hardener"

ansible_sitectl_line="$(grep -n -m1 '/etc/cloud-compose/libexec/bootstrap-sitectl.sh' "$ansible_tasks" | cut -d: -f1)"
ansible_hardener_line="$(grep -n -m1 'cmd: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh' "$ansible_tasks" | cut -d: -f1)"
[[ -n "$ansible_sitectl_line" && "$ansible_sitectl_line" -lt "$ansible_hardener_line" ]] || \
  contract_fail "Ansible does not stage sitectl before invoking sitectl-backed hardening"
grep -Fq -- '--version {{ _cc_sitectl_version | quote }}' "$ansible_tasks" || \
  contract_fail "Ansible does not stage the configured sitectl version"

salt_sitectl_block="$(sed -n '/^cloud-compose-bootstrap-sitectl:/,/^[^[:space:]]/p' "$salt_state")"
grep -Fq -- '--version {{ sitectl_version | json }}' <<<"$salt_sitectl_block" || \
  contract_fail "Salt does not stage the configured sitectl version"
salt_hardener_block="$(sed -n '/^cloud-compose-bootstrap-paths-hardened:/,/^[^[:space:]]/p' "$salt_state")"
grep -Fq -- '- cmd: cloud-compose-bootstrap-sitectl' <<<"$salt_hardener_block" || \
  contract_fail "Salt does not stage sitectl before invoking sitectl-backed hardening"

ansible_privileged_block="$(sed -n '/^- name: Secure Cloud Compose privileged program directories/,/^- name:/p' "$ansible_tasks")"
grep -Fq -- '- "{{ cloud_compose_home }}"' <<<"$ansible_privileged_block" || \
  contract_fail "Ansible does not close the account-owned runtime-home window after installing rootfs"
salt_privileged_block="$(sed -n '/^cloud-compose-privileged-program-directories:/,/^[^[:space:]]/p' "$salt_state")"
grep -Fq -- '- {{ home | json }}' <<<"$salt_privileged_block" || \
  contract_fail "Salt does not close the account-owned runtime-home window after installing rootfs"
ansible_mount_parent_block="$(sed -n '/^- name: Ensure cloud-compose mount parent is root-owned/,/^- name:/p' "$ansible_tasks")"
for marker in 'owner: root' 'group: root' 'mode: "0755"'; do
  grep -Fq -- "$marker" <<<"$ansible_mount_parent_block" || \
    contract_fail "Ansible mount parent is missing $marker"
done
salt_mount_parent_block="$(sed -n '/^cloud-compose-mount-parent:/,/^[^[:space:]]/p' "$salt_state")"
for marker in '- name: /mnt/disks' '- user: root' '- group: root' "- mode: '0755'"; do
  grep -Fq -- "$marker" <<<"$salt_mount_parent_block" || \
    contract_fail "Salt mount parent is missing $marker"
done
salt_rollout_block="$(sed -n '/^cloud-compose-rollout-service:/,/^{% endif %}$/p' "$salt_state")"
[[ -n "$salt_rollout_block" ]] || contract_fail "Salt rollout state is missing"
for marker in \
  "- name: $rollout_runner" \
  '- file: cloud-compose-env' \
  '- file: cloud-compose-application-env' \
  '- file: cloud-compose-project-manifest' \
  '- file: cloud-compose-managed-runtime-artifacts' \
  '- file: cloud-compose-rootfs' \
  '- cmd: cloud-compose-lifecycle-lock' \
  '- cmd: cloud-compose-rootfs-script-modes' \
  '- file: cloud-compose-lifecycle-init' \
  '- file: cloud-compose-lifecycle-up' \
  '- file: cloud-compose-lifecycle-down' \
  '- file: cloud-compose-lifecycle-rollout'; do
  grep -Fq -- "$marker" <<<"$salt_rollout_block" || \
    contract_fail "Salt rollout state is missing $marker"
done


exec python3 "$repo_root/ci/config-management-input-contract.py" "$repo_root" "$validator"
