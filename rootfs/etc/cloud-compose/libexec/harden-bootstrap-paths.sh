#!/usr/bin/env bash
set -euo pipefail
sitectl=/etc/cloud-compose/bin/bootstrap-sitectl
[[ -x "$sitectl" && ! -L "$sitectl" ]] || sitectl=/home/cloud-compose/bin/sitectl
exec "$sitectl" host security secure-runtime
