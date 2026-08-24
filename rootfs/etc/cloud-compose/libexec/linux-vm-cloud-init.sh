#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    echo "usage: linux-vm-cloud-init.sh DATA_DEVICE VOLUMES_DEVICE ROLLOUT_ENABLED SITECTL_VERSION" >&2
    exit 2
fi

data_device="$1"
volumes_device="$2"
rollout_enabled="$3"
sitectl_version="$4"
readonly sitectl=/etc/cloud-compose/bin/bootstrap-sitectl

case "$rollout_enabled" in
    true | false) ;;
    *)
        echo "ROLLOUT_ENABLED must be true or false" >&2
        exit 2
        ;;
esac
if ! id -u cloud-compose >/dev/null 2>&1 || ! getent group docker >/dev/null 2>&1; then
    echo "cloud-init did not create the cloud-compose user and docker group" >&2
    exit 1
fi
cloud_compose_in_docker_group=false
for account_group in $(id -nG cloud-compose); do
    if [[ "$account_group" == "docker" ]]; then
        cloud_compose_in_docker_group=true
        break
    fi
done
if [[ "$cloud_compose_in_docker_group" != "true" ]]; then
    echo "cloud-init did not add cloud-compose to the docker group" >&2
    exit 1
fi

bash /etc/cloud-compose/libexec/bootstrap-sitectl.sh \
    --version "$sitectl_version"
"$sitectl" host filesystems \
    --data-device "$data_device" \
    --volumes-device "$volumes_device" \
    --fresh-identity fresh

if [[ -d /var/lib/cloud-compose/mounted-rootfs/mnt/disks ]]; then
    cp -a /var/lib/cloud-compose/mounted-rootfs/mnt/disks/. /mnt/disks/
fi
chown root:cloud-compose /mnt/disks/data
chmod 1775 /mnt/disks/data
chown cloud-compose:cloud-compose /mnt/disks/volumes
chmod 0775 /mnt/disks/volumes
install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/data/libops

if [[ "$rollout_enabled" == "true" ]]; then
    bash /home/cloud-compose/deploy-rollout.sh >>/home/cloud-compose/run.log 2>&1
fi
rm -f /var/lib/cloud-compose/bootstrap-complete
/etc/cloud-compose/libexec/harden-bootstrap-paths.sh
"$sitectl" host systemd ensure-bootstrap
