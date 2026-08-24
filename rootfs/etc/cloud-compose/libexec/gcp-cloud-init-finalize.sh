#!/usr/bin/env bash

set -eu

if [[ "$#" -ne 1 ]]; then
    echo "usage: gcp-cloud-init-finalize.sh INIT_COMMANDS_FILE" >&2
    exit 2
fi

init_commands_file="$1"
if [[ ! -f /run/cloud-compose-filesystems-ready ]]; then
    echo "Cloud Compose filesystems were not prepared; refusing application initialization" >&2
    exit 1
fi
if [[ -s "$init_commands_file" ]]; then
    # Operator-provided initialization commands are stored as a root-controlled
    # program instead of being interpolated into the cloud-init shell body.
    # shellcheck disable=SC1090
    source "$init_commands_file"
fi
chown root:cloud-compose /mnt/disks/data
chmod 1775 /mnt/disks/data
chown cloud-compose:cloud-compose /mnt/disks/volumes
chmod 0775 /mnt/disks/volumes
install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/data/libops
rm -f /var/lib/cloud-compose/bootstrap-complete
/etc/cloud-compose/libexec/harden-bootstrap-paths.sh
/etc/cloud-compose/bin/bootstrap-sitectl host systemd ensure-bootstrap
