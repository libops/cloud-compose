#!/usr/bin/env bash

set -euo pipefail

: "${SMOKE_METHOD:?}"
: "${SMOKE_HOST:?}"
: "${SMOKE_NAME:?}"
: "${SMOKE_TEMPLATE:?}"
: "${SMOKE_ENVIRONMENT:?}"
: "${SMOKE_PROJECT_DIR:?}"

readonly smoke_ssh_key_mount="/run/secrets/cloud-compose-ssh-key"
if [[ -L "$smoke_ssh_key_mount" || ! -f "$smoke_ssh_key_mount" ]]; then
  echo "Config-management smoke SSH key mount is missing or unsafe" >&2
  exit 1
fi

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
install -m 0600 "$smoke_ssh_key_mount" /tmp/cloud-compose-ssh/id_ed25519
touch /tmp/cloud-compose-ssh/known_hosts
chmod 0600 /tmp/cloud-compose-ssh/known_hosts
ssh-keyscan -H "$SMOKE_HOST" >>/tmp/cloud-compose-ssh/known_hosts 2>/dev/null

ssh_target="root@${SMOKE_HOST}"
ssh_opts=(
  -i /tmp/cloud-compose-ssh/id_ed25519
  -o BatchMode=yes
  -o ConnectTimeout=20
  -o ServerAliveCountMax=10
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile=/tmp/cloud-compose-ssh/known_hosts
)

retry_remote_operation() {
  local label="$1" attempt status
  shift

  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if [[ "$attempt" -eq 3 ]]; then
      echo "${label} failed after ${attempt} attempts" >&2
      return "$status"
    fi
    echo "${label} failed; retrying in 15s (attempt $((attempt + 1)) of 3)" >&2
    sleep 15
  done
}

deploy_ansible() {
  export ANSIBLE_RETRY_FILES_ENABLED=false
  export ANSIBLE_ROLES_PATH=/work/ansible/roles

  cat >/tmp/cloud-compose-ansible-inventory.yml <<EOF || return 1
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
          cloud_compose_dedicated_host_acknowledged: true
          cloud_compose_bootstrap_timeout: 1500
          cloud_compose_bootstrap_wait_seconds: 1200
          cloud_compose_runtime:
            compose:
              ingress_port: 80
              project_dir: ${SMOKE_PROJECT_DIR}
            sitectl:
              environment: ${SMOKE_ENVIRONMENT}
EOF

  ansible-playbook \
    -i /tmp/cloud-compose-ansible-inventory.yml \
    /work/ansible/playbooks/site.yml
}

deploy_salt() {
  local remote_command

  if ! tar -C /work \
    --exclude="./.git" \
    --exclude="./.terraform" \
    --exclude="./docs/site" \
    -czf - . |
    ssh "${ssh_opts[@]}" "$ssh_target" \
      "rm -rf /srv/cloud-compose && mkdir -p /srv/cloud-compose && tar -xzf - -C /srv/cloud-compose"; then
    return 1
  fi

  printf -v remote_command '%q ' \
    /srv/cloud-compose/ci/remote/config-management-deploy-salt.sh \
    "$SMOKE_NAME" \
    "$SMOKE_TEMPLATE" \
    "$SMOKE_ENVIRONMENT" \
    "$SMOKE_PROJECT_DIR"
  if ! ssh "${ssh_opts[@]}" "$ssh_target" "$remote_command"; then
    return 1
  fi
}

verify_remote() {
  local remote_contract_dir lifecycle_contract runtime_state_contract verification_program
  local remote_command status

  remote_contract_dir="$(ssh "${ssh_opts[@]}" "$ssh_target" \
    'mktemp -d /tmp/cloud-compose-hosted-contract.XXXXXX')" || return 1
  if [[ ! "$remote_contract_dir" =~ ^/tmp/cloud-compose-hosted-contract\.[A-Za-z0-9]+$ ]]; then
    echo "Remote contract directory is unsafe: $remote_contract_dir" >&2
    return 1
  fi

  lifecycle_contract="$remote_contract_dir/lifecycle-program-contract.sh"
  runtime_state_contract="$remote_contract_dir/config-management-runtime-state-contract.py"
  verification_program="$remote_contract_dir/config-management-verify.sh"
  if ! ssh "${ssh_opts[@]}" "$ssh_target" \
    "install -m 0700 /dev/stdin $lifecycle_contract" \
    </work/ci/lifecycle-program-contract.sh; then
    ssh "${ssh_opts[@]}" "$ssh_target" "rmdir -- $remote_contract_dir" || true
    return 1
  fi
  if ! ssh "${ssh_opts[@]}" "$ssh_target" \
    "install -m 0600 /dev/stdin $runtime_state_contract" \
    </work/ci/config-management-runtime-state-contract.py; then
    ssh "${ssh_opts[@]}" "$ssh_target" \
      "rm -f -- $lifecycle_contract && rmdir -- $remote_contract_dir" || true
    return 1
  fi
  if ! ssh "${ssh_opts[@]}" "$ssh_target" \
    "install -m 0700 /dev/stdin $verification_program" \
    </work/ci/remote/config-management-verify.sh; then
    ssh "${ssh_opts[@]}" "$ssh_target" \
      "rm -f -- $lifecycle_contract $runtime_state_contract && rmdir -- $remote_contract_dir" || true
    return 1
  fi

  printf -v remote_command '%q ' \
    "$verification_program" \
    "$SMOKE_NAME" \
    "$SMOKE_TEMPLATE" \
    "$SMOKE_ENVIRONMENT" \
    "$SMOKE_PROJECT_DIR" \
    "$lifecycle_contract" \
    "$runtime_state_contract"
  if ssh "${ssh_opts[@]}" "$ssh_target" "$remote_command"; then
    status=0
  else
    status=$?
  fi

  ssh "${ssh_opts[@]}" "$ssh_target" \
    "rm -f -- $lifecycle_contract $runtime_state_contract $verification_program && rmdir -- $remote_contract_dir" || true
  return "$status"
}

case "$SMOKE_METHOD" in
  ansible) retry_remote_operation "Ansible deployment" deploy_ansible ;;
  salt) retry_remote_operation "Salt deployment" deploy_salt ;;
  *)
    echo "Unknown config-management smoke method: ${SMOKE_METHOD}" >&2
    exit 2
    ;;
esac

retry_remote_operation "Remote verification" verify_remote
