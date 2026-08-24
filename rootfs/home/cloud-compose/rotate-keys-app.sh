#!/usr/bin/env bash
set -euo pipefail
source /home/cloud-compose/profile.sh
exec sitectl host keys app "${1:-rotate}"
