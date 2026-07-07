#!/usr/bin/env bash

set -euo pipefail

: "${SMOKE_METHOD:?}"
: "${SMOKE_HOST:?}"
: "${SMOKE_SSH_KEY_B64:?}"
: "${SMOKE_NAME:?}"
: "${SMOKE_TEMPLATE:?}"
: "${SMOKE_ENVIRONMENT:?}"
: "${SMOKE_PROJECT_DIR:?}"
: "${SMOKE_HEALTHCHECK_TIMEOUT:?}"
: "${SMOKE_HEALTHCHECK_INTERVAL:?}"

apt-get update >/tmp/cloud-compose-apt-update.log
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  openssh-client \
  tar >/tmp/cloud-compose-apt-install.log

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

install -d -m 0700 /tmp/cloud-compose-ssh
printf '%s' "$SMOKE_SSH_KEY_B64" | base64 -d >/tmp/cloud-compose-ssh/id_ed25519
chmod 0600 /tmp/cloud-compose-ssh/id_ed25519
touch /tmp/cloud-compose-ssh/known_hosts
chmod 0600 /tmp/cloud-compose-ssh/known_hosts
ssh-keyscan -H "$SMOKE_HOST" >>/tmp/cloud-compose-ssh/known_hosts 2>/dev/null

ssh_target="root@${SMOKE_HOST}"
ssh_opts=(
  -i /tmp/cloud-compose-ssh/id_ed25519
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/tmp/cloud-compose-ssh/known_hosts
)

deploy_ansible() {
  export ANSIBLE_RETRY_FILES_ENABLED=false
  export ANSIBLE_ROLES_PATH=/work/ansible/roles

  cat >/tmp/cloud-compose-ansible-inventory.yml <<EOF
all:
  children:
    cloud_compose:
      hosts:
        raw-linode:
          ansible_host: ${SMOKE_HOST}
          ansible_user: root
          ansible_ssh_private_key_file: /tmp/cloud-compose-ssh/id_ed25519
          ansible_ssh_common_args: "-o UserKnownHostsFile=/tmp/cloud-compose-ssh/known_hosts -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
          cloud_compose_name: ${SMOKE_NAME}
          cloud_compose_template: ${SMOKE_TEMPLATE}
          cloud_compose_runtime:
            compose:
              ingress_port: 80
              project_dir: ${SMOKE_PROJECT_DIR}
            sitectl:
              environment: ${SMOKE_ENVIRONMENT}
              healthcheck_timeout: ${SMOKE_HEALTHCHECK_TIMEOUT}
              healthcheck_interval: ${SMOKE_HEALTHCHECK_INTERVAL}
EOF

  ansible-playbook \
    -i /tmp/cloud-compose-ansible-inventory.yml \
    /work/ansible/playbooks/site.yml
}

deploy_salt() {
  tar -C /work \
    --exclude="./.git" \
    --exclude="./.terraform" \
    --exclude="./docs/site" \
    -czf - . |
    ssh "${ssh_opts[@]}" "$ssh_target" \
      "rm -rf /srv/cloud-compose && mkdir -p /srv/cloud-compose && tar -xzf - -C /srv/cloud-compose"

  ssh "${ssh_opts[@]}" "$ssh_target" \
    "SMOKE_NAME=${SMOKE_NAME} SMOKE_TEMPLATE=${SMOKE_TEMPLATE} SMOKE_ENVIRONMENT=${SMOKE_ENVIRONMENT} SMOKE_PROJECT_DIR=${SMOKE_PROJECT_DIR} SMOKE_HEALTHCHECK_TIMEOUT=${SMOKE_HEALTHCHECK_TIMEOUT} SMOKE_HEALTHCHECK_INTERVAL=${SMOKE_HEALTHCHECK_INTERVAL} bash -s" <<'REMOTE'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends python3-venv ca-certificates

python3 -m venv /opt/cloud-compose-salt-smoke
/opt/cloud-compose-salt-smoke/bin/python -m pip install --no-cache-dir \
  salt==3007.1 \
  tornado==6.4.2 \
  looseversion==1.3.0 \
  PyYAML==6.0.2 \
  packaging==24.2 \
  msgpack==1.1.0 \
  distro==1.9.0 \
  Jinja2==3.1.4

mkdir -p /tmp/cloud-compose-salt/etc /tmp/cloud-compose-salt/cache /tmp/cloud-compose-salt/pki /srv/cloud-compose/.smoke-pillar
cat >/tmp/cloud-compose-salt/etc/minion <<EOF
id: ${SMOKE_NAME}
file_client: local
file_roots:
  base:
    - /srv/cloud-compose/salt
    - /srv/cloud-compose
pillar_roots:
  base:
    - /srv/cloud-compose/.smoke-pillar
cachedir: /tmp/cloud-compose-salt/cache
pki_dir: /tmp/cloud-compose-salt/pki
log_file: /tmp/cloud-compose-salt/minion.log
EOF

cat >/srv/cloud-compose/.smoke-pillar/top.sls <<EOF
base:
  '${SMOKE_NAME}':
    - cloud-compose
EOF

cat >/srv/cloud-compose/.smoke-pillar/cloud-compose.sls <<EOF
cloud_compose:
  name: ${SMOKE_NAME}
  provider: onprem
  template: ${SMOKE_TEMPLATE}
  runtime:
    compose:
      ingress_port: 80
      project_dir: ${SMOKE_PROJECT_DIR}
    sitectl:
      environment: ${SMOKE_ENVIRONMENT}
      healthcheck_timeout: ${SMOKE_HEALTHCHECK_TIMEOUT}
      healthcheck_interval: ${SMOKE_HEALTHCHECK_INTERVAL}
EOF

/opt/cloud-compose-salt-smoke/bin/salt-call \
  --local \
  --retcode-passthrough \
  --config-dir=/tmp/cloud-compose-salt/etc \
  state.show_sls cloud-compose >/tmp/cloud-compose-salt-show-sls.txt

/opt/cloud-compose-salt-smoke/bin/salt-call \
  --local \
  --retcode-passthrough \
  --config-dir=/tmp/cloud-compose-salt/etc \
  state.apply cloud-compose
REMOTE
}

verify_remote() {
  ssh "${ssh_opts[@]}" "$ssh_target" \
    "SMOKE_NAME=${SMOKE_NAME} SMOKE_TEMPLATE=${SMOKE_TEMPLATE} SMOKE_ENVIRONMENT=${SMOKE_ENVIRONMENT} SMOKE_PROJECT_DIR=${SMOKE_PROJECT_DIR} SMOKE_HEALTHCHECK_TIMEOUT=${SMOKE_HEALTHCHECK_TIMEOUT} SMOKE_HEALTHCHECK_INTERVAL=${SMOKE_HEALTHCHECK_INTERVAL} bash -s" <<'REMOTE'
set -euo pipefail

test -x /home/cloud-compose/init
test -x /home/cloud-compose/up
test -x /home/cloud-compose/down
test -x /home/cloud-compose/rollout
test -x /home/cloud-compose/run.sh
python3 -m json.tool /home/cloud-compose/compose-projects.json >/dev/null

python3 - <<'PY'
import json
import os
from pathlib import Path

name = os.environ["SMOKE_NAME"]
template = os.environ["SMOKE_TEMPLATE"]
project_dir = os.environ["SMOKE_PROJECT_DIR"]
env = {}
for line in Path("/home/cloud-compose/.env").read_text().splitlines():
    if not line.strip():
        continue
    key, raw = line.split("=", 1)
    env[key] = json.loads(raw)

projects = json.loads(Path("/home/cloud-compose/compose-projects.json").read_text())
project = projects[name]

assert env["CLOUD_COMPOSE_PROVIDER"] == "onprem"
assert env["CLOUD_COMPOSE_APPS"] == name
assert env["CLOUD_COMPOSE_PRIMARY_APP"] == name
assert env["SITECTL_PLUGIN"] == template
assert env["DOCKER_COMPOSE_DIR"] == project_dir
assert f"sitectl-{template}" in env["SITECTL_PACKAGES"].split()
assert project["docker_compose_repo"] == f"https://github.com/libops/{template}.git"
assert project["project_dir"] == project_dir
assert project["sitectl_plugin"] == template
PY

test -d "$SMOKE_PROJECT_DIR/.git"
systemctl is-active --quiet cloud-compose
runuser -u cloud-compose -- env HOME=/home/cloud-compose bash -lc \
  "source /home/cloud-compose/profile.sh && sitectl healthcheck --context \"${SMOKE_NAME}\" --persist --timeout \"${SMOKE_HEALTHCHECK_TIMEOUT}\" --interval \"${SMOKE_HEALTHCHECK_INTERVAL}\" --format table"
REMOTE
}

case "$SMOKE_METHOD" in
  ansible) deploy_ansible ;;
  salt) deploy_salt ;;
  *)
    echo "Unknown config-management smoke method: ${SMOKE_METHOD}" >&2
    exit 2
    ;;
esac

verify_remote
