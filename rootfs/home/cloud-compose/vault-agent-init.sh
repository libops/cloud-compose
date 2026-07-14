#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

case "${VAULT_AGENT_ENABLED:-false}" in
    false)
        echo "Vault Agent is disabled"
        systemctl disable --now cloud-compose-vault-agent.service >/dev/null 2>&1 || true
        rm -f -- /run/cloud-compose/vault-agent.ready
        exit 0
        ;;
    true) ;;
    *)
        echo "VAULT_AGENT_ENABLED must be true or false" >&2
        exit 1
        ;;
esac

if [ -L /etc/vault-agent.d/cloud-compose.hcl ] || [ ! -f /etc/vault-agent.d/cloud-compose.hcl ]; then
    echo "Vault Agent is enabled but its config is missing or unsafe" >&2
    systemctl disable --now cloud-compose-vault-agent.service >/dev/null 2>&1 || true
    exit 1
fi

if [ ! -x /usr/local/bin/vault ]; then
    echo "Vault Agent is enabled but the Vault binary is not installed" >&2
    systemctl disable --now cloud-compose-vault-agent.service >/dev/null 2>&1 || true
    exit 1
fi

bash /home/cloud-compose/vault-agent-readiness.sh prepare

systemctl daemon-reload
systemctl enable cloud-compose-vault-agent.service
systemctl restart cloud-compose-vault-agent.service
if ! systemctl is-active --quiet cloud-compose-vault-agent.service ||
    [ -L /run/cloud-compose/vault-agent.ready ] || [ ! -f /run/cloud-compose/vault-agent.ready ]; then
    echo "Vault Agent failed to initialize while explicitly enabled" >&2
    systemctl disable --now cloud-compose-vault-agent.service >/dev/null 2>&1 || true
    exit 1
fi
