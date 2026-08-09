#!/usr/bin/env bash

set -euo pipefail

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  systemd-standalone-tmpfiles >/tmp/cloud-compose-apt-install.log

python -m pip install --no-cache-dir \
  ansible-core==2.18.6 \
  salt==3007.1 \
  tornado==6.4.2 \
  looseversion==1.3.0 \
  PyYAML==6.0.2 \
  packaging==24.2 \
  msgpack==1.1.0 \
  distro==1.9.0 \
  Jinja2==3.1.4 >/tmp/cloud-compose-pip-install.log

export ANSIBLE_RETRY_FILES_ENABLED=false
export ANSIBLE_ROLES_PATH=/work/ansible/roles
rm -f \
  /tmp/cloud-compose-ansible-backtick-injection \
  /tmp/cloud-compose-ansible-command-injection \
  /tmp/cloud-compose-salt-backtick-injection \
  /tmp/cloud-compose-salt-command-injection

tamper_adapter_control_ownership() {
  chown cloud-compose:cloud-compose \
    /home/cloud-compose/init \
    /home/cloud-compose/up \
    /home/cloud-compose/down \
    /home/cloud-compose/rollout \
    /home/cloud-compose/.env \
    /home/cloud-compose/application-env.json \
    /home/cloud-compose/compose-projects.json \
    /home/cloud-compose/managed-runtime-artifacts.tsv
  chmod 0777 \
    /home/cloud-compose/init \
    /home/cloud-compose/up \
    /home/cloud-compose/down \
    /home/cloud-compose/rollout
  chmod 0666 \
    /home/cloud-compose/.env \
    /home/cloud-compose/application-env.json \
    /home/cloud-compose/compose-projects.json \
    /home/cloud-compose/managed-runtime-artifacts.tsv
}

verify_lifecycle_lock_contract() {
  local lock_dir=/run/lock/cloud-compose
  local lock_file="$lock_dir/lifecycle.lock"
  local profile=/home/cloud-compose/profile.sh
  local fixture=/work/ci/fixtures/config-management-lifecycle-lock.sh
  local ready=/tmp/cloud-compose-lifecycle-lock-ready
  local holder_pid contention_status passwd_sha

  command -v flock >/dev/null
  command -v runuser >/dev/null
  command -v systemd-tmpfiles >/dev/null
  [[ "$(stat -c '%U:%G:%a' "$lock_dir" "$lock_file")" == \
    $'root:cloud-compose:750\nroot:cloud-compose:660' ]]

  rm -f -- "$ready"
  CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    "$fixture" hold "$profile" "$ready" &
  holder_pid=$!
  for _ in {1..50}; do
    [[ -e "$ready" ]] && break
    sleep 0.1
  done
  [[ -e "$ready" ]]

  set +e
  runuser -u cloud-compose -- env \
    HOME=/home/cloud-compose \
    CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    CLOUD_COMPOSE_LIFECYCLE_LOCK_TIMEOUT_SECONDS=1 \
    "$fixture" contend "$profile" >/dev/null 2>&1
  contention_status=$?
  set -e
  [[ "$contention_status" -ne 0 ]]
  wait "$holder_pid"

  runuser -u cloud-compose -- env \
    HOME=/home/cloud-compose \
    CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    "$fixture" subshell "$profile"

  passwd_sha="$(sha256sum /etc/passwd)"
  mv -- "$lock_file" "${lock_file}.real"
  ln -s /etc/passwd "$lock_file"
  if CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    "$fixture" reject-symlink "$profile" \
      >/dev/null 2>&1; then
    echo "Lifecycle lock accepted a symbolic-link target" >&2
    exit 1
  fi
  [[ "$(sha256sum /etc/passwd)" == "$passwd_sha" ]]
  rm -f -- "$lock_file"
  mv -- "${lock_file}.real" "$lock_file"
}

ansible-playbook \
  -i /work/ansible/inventory.example.yml \
  /work/ansible/playbooks/site.yml \
  --syntax-check

ansible-playbook \
  -i /work/tests/config-management/ansible/inventory.yml \
  /work/tests/config-management/ansible/smoke.yml \
  --syntax-check

ansible_invalid_cases=(
  invalid-env
  invalid-sitectl
  invalid-reserved-env
  invalid-project
  invalid-project-repo
  invalid-project-port
  invalid-ingress-port
  invalid-lifecycle
  invalid-project-lifecycle
  invalid-internal-services
  invalid-primary
  invalid-template
  invalid-vault
  invalid-disaster-recovery
  invalid-package
  invalid-host-ack
  invalid-project-dir-root
  invalid-project-dir-etc
  invalid-project-dir-traversal
  invalid-project-dir-symlink
  invalid-artifacts
)

for invalid_case in "${ansible_invalid_cases[@]}"; do
  ansible-playbook \
    -i /work/tests/config-management/ansible/inventory.yml \
    "/work/tests/config-management/ansible/${invalid_case}.yml" \
    --syntax-check
done

run_invalid_ansible_case() {
  local invalid_case="$1" expected="$2"
  local log="/tmp/cloud-compose-ansible-${invalid_case}.log"
  local root_before etc_before passwd_before group_before

  rm -rf /home/cloud-compose /mnt/disks /tmp/cloud-compose-symlink-target
  if [[ "$invalid_case" == "invalid-project-dir-symlink" ]]; then
    mkdir -p /mnt/disks/data /tmp/cloud-compose-symlink-target
    printf 'must-not-change\n' >/tmp/cloud-compose-symlink-target/sentinel
    ln -s /tmp/cloud-compose-symlink-target /mnt/disks/data/escape
  fi
  root_before="$(stat -c '%u:%g:%a' /)"
  etc_before="$(stat -c '%u:%g:%a' /etc)"
  passwd_before="$(getent passwd cloud-compose || true)"
  group_before="$(getent group cloud-compose || true)"

  if ansible-playbook \
    -i /work/tests/config-management/ansible/inventory.yml \
    "/work/tests/config-management/ansible/${invalid_case}.yml" \
    >"$log" 2>&1; then
    echo "Ansible accepted invalid settings from ${invalid_case}.yml" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$log"; then
    echo "Ansible invalid case ${invalid_case} did not report: ${expected}" >&2
    cat "$log" >&2
    exit 1
  fi
  if [[ "$(stat -c '%u:%g:%a' /)" != "$root_before" ||
    "$(stat -c '%u:%g:%a' /etc)" != "$etc_before" ||
    "$(getent passwd cloud-compose || true)" != "$passwd_before" ||
    "$(getent group cloud-compose || true)" != "$group_before" ||
    -e /home/cloud-compose || -e /mnt/disks/volumes ]]; then
    echo "Ansible invalid case ${invalid_case} mutated host state before rejection" >&2
    cat "$log" >&2
    exit 1
  fi
  if [[ "$invalid_case" == "invalid-project-dir-symlink" ]]; then
    grep -Fxq 'must-not-change' /tmp/cloud-compose-symlink-target/sentinel
    [[ -L /mnt/disks/data/escape ]]
  fi
}

run_invalid_ansible_case invalid-env 'cloud_compose_extra_env names must match'
run_invalid_ansible_case invalid-sitectl 'sitectl.version must be latest or an exact semantic-version release tag'
run_invalid_ansible_case invalid-reserved-env 'must not replace HOME, PATH, or reserved control-plane prefixes'
run_invalid_ansible_case invalid-project 'compose.projects keys must match'
run_invalid_ansible_case invalid-project-repo 'repositories are required'
run_invalid_ansible_case invalid-project-port 'ingress ports must be whole numbers between 1 and 65535'
run_invalid_ansible_case invalid-ingress-port 'compose.ingress_port must be a whole number between 1 and 65535'
run_invalid_ansible_case invalid-lifecycle 'lifecycle commands must be lists of strings'
run_invalid_ansible_case invalid-project-lifecycle 'Lifecycle init, up, down, and rollout commands for every compose project must be lists of strings'
run_invalid_ansible_case invalid-internal-services 'internal-services stack is GCP-specific'
run_invalid_ansible_case invalid-primary 'compose.primary must match'
run_invalid_ansible_case invalid-template 'template must name a supported app'
run_invalid_ansible_case invalid-vault 'Vault Agent is currently supported only by Terraform'
run_invalid_ansible_case invalid-disaster-recovery 'driver_path must be a safe absolute path'
run_invalid_ansible_case invalid-package 'sitectl packages must use valid release package names'
run_invalid_ansible_case invalid-host-ack 'dedicated_host_acknowledged=true'
run_invalid_ansible_case invalid-project-dir-root 'project_dir must be a normalized non-root absolute path'
run_invalid_ansible_case invalid-project-dir-etc 'project_dir must be a non-root descendant of /mnt/disks/data'
run_invalid_ansible_case invalid-project-dir-traversal 'project_dir must be a normalized non-root absolute path'
run_invalid_ansible_case invalid-project-dir-symlink 'project_dir resolves outside the fixed /mnt/disks/data boundary'
run_invalid_ansible_case invalid-artifacts 'name must be a safe basename'

ansible-playbook \
  -i /work/tests/config-management/ansible/inventory.yml \
  /work/tests/config-management/ansible/smoke.yml

# A second adapter apply must repair the root-owned runtime control boundary.
tamper_adapter_control_ownership
rm -rf -- /run/lock/cloud-compose
ansible-playbook \
  -i /work/tests/config-management/ansible/inventory.yml \
  /work/tests/config-management/ansible/smoke.yml

verify_lifecycle_lock_contract

python /work/ci/config-management-smoke-assert.py ansible-runtime

rm -rf /home/cloud-compose /mnt/disks

mkdir -p /tmp/salt/etc /tmp/salt/cache /tmp/salt/pki
write_salt_config() {
  local minion_id="$1"

  cat >/tmp/salt/etc/minion <<MINION
id: ${minion_id}
file_client: local
file_roots:
  base:
    - /work/salt
    - /work
pillar_roots:
  base:
    - /work/tests/config-management/salt-pillar
cachedir: /tmp/salt/cache
pki_dir: /tmp/salt/pki
log_file: /tmp/salt/minion.log
MINION
}

run_salt_case() {
  local minion_id="$1" expected_name="$2" expected_repo="$3" expected_plugin="$4" expected_package="$5" expected_domain="$6" expected_project_dir="$7" expected_compose_project_name="$8"

  rm -rf /home/cloud-compose /mnt/disks
  write_salt_config "$minion_id"

  salt-call \
    --local \
    --retcode-passthrough \
    --config-dir=/tmp/salt/etc \
    state.show_sls cloud-compose >/tmp/cloud-compose-salt-show-sls.txt

  salt-call \
    --local \
    --retcode-passthrough \
    --config-dir=/tmp/salt/etc \
    state.apply cloud-compose

  # Reapplying the formula must repair controls changed by the app user.
  tamper_adapter_control_ownership
  rm -rf -- /run/lock/cloud-compose
  salt-call \
    --local \
    --retcode-passthrough \
    --config-dir=/tmp/salt/etc \
    state.apply cloud-compose

  [[ "$(stat -c '%U:%G:%a' \
    /run/lock/cloud-compose \
    /run/lock/cloud-compose/lifecycle.lock)" == \
    $'root:cloud-compose:750\nroot:cloud-compose:660' ]]

  salt-call \
    --local \
    --retcode-passthrough \
    --config-dir=/tmp/salt/etc \
    --out=json \
    state.apply cloud-compose >/tmp/cloud-compose-salt-noop.json
  python /work/ci/config-management-smoke-assert.py salt-noop

  python -m json.tool /home/cloud-compose/compose-projects.json >/dev/null
  python /work/ci/config-management-smoke-assert.py salt-runtime \
    "$expected_name" \
    "$expected_repo" \
    "$expected_plugin" \
    "$expected_package" \
    "$expected_domain" \
    "$expected_project_dir" \
    "$expected_compose_project_name"
}

run_salt_case \
  wp-prod \
  wp-prod \
  https://github.com/libops/wp.git \
  wp \
  sitectl-wp \
  wp.example.edu \
  /mnt/disks/data/libops/wp.git/wp-prod \
  libops-wp-v1-1-1

run_salt_case \
  drupal-prod \
  drupal-prod \
  https://github.com/libops/drupal.git \
  drupal \
  sitectl-drupal \
  drupal.example.edu \
  /mnt/disks/data/libops/drupal.git/drupal-prod \
  libops-drupal-v1-2-1

run_invalid_salt_case() {
  local invalid_case="$1" expected="$2"
  local log="/tmp/cloud-compose-salt-${invalid_case}.log"
  local root_before etc_before passwd_before group_before

  rm -rf /home/cloud-compose /mnt/disks /tmp/cloud-compose-symlink-target
  if [[ "$invalid_case" == "invalid-project-dir-symlink" ]]; then
    mkdir -p /mnt/disks/data /tmp/cloud-compose-symlink-target
    printf 'must-not-change\n' >/tmp/cloud-compose-symlink-target/sentinel
    ln -s /tmp/cloud-compose-symlink-target /mnt/disks/data/escape
  fi
  root_before="$(stat -c '%u:%g:%a' /)"
  etc_before="$(stat -c '%u:%g:%a' /etc)"
  passwd_before="$(getent passwd cloud-compose || true)"
  group_before="$(getent group cloud-compose || true)"
  write_salt_config "$invalid_case"
  if salt-call \
    --local \
    --retcode-passthrough \
    --config-dir=/tmp/salt/etc \
    state.apply cloud-compose \
    >"$log" 2>&1; then
    echo "Salt accepted invalid settings from ${invalid_case}.sls" >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$log"
  [[ "$(stat -c '%u:%g:%a' /)" == "$root_before" ]]
  [[ "$(stat -c '%u:%g:%a' /etc)" == "$etc_before" ]]
  [[ "$(getent passwd cloud-compose || true)" == "$passwd_before" ]]
  [[ "$(getent group cloud-compose || true)" == "$group_before" ]]
  [[ ! -e /home/cloud-compose ]]
  [[ ! -e /mnt/disks/volumes ]]
  if [[ "$invalid_case" == "invalid-project-dir-symlink" ]]; then
    grep -Fxq 'must-not-change' /tmp/cloud-compose-symlink-target/sentinel
    [[ -L /mnt/disks/data/escape ]]
  fi
}

run_invalid_salt_case invalid-env 'extra_env name must match'
run_invalid_salt_case invalid-sitectl 'sitectl.version must be latest or an exact semantic-version release tag'
run_invalid_salt_case invalid-reserved-env 'reserved host control'
run_invalid_salt_case invalid-project 'compose.projects key must match'
run_invalid_salt_case invalid-project-repo 'docker_compose_repo is required'
run_invalid_salt_case invalid-project-port 'ingress_port must be a whole number between 1 and 65535'
run_invalid_salt_case invalid-ingress-port 'compose.ingress_port must be a whole number between 1 and 65535'
run_invalid_salt_case invalid-lifecycle 'compose.init must be a list of strings'
run_invalid_salt_case invalid-project-lifecycle 'up_commands or docker_compose_up must be a list of strings'
run_invalid_salt_case invalid-internal-services 'internal-services stack is GCP-specific'
run_invalid_salt_case invalid-primary 'compose.primary must match'
run_invalid_salt_case invalid-template 'template must name a supported cloud-compose app'
run_invalid_salt_case invalid-vault 'Vault Agent is currently supported only by Terraform'
run_invalid_salt_case invalid-disaster-recovery 'driver_path must be a safe absolute path'
run_invalid_salt_case invalid-package 'invalid installed package'
run_invalid_salt_case invalid-host-ack 'dedicated_host_acknowledged=true'
run_invalid_salt_case invalid-project-dir-root 'project_dir must be a normalized non-root absolute path'
run_invalid_salt_case invalid-project-dir-etc 'project_dir must be a non-root descendant of /mnt/disks/data'
run_invalid_salt_case invalid-project-dir-traversal 'project_dir must be a normalized non-root absolute path'
run_invalid_salt_case invalid-project-dir-symlink 'project_dir resolves outside the fixed /mnt/disks/data boundary'
run_invalid_salt_case invalid-artifacts 'name must be a safe basename'
