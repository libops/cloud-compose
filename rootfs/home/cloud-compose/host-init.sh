#!/usr/bin/env bash

set -euo pipefail

cleanup() {
  rm tmp.attr .env.tmp || echo ""
  popd
}

pushd /home/cloud-compose

trap cleanup EXIT

if [ -f .env ]; then
  cp .env .env.tmp
fi

curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > tmp.attr

{
  echo "GCP_PUBLIC_IP=$(jq -r '.instance.networkInterfaces[0].accessConfigs[0].externalIp' tmp.attr)"
  echo "GCP_PRIVATE_IP=$(jq -r '.instance.networkInterfaces[0].ip' tmp.attr)"
} >> .env.tmp

if ! diff <(md5sum .env.tmp) <(md5sum .env); then
  mv .env.tmp .env
  cp .env /mnt/disks/data/libops-internal/
  chown cloud-compose /mnt/disks/data/libops-internal/.env
fi

chown -R cloud-compose:cloud-compose /home/cloud-compose
usermod -aG docker cloud-compose
