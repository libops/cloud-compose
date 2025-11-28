#!/usr/bin/env bash

set -eou pipefail
set -x

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

bash /home/cloud-compose/host-conf.sh
bash /home/cloud-compose/host-init.sh
bash /home/cloud-compose/app-init.sh

systemctl start cloud-compose
systemctl start internal-services.timer
systemctl start cron.timer
