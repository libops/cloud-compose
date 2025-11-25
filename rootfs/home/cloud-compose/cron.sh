#!/usr/bin/env bash

set -eou pipefail

echo "Running daily cron"

pushd /home/cloud-compose

bash rotate-keys-internal.sh
bash rotate-keys-app.sh

/usr/bin/docker system prune -af

popd
