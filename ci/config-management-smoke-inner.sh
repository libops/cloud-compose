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
  local ready=/tmp/cloud-compose-lifecycle-lock-ready
  local holder_pid contention_status passwd_sha

  command -v flock >/dev/null
  command -v runuser >/dev/null
  command -v systemd-tmpfiles >/dev/null
  [[ "$(stat -c '%U:%G:%a' "$lock_dir" "$lock_file")" == \
    $'root:cloud-compose:750\nroot:cloud-compose:660' ]]

  rm -f -- "$ready"
  CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    bash -c '
      set -euo pipefail
      source "$1"
      acquire_cloud_compose_lifecycle_lock root-first-contract
      touch "$2"
      sleep 3
      release_cloud_compose_lifecycle_lock
    ' _ "$profile" "$ready" &
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
    bash -c '
      source "$1"
      acquire_cloud_compose_lifecycle_lock contention-contract
    ' _ "$profile" >/dev/null 2>&1
  contention_status=$?
  set -e
  [[ "$contention_status" -ne 0 ]]
  wait "$holder_pid"

  runuser -u cloud-compose -- env \
    HOME=/home/cloud-compose \
    CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    bash -c '
      set -euo pipefail
      source "$1"
      (
        acquire_cloud_compose_lifecycle_lock subshell-contract
        release_cloud_compose_lifecycle_lock
      )
    ' _ "$profile"

  passwd_sha="$(sha256sum /etc/passwd)"
  mv -- "$lock_file" "${lock_file}.real"
  ln -s /etc/passwd "$lock_file"
  if CLOUD_COMPOSE_ENV_FILE=/home/cloud-compose/.env \
    bash -c 'source "$1"; acquire_cloud_compose_lifecycle_lock symlink-contract' _ "$profile" \
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

python - <<'PY'
import json
import grp
import os
import stat
import subprocess
from pathlib import Path

def load_runtime_env(path):
    result = subprocess.run(
        [
            "env", "-i", "PATH=/usr/bin:/bin", f"CLOUD_COMPOSE_ENV_FILE={path}",
            "bash", "--noprofile", "--norc", "-c",
            "source /home/cloud-compose/profile.sh; env -0",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        entry.split(b"=", 1)[0].decode(): entry.split(b"=", 1)[1].decode()
        for entry in result.stdout.split(b"\0") if b"=" in entry
    }

env = load_runtime_env(Path("/home/cloud-compose/.env"))
application_env = json.loads(Path("/home/cloud-compose/application-env.json").read_text())

projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects["isle-prod"]

assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
assert env["DOCKER_COMPOSE_DIR"] == "/mnt/disks/data/libops/isle/main"
assert env["DOCKER_COMPOSE_REPO"] == "https://github.com/libops/isle"
assert env["SITECTL_PLUGIN"] == "isle"
assert "sitectl-isle" in env["SITECTL_PACKAGES"].split()
assert json.loads(env["SITECTL_PACKAGE_VERSIONS"]) == {
    "sitectl": "v0.39.0",
    "sitectl-drupal": "v0.11.0",
    "sitectl-isle": "v0.12.0",
}
assert project["docker_compose_repo"] == "https://github.com/libops/isle"
assert project["project_dir"] == "/mnt/disks/data/libops/isle/main"
assert project["ingress"]["domain"] == "isle.example.edu"
assert project["sitectl_plugin"] == "isle"
assert project["init_commands"] == []
assert project["up_commands"] == []
assert project["down_commands"] == ["app-down-command"]
assert project["rollout_commands"] == ["global-rollout-command"]
assert Path("/mnt/disks/data/libops/isle/main").is_dir()
assert "BASH_ENV" not in env
assert "LD_PRELOAD" not in env
assert "PORT" not in env
assert application_env["BASH_ENV"] == "/tmp/cloud-compose-ansible-untrusted-bash-env"
assert application_env["LD_PRELOAD"] == "/tmp/cloud-compose-ansible-untrusted-preload.so"
assert application_env["PORT"] == "9999"
assert application_env["CONTRACT_BACKTICKS"] == "`touch /tmp/cloud-compose-ansible-backtick-injection`"
assert application_env["CONTRACT_BACKSLASH"] == "a\\path\\ends\\"
assert application_env["CONTRACT_COMMAND_SUB"] == "$(touch /tmp/cloud-compose-ansible-command-injection)"
assert application_env["CONTRACT_DOLLARS"] == "$HOME ${HOME}"
assert application_env["CONTRACT_QUOTES"] == 'a "double" and a single quote: O\'Reilly'
assert application_env["CONTRACT_WHITESPACE"] == "  leading and trailing  "
assert application_env["CONTRACT_MULTILINE"] == "line one\nline two"
assert not Path("/tmp/cloud-compose-ansible-backtick-injection").exists()
assert not Path("/tmp/cloud-compose-ansible-command-injection").exists()

for path in [
    "/home/cloud-compose/init",
    "/home/cloud-compose/up",
    "/home/cloud-compose/down",
    "/home/cloud-compose/rollout",
    "/home/cloud-compose/run.sh",
]:
    assert Path(path).exists(), path
    assert os.access(path, os.X_OK), path

cloud_compose_gid = grp.getgrnam("cloud-compose").gr_gid
for path, expected_mode in {
    "/home/cloud-compose/init": 0o750,
    "/home/cloud-compose/up": 0o750,
    "/home/cloud-compose/down": 0o750,
    "/home/cloud-compose/rollout": 0o750,
    "/home/cloud-compose/.env": 0o640,
    "/home/cloud-compose/application-env.json": 0o640,
    "/home/cloud-compose/compose-projects.json": 0o640,
    "/home/cloud-compose/managed-runtime-artifacts.tsv": 0o640,
}.items():
    metadata = Path(path).stat()
    assert metadata.st_uid == 0, (path, metadata.st_uid)
    assert metadata.st_gid == cloud_compose_gid, (path, metadata.st_gid)
    assert stat.S_IMODE(metadata.st_mode) == expected_mode, (path, oct(stat.S_IMODE(metadata.st_mode)))
PY

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
  local minion_id="$1" expected_name="$2" expected_repo="$3" expected_plugin="$4" expected_package="$5" expected_domain="$6" expected_project_dir="$7"

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
  python - <<'PY'
import json
from pathlib import Path

states = json.loads(Path("/tmp/cloud-compose-salt-noop.json").read_text())["local"]
lock_states = [
    state for state_id, state in states.items()
    if "|-cloud-compose-lifecycle-lock_|-" in state_id
]
assert len(lock_states) == 1, lock_states
assert lock_states[0]["result"] is True, lock_states[0]
assert lock_states[0]["changes"] == {}, lock_states[0]
PY

  python -m json.tool /home/cloud-compose/compose-projects.json >/dev/null
  python - "$expected_name" "$expected_repo" "$expected_plugin" "$expected_package" "$expected_domain" "$expected_project_dir" <<'PY'
import json
import grp
import os
import stat
import subprocess
import sys
from pathlib import Path

expected_name, expected_repo, expected_plugin, expected_package, expected_domain, expected_project_dir = sys.argv[1:]

def load_runtime_env(path):
    result = subprocess.run(
        [
            "env", "-i", "PATH=/usr/bin:/bin", f"CLOUD_COMPOSE_ENV_FILE={path}",
            "bash", "--noprofile", "--norc", "-c",
            "source /home/cloud-compose/profile.sh; env -0",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        entry.split(b"=", 1)[0].decode(): entry.split(b"=", 1)[1].decode()
        for entry in result.stdout.split(b"\0") if b"=" in entry
    }

env = load_runtime_env(Path("/home/cloud-compose/.env"))
application_env = json.loads(Path("/home/cloud-compose/application-env.json").read_text())

projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects[expected_name]
artifact_manifest = Path("/home/cloud-compose/managed-runtime-artifacts.tsv").read_text()

assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
assert env["CLOUD_COMPOSE_APPS"] == expected_name
assert env["CLOUD_COMPOSE_PRIMARY_APP"] == expected_name
assert env["DOCKER_COMPOSE_DIR"] == expected_project_dir
assert env["DOCKER_COMPOSE_REPO"] == expected_repo
assert env["SITECTL_PLUGIN"] == expected_plugin
assert expected_package in env["SITECTL_PACKAGES"].split()
assert project["docker_compose_repo"] == expected_repo
assert project["project_dir"] == expected_project_dir
assert project["sitectl_plugin"] == expected_plugin
assert project["ingress"]["domain"] == expected_domain
assert Path(expected_project_dir).is_dir()

if expected_name == "wp-prod":
    assert json.loads(env["SITECTL_PACKAGE_VERSIONS"]) == {
        "sitectl": "v0.39.0",
        "sitectl-wp": "v0.10.0",
    }
    assert "BASH_ENV" not in env
    assert "LD_PRELOAD" not in env
    assert "PORT" not in env
    assert application_env["BASH_ENV"] == "/tmp/cloud-compose-salt-untrusted-bash-env"
    assert application_env["LD_PRELOAD"] == "/tmp/cloud-compose-salt-untrusted-preload.so"
    assert application_env["PORT"] == "9999"
    assert application_env["CONTRACT_BACKTICKS"] == "`touch /tmp/cloud-compose-salt-backtick-injection`"
    assert application_env["CONTRACT_BACKSLASH"] == "a\\path\\ends\\"
    assert application_env["CONTRACT_COMMAND_SUB"] == "$(touch /tmp/cloud-compose-salt-command-injection)"
    assert application_env["CONTRACT_DOLLARS"] == "$HOME ${HOME}"
    assert application_env["CONTRACT_QUOTES"] == 'a "double" and a single quote: O\'Reilly'
    assert application_env["CONTRACT_WHITESPACE"] == "  leading and trailing  "
    assert application_env["CONTRACT_MULTILINE"] == "line one\nline two"
    assert env["LIBOPS_MANAGED_RUNTIME_ENABLED"] == "false"
    assert env["LIBOPS_INTERNAL_SERVICES_ENABLED"] == "false"
    assert env["LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE"] == "false"
    assert project["init_commands"] == []
    assert project["up_commands"] == []
    assert project["down_commands"] == ["app-down-command"]
    assert project["rollout_commands"] == ["global-rollout-command"]
    assert "contract-agent\thttps://example.invalid/contract-agent\t" in artifact_manifest
    assert "\t/usr/local/bin/contract-agent\t0750\troot\troot\tcloud-compose.service" in artifact_manifest
    assert not Path("/tmp/cloud-compose-salt-backtick-injection").exists()
    assert not Path("/tmp/cloud-compose-salt-command-injection").exists()

for path in [
    "/home/cloud-compose/init",
    "/home/cloud-compose/up",
    "/home/cloud-compose/down",
    "/home/cloud-compose/rollout",
    "/home/cloud-compose/run.sh",
]:
    assert Path(path).exists(), path
    assert os.access(path, os.X_OK), path

cloud_compose_gid = grp.getgrnam("cloud-compose").gr_gid
for path, expected_mode in {
    "/home/cloud-compose/init": 0o750,
    "/home/cloud-compose/up": 0o750,
    "/home/cloud-compose/down": 0o750,
    "/home/cloud-compose/rollout": 0o750,
    "/home/cloud-compose/.env": 0o640,
    "/home/cloud-compose/application-env.json": 0o640,
    "/home/cloud-compose/compose-projects.json": 0o640,
    "/home/cloud-compose/managed-runtime-artifacts.tsv": 0o640,
}.items():
    metadata = Path(path).stat()
    assert metadata.st_uid == 0, (path, metadata.st_uid)
    assert metadata.st_gid == cloud_compose_gid, (path, metadata.st_gid)
    assert stat.S_IMODE(metadata.st_mode) == expected_mode, (path, oct(stat.S_IMODE(metadata.st_mode)))
PY
}

run_salt_case \
  wp-prod \
  wp-prod \
  https://github.com/libops/wp.git \
  wp \
  sitectl-wp \
  wp.example.edu \
  /mnt/disks/data/libops/wp/main

run_salt_case \
  drupal-prod \
  drupal-prod \
  https://github.com/libops/drupal.git \
  drupal \
  sitectl-drupal \
  drupal.example.edu \
  /mnt/disks/data/libops/drupal/main

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
run_invalid_salt_case invalid-package 'invalid installed package'
run_invalid_salt_case invalid-host-ack 'dedicated_host_acknowledged=true'
run_invalid_salt_case invalid-project-dir-root 'project_dir must be a normalized non-root absolute path'
run_invalid_salt_case invalid-project-dir-etc 'project_dir must be a non-root descendant of /mnt/disks/data'
run_invalid_salt_case invalid-project-dir-traversal 'project_dir must be a normalized non-root absolute path'
run_invalid_salt_case invalid-project-dir-symlink 'project_dir resolves outside the fixed /mnt/disks/data boundary'
run_invalid_salt_case invalid-artifacts 'name must be a safe basename'
