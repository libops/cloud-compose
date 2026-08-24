#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh
sitectl=/home/cloud-compose/bin/sitectl
[[ -x "$sitectl" && ! -L "$sitectl" ]] || sitectl=/etc/cloud-compose/bin/bootstrap-sitectl
exec "$sitectl" host docker-plugins
