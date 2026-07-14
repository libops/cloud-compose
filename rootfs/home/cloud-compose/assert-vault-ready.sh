#!/usr/bin/env bash

set -euo pipefail

profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-/home/cloud-compose/profile.sh}"
# shellcheck disable=SC1090
source "$profile_path"

case "${VAULT_AGENT_ENABLED:-false}" in
    false) exit 0 ;;
    true) ;;
    *)
        echo "VAULT_AGENT_ENABLED must be true or false" >&2
        exit 1
        ;;
esac

ready_marker="${VAULT_AGENT_READY_MARKER:-/run/cloud-compose/vault-agent.ready}"
if [[ -L "$ready_marker" || ! -f "$ready_marker" ]]; then
    echo "Vault Agent is enabled but has not published readiness" >&2
    exit 1
fi
if ! systemctl is-active --quiet cloud-compose-vault-agent.service; then
    echo "Vault Agent is enabled but its service is not active" >&2
    exit 1
fi
