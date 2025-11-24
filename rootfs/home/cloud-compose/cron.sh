#!/usr/bin/env bash

set -eou pipefail

echo "Running daily cron"

export DIR=/etc/libops
bash /home/cloud-compose/rollout.sh

/usr/bin/docker system prune -af
