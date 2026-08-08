#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

cleanup() {
  if [ -n "${metadata_file:-}" ]; then
    rm -f "$metadata_file"
  fi
  popd >/dev/null
}

pushd /home/cloud-compose >/dev/null

trap cleanup EXIT

if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  metadata_file="$(mktemp /home/cloud-compose/.metadata.XXXXXXXXXX)"
  curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/?recursive=true" >"$metadata_file"

  update_runtime_env_file .env GCP_PUBLIC_IP \
    "$(jq -er '.instance.networkInterfaces[0].accessConfigs[0].externalIp' "$metadata_file")"
  update_runtime_env_file .env GCP_PRIVATE_IP \
    "$(jq -er '.instance.networkInterfaces[0].ip' "$metadata_file")"
fi

if [ "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" = "true" ]; then
  install -d -m 0755 /mnt/disks/data/libops-internal
  cp .env /mnt/disks/data/libops-internal/
  chown cloud-compose:cloud-compose /mnt/disks/data/libops-internal/.env
fi

# Root-owned services execute scripts and load control data from this tree.
# Keep the home boundary itself non-writable and grant the application account
# only explicit mutable subdirectories. In particular, sitectl owns its state
# below .sitectl; scripts at the home boundary remain root-owned.
chown root:root /home/cloud-compose
chmod 0755 /home/cloud-compose
for mutable_dir in \
  /home/cloud-compose/apps \
  /home/cloud-compose/state \
  /home/cloud-compose/.sitectl \
  /home/cloud-compose/.cache \
  /home/cloud-compose/.config \
  /home/cloud-compose/.local; do
  install -d -m 0750 -o cloud-compose -g cloud-compose "$mutable_dir"
done
if [[ -L /home/cloud-compose/bin || ! -d /home/cloud-compose/bin ||
  "$(stat -c '%u:%g:%a:%F' -- /home/cloud-compose/bin)" != "0:0:755:directory" ]]; then
  echo "Managed command directory was not secured by the runtime installer" >&2
  exit 1
fi

find /home/cloud-compose -maxdepth 1 -type f -name '*.sh' \
  -exec chown root:root {} + \
  -exec chmod 0755 {} +
for dispatcher in init up down rollout; do
  dispatcher_path="/home/cloud-compose/$dispatcher"
  dispatcher_metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$dispatcher_path")" || {
    echo "Unable to inspect Cloud Compose lifecycle dispatcher: $dispatcher_path" >&2
    exit 1
  }
  IFS=: read -r dispatcher_uid _ dispatcher_mode dispatcher_links dispatcher_kind \
    <<<"$dispatcher_metadata"
  if [[ -L "$dispatcher_path" || ! -f "$dispatcher_path" ||
    "$dispatcher_uid" != "0" || "$dispatcher_links" != "1" ||
    "$dispatcher_kind" != "regular file" || ! "$dispatcher_mode" =~ ^[0-7]{3,4}$ ||
    $((8#$dispatcher_mode & 0022)) -ne 0 ]]; then
    echo "Unsafe Cloud Compose lifecycle dispatcher: $dispatcher_path" >&2
    exit 1
  fi
  chown root:root "$dispatcher_path"
  chmod 0755 "$dispatcher_path"
done
for runtime_input in .env compose-projects.json application-env.json; do
  if [ -f "/home/cloud-compose/$runtime_input" ]; then
    chown root:cloud-compose "/home/cloud-compose/$runtime_input"
    chmod 0640 "/home/cloud-compose/$runtime_input"
  fi
done
groupadd --force docker
if ! id -u cloud-compose >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups docker cloud-compose
elif ! id -nG cloud-compose | tr ' ' '\n' | grep -qx docker; then
  usermod --append --groups docker cloud-compose || {
    echo "Warning: failed to add cloud-compose to docker group" >&2
    id cloud-compose >&2 || true
    getent group docker >&2 || true
  }
fi

# Cloud-init prepares these mount roots before invoking run.sh, while the
# Ansible and Salt adapters can install the runtime onto pre-mounted storage.
# Normalize only the mount roots here so every entry path can create lifecycle
# locks without granting recursive ownership of application or control data.
# The sticky, root-owned data root protects root-only bootstrap attestations
# while still allowing the cloud-compose group to create application paths.
install -d -m 1775 -o root -g cloud-compose /mnt/disks/data
install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/volumes
install -d -m 0775 -o cloud-compose -g cloud-compose /mnt/disks/data/libops
