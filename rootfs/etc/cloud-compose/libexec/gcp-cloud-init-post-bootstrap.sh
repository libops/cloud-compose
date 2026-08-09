#!/usr/bin/env bash

set -eu

if [[ "$#" -ne 2 ]]; then
    echo "usage: gcp-cloud-init-post-bootstrap.sh ROLLOUT_ENABLED RUNCMD_FILE" >&2
    exit 2
fi

rollout_enabled="$1"
runcmd_file="$2"
case "$rollout_enabled" in
    true | false) ;;
    *)
        echo "ROLLOUT_ENABLED must be true or false" >&2
        exit 2
        ;;
esac

bash /etc/cloud-compose/libexec/require-bootstrap-ready.sh
if [[ "$rollout_enabled" == "true" ]]; then
    bash /home/cloud-compose/deploy-rollout.sh >>/home/cloud-compose/run.log 2>&1
fi
if [[ -s "$runcmd_file" ]]; then
    # shellcheck disable=SC1090
    source "$runcmd_file"
fi
