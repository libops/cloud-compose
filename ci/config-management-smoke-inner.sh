#!/usr/bin/env bash

set -euo pipefail

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

ansible-playbook \
  -i /work/ansible/inventory.example.yml \
  /work/ansible/playbooks/site.yml \
  --syntax-check

ansible-playbook \
  -i /work/tests/config-management/ansible/inventory.yml \
  /work/tests/config-management/ansible/smoke.yml \
  --syntax-check

ansible-playbook \
  -i /work/tests/config-management/ansible/inventory.yml \
  /work/tests/config-management/ansible/smoke.yml

python - <<'PY'
import json
import os
from pathlib import Path

env = {}
for line in Path("/home/cloud-compose/.env").read_text().splitlines():
    if not line.strip():
        continue
    key, raw = line.split("=", 1)
    env[key] = json.loads(raw)

projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects["isle-prod"]

assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
assert env["DOCKER_COMPOSE_DIR"] == "/opt/isle"
assert env["DOCKER_COMPOSE_REPO"] == "https://github.com/libops/isle"
assert env["SITECTL_PLUGIN"] == "isle"
assert "sitectl-isle" in env["SITECTL_PACKAGES"].split()
assert project["docker_compose_repo"] == "https://github.com/libops/isle"
assert project["project_dir"] == "/opt/isle"
assert project["ingress"]["domain"] == "isle.example.edu"
assert project["sitectl_plugin"] == "isle"
assert Path("/opt/isle").is_dir()

for path in [
    "/home/cloud-compose/init",
    "/home/cloud-compose/up",
    "/home/cloud-compose/down",
    "/home/cloud-compose/rollout",
    "/home/cloud-compose/run.sh",
]:
    assert Path(path).exists(), path
    assert os.access(path, os.X_OK), path
PY

rm -rf /home/cloud-compose /mnt/disks /opt/isle /opt/wp /opt/drupal

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

  rm -rf /home/cloud-compose /mnt/disks /opt/isle /opt/wp /opt/drupal
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

  python -m json.tool /home/cloud-compose/compose-projects.json >/dev/null
  python - "$expected_name" "$expected_repo" "$expected_plugin" "$expected_package" "$expected_domain" "$expected_project_dir" <<'PY'
import json
import os
import sys
from pathlib import Path

expected_name, expected_repo, expected_plugin, expected_package, expected_domain, expected_project_dir = sys.argv[1:]

env = {}
for line in Path("/home/cloud-compose/.env").read_text().splitlines():
    if not line.strip():
        continue
    key, raw = line.split("=", 1)
    env[key] = json.loads(raw)

projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects[expected_name]

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

for path in [
    "/home/cloud-compose/init",
    "/home/cloud-compose/up",
    "/home/cloud-compose/down",
    "/home/cloud-compose/rollout",
    "/home/cloud-compose/run.sh",
]:
    assert Path(path).exists(), path
    assert os.access(path, os.X_OK), path
PY
}

run_salt_case \
  wp-prod \
  wp-prod \
  https://github.com/libops/wp.git \
  wp \
  sitectl-wp \
  wp.example.edu \
  /opt/wp

run_salt_case \
  drupal-prod \
  drupal-prod \
  https://github.com/libops/drupal.git \
  drupal \
  sitectl-drupal \
  drupal.example.edu \
  /opt/drupal
