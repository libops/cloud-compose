#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/libexec/cloud-compose/bootstrap-security.sh

program="${1:-}"
if [[ -z "$program" ]]; then
    echo "A Cloud Compose root program is required" >&2
    exit 2
fi
shift

case "$program" in
    configure-metadata-firewall.sh | deploy-rollout.sh | docker-prune.sh | \
    libops-managed-runtime.sh | mount-overlays.sh | offhost-backup.sh | \
    restore-test.sh | rotate-keys-daily.sh | \
    vault-agent-readiness.sh) ;;
    *)
        echo "Unsupported Cloud Compose root program: $program" >&2
        exit 2
        ;;
esac

cloud_compose_secure_runtime_home
exec /bin/bash "/home/cloud-compose/$program" "$@"
