#!/usr/bin/env bash
set -euo pipefail
exec /etc/cloud-compose/libexec/sitectl-host.sh diagnostics "$@"
