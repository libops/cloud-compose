#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 6 ]]; then
  echo "usage: config-management-verify.sh NAME TEMPLATE ENVIRONMENT PROJECT_DIR LIFECYCLE_CONTRACT RUNTIME_STATE_CONTRACT" >&2
  exit 2
fi

export SMOKE_NAME="$1"
export SMOKE_TEMPLATE="$2"
export SMOKE_ENVIRONMENT="$3"
export SMOKE_PROJECT_DIR="$4"
readonly lifecycle_program_contract="$5"
readonly runtime_state_contract="$6"

for contract_program in "$lifecycle_program_contract" "$runtime_state_contract"; do
  [[ "$contract_program" == /tmp/cloud-compose-hosted-contract.*/* &&
      -f "$contract_program" && ! -L "$contract_program" ]] || {
    echo "Remote contract program is missing or unsafe: $contract_program" >&2
    exit 1
  }
done

for program in \
  /home/cloud-compose/init \
  /home/cloud-compose/up \
  /home/cloud-compose/down \
  /home/cloud-compose/rollout \
  /home/cloud-compose/default-lifecycle.sh \
  /home/cloud-compose/run.sh \
  /home/cloud-compose/start-cloud-compose-bootstrap.sh \
  /etc/cloud-compose/libexec/bootstrap-required.sh \
  /etc/cloud-compose/libexec/bootstrap-security.sh \
  /etc/cloud-compose/libexec/run-bootstrap.sh \
  /etc/cloud-compose/libexec/require-bootstrap-ready.sh \
  /etc/cloud-compose/libexec/start-cloud-compose-bootstrap.sh \
  /etc/cloud-compose/libexec/run-root-program.sh; do
  test -x "$program"
done

python3 -m json.tool /home/cloud-compose/compose-projects.json >/dev/null
python3 -m json.tool /home/cloud-compose/application-env.json >/dev/null
python3 "$runtime_state_contract"
bash "$lifecycle_program_contract" /home/cloud-compose/default-lifecycle.sh

test -d "$SMOKE_PROJECT_DIR/.git"
systemctl is-active --quiet cloud-compose
runuser -u cloud-compose -- env HOME=/home/cloud-compose \
  /home/cloud-compose/smoke-healthcheck.sh "$SMOKE_NAME"
