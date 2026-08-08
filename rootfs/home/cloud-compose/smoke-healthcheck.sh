#!/usr/bin/env bash

set -euo pipefail

if (($# != 1)) || [[ -z "$1" ]]; then
    echo "usage: smoke-healthcheck.sh CONTEXT" >&2
    exit 2
fi

readonly context="$1"

# Load the same validated runtime environment and tool path used by the
# host-owned lifecycle scripts before handing control to sitectl.
export HOME=/home/cloud-compose
source /home/cloud-compose/profile.sh

exec sitectl healthcheck --context "$context" --persist --format table
