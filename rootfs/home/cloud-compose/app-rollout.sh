#!/usr/bin/env bash

set -eou pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

exec bash /home/cloud-compose/compose-dispatch.sh rollout
