#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

if [ "${VAULT_AGENT_ENABLED:-false}" != "true" ]; then
    echo "Vault Agent is disabled"
    exit 0
fi

if [ ! -f /etc/vault-agent.d/cloud-compose.hcl ]; then
    echo "Vault Agent config is missing"
    exit 0
fi

if ! command -v vault >/dev/null 2>&1; then
    echo "Vault binary is not installed; skipping vault-agent.service"
    exit 0
fi

mkdir -p "$(dirname "${VAULT_AGENT_TOKEN_PATH:-/mnt/disks/data/vault/token}")"
chmod 0700 "$(dirname "${VAULT_AGENT_TOKEN_PATH:-/mnt/disks/data/vault/token}")"

systemctl daemon-reload
systemctl enable vault-agent.service
systemctl restart vault-agent.service
