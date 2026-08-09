#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: linux-vm-cloud-init.sh DATA_DEVICE VOLUMES_DEVICE ROOTFS_ARCHIVE_ENABLED ROLLOUT_ENABLED DIAGNOSTICS_SHA256" >&2
    exit 2
fi

data_device="$1"
volumes_device="$2"
rootfs_archive_enabled="$3"
rollout_enabled="$4"
diagnostics_sha256="$5"
readonly bootstrap_dir=/var/lib/cloud-compose/bootstrap
readonly archive_program="$bootstrap_dir/rootfs-archive.sh"
readonly overlay_dir=/var/lib/cloud-compose/rootfs-overlay
readonly filesystem_prep=/run/cloud-compose-prepare-filesystem
readonly filesystem_persist=/run/cloud-compose-persist-filesystems
readonly filesystem_reconcile=/run/cloud-compose-reconcile-fstab.awk

require_root_owned_data_program() {
    local path="$1" metadata

    if [[ -L "$path" || ! -f "$path" ]]; then
        echo "Checked filesystem data program is missing or unsafe: $path" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$path")" || return 1
    if [[ "$metadata" != "0:0:600:1:regular file" ]]; then
        echo "Checked filesystem data program is not an unlinked root-owned mode-0600 file: $path" >&2
        return 1
    fi
}

for boolean_name in rootfs_archive_enabled rollout_enabled; do
    case "${!boolean_name}" in
        true | false) ;;
        *)
            echo "${boolean_name^^} must be true or false" >&2
            exit 2
            ;;
    esac
done
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

if [[ "$rootfs_archive_enabled" == "false" ]]; then
    install -m 0600 -- /home/cloud-compose/prepare-filesystem.sh "$filesystem_prep"
    install -m 0600 -- /home/cloud-compose/persist-filesystems.sh "$filesystem_persist"
    install -m 0600 -- /etc/cloud-compose/awk/reconcile-fstab.awk "$filesystem_reconcile"
fi

require_root_owned_data_program "$filesystem_reconcile"

bash "$filesystem_prep" "$data_device" /mnt/disks/data --publish-fresh-marker
bash "$filesystem_prep" "$volumes_device" /mnt/disks/volumes
mkdir -p /mnt/disks/data/docker/volumes
if ! mountpoint -q /mnt/disks/data/docker/volumes; then
    mount --bind /mnt/disks/volumes /mnt/disks/data/docker/volumes
fi
for required_mount in /mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes; do
    if ! mountpoint -q -- "$required_mount"; then
        echo "Required cloud-compose mount is unavailable: $required_mount" >&2
        exit 1
    fi
done
CLOUD_COMPOSE_FSTAB_RECONCILE_PROGRAM="$filesystem_reconcile" \
    bash "$filesystem_persist" "$data_device" "$volumes_device"

if [[ "$rootfs_archive_enabled" == "true" ]]; then
    bash "$archive_program" install-staged "$overlay_dir"
elif [[ -d /var/lib/cloud-compose/mounted-rootfs/mnt/disks ]]; then
    cp -a /var/lib/cloud-compose/mounted-rootfs/mnt/disks/. /mnt/disks/
fi

bash "$archive_program" install-diagnostics "$diagnostics_sha256"
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
bash /etc/cloud-compose/libexec/start-cloud-compose-bootstrap.sh
