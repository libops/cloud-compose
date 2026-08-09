#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: config-management-deploy-salt.sh NAME TEMPLATE ENVIRONMENT PROJECT_DIR" >&2
  exit 2
fi

smoke_name="$1"
smoke_template="$2"
smoke_environment="$3"
smoke_project_dir="$4"

for identifier in "$smoke_name" "$smoke_template" "$smoke_environment"; do
  [[ "$identifier" =~ ^[a-z][a-z0-9-]*$ ]] || {
    echo "Unsafe config-management smoke identifier: $identifier" >&2
    exit 2
  }
done
[[ "$smoke_project_dir" == /mnt/disks/data/libops/* &&
    "$smoke_project_dir" != *'//'* &&
    ! "$smoke_project_dir" =~ (^|/)\.\.?(/|$) ]] || {
  echo "Unsafe config-management smoke project directory: $smoke_project_dir" >&2
  exit 2
}

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

mkdir -p \
  /tmp/cloud-compose-salt/etc \
  /tmp/cloud-compose-salt/cache \
  /tmp/cloud-compose-salt/pki \
  /srv/cloud-compose/.smoke-pillar
cat >/tmp/cloud-compose-salt/etc/minion <<EOF
id: ${smoke_name}
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
  '${smoke_name}':
    - cloud-compose
EOF

cat >/srv/cloud-compose/.smoke-pillar/cloud-compose.sls <<EOF
cloud_compose:
  name: ${smoke_name}
  provider: onprem
  template: ${smoke_template}
  dedicated_host_acknowledged: true
  bootstrap_wait_seconds: 1200
  runtime:
    compose:
      ingress_port: 80
      project_dir: ${smoke_project_dir}
    sitectl:
      environment: ${smoke_environment}
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
