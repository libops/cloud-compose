#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "usage: config-management-verify.sh NAME TEMPLATE ENVIRONMENT PROJECT_DIR RUNTIME_STATE_CONTRACT" >&2
  exit 2
fi

export SMOKE_NAME="$1"
export SMOKE_TEMPLATE="$2"
export SMOKE_ENVIRONMENT="$3"
export SMOKE_PROJECT_DIR="$4"
readonly runtime_state_contract="$5"

[[ "$runtime_state_contract" == /tmp/cloud-compose-hosted-contract.*/* &&
    -f "$runtime_state_contract" && ! -L "$runtime_state_contract" ]] || {
  echo "Remote contract program is missing or unsafe: $runtime_state_contract" >&2
  exit 1
}

for program in \
  /home/cloud-compose/init \
  /home/cloud-compose/up \
  /home/cloud-compose/down \
  /home/cloud-compose/rollout \
  /home/cloud-compose/bin/sitectl \
  /home/cloud-compose/run.sh \
  /etc/cloud-compose/libexec/bootstrap-required.sh \
  /etc/cloud-compose/libexec/sitectl-host.sh; do
  test -x "$program"
done

for program_parent in \
  /home/cloud-compose \
  /etc/cloud-compose \
  /etc/cloud-compose/libexec; do
  test ! -L "$program_parent"
  test -d "$program_parent"
  test "$(stat -c '%u:%g:%a' -- "$program_parent")" = "0:0:755"
done

python3 -m json.tool /home/cloud-compose/compose-projects.json >/dev/null
python3 -m json.tool /home/cloud-compose/application-env.json >/dev/null
python3 "$runtime_state_contract"
/home/cloud-compose/bin/sitectl --version >/dev/null

test -d "$SMOKE_PROJECT_DIR/.git"
systemctl is-active --quiet cloud-compose
runuser -u cloud-compose -- env HOME=/home/cloud-compose \
  /home/cloud-compose/smoke-healthcheck.sh "$SMOKE_NAME"
