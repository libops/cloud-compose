#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /usr/local/libexec/cloud-compose/bootstrap-security.sh

cloud_compose_secure_runtime_home
exec /bin/bash /home/cloud-compose/run.sh
