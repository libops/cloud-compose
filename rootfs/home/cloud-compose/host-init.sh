#!/usr/bin/env bash

set -euxo pipefail

cleanup() {
  rm -f tmp.attr .env.tmp
  popd >/dev/null
}

pushd /home/cloud-compose >/dev/null

trap cleanup EXIT

if [ -f .env ]; then
  cp .env .env.tmp
else
  touch .env .env.tmp
fi

if [ "${CLOUD_COMPOSE_PROVIDER:-}" = "gcp" ]; then
  curl -sf \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > tmp.attr

  {
    echo "GCP_PUBLIC_IP=$(jq -r '.instance.networkInterfaces[0].accessConfigs[0].externalIp' tmp.attr)"
    echo "GCP_PRIVATE_IP=$(jq -r '.instance.networkInterfaces[0].ip' tmp.attr)"
  } >> .env.tmp
fi

if ! diff <(md5sum .env.tmp) <(md5sum .env) >/dev/null 2>&1; then
  mv .env.tmp .env
else
  rm -f .env.tmp
fi

if [ "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" = "true" ]; then
  install -d -m 0755 /mnt/disks/data/libops-internal
  cp .env /mnt/disks/data/libops-internal/
  chown cloud-compose:cloud-compose /mnt/disks/data/libops-internal/.env
fi

chown -R cloud-compose:cloud-compose /home/cloud-compose
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
