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
root_program_runner="$repo_root/rootfs/etc/cloud-compose/libexec/run-root-program.sh"
rollout_runner="bash /etc/cloud-compose/libexec/run-root-program.sh deploy-rollout.sh"

contract_fail() {
  echo "config-management input contract: $1" >&2
  exit 1
}

grep -Fq "cmd: $rollout_runner" "$ansible_tasks" || \
  contract_fail "Ansible rollout does not use the trusted root-program runner"
if grep -Fq 'cmd: bash "{{ cloud_compose_home }}/' "$ansible_tasks" || \
  grep -Fq 'cmd: bash /home/cloud-compose/' "$ansible_tasks"; then
  contract_fail "Ansible rollout executes a root program directly from the runtime home"
fi
grep -Fq 'cmd: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh' "$ansible_tasks" || \
  contract_fail "Ansible does not apply the shared bootstrap path hardener"
grep -Fq -- '- name: /etc/cloud-compose/libexec/harden-bootstrap-paths.sh' "$salt_state" || \
  contract_fail "Salt does not apply the shared bootstrap path hardener"

grep -Fq 'configure-metadata-firewall.sh | deploy-rollout.sh | docker-prune.sh' "$root_program_runner" || \
  contract_fail "the trusted root-program runner does not allow deploy-rollout.sh"

salt_rollout_block="$(sed -n '/^cloud-compose-rollout-service:/,/^{% endif %}$/p' "$salt_state")"
[[ -n "$salt_rollout_block" ]] || contract_fail "Salt rollout state is missing"
if grep -Fq -- '- name: bash /home/cloud-compose/' "$salt_state"; then
  contract_fail "Salt rollout executes a root program directly from the runtime home"
fi
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
