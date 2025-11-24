#!/usr/bin/env bash

set -euo pipefail

cleanup() {
  rm tmp.attr env.tmp || echo ""
  popd
}

pushd /home/cloud-compose

trap cleanup EXIT

if [ ! -f env ]; then
  touch env
fi

curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/?recursive=true" > tmp.attr

echo "HOME=/home/cloud-compose" > env.tmp
for K in $(jq -r '.instance.attributes | keys | .[]' tmp.attr | grep -E '(DOCKER|GCP|LIBOPS)'); do
  V=$(jq -r .instance.attributes."$K" tmp.attr)
  echo "$K=\"$V\"" >> env.tmp
done

{
  echo "GCP_PUBLIC_IP=$(jq -r '.instance.networkInterfaces[0].accessConfigs[0].externalIp' tmp.attr)"
  echo "GCP_PRIVATE_IP=$(jq -r '.instance.networkInterfaces[0].ip' tmp.attr)"
} >> env.tmp

# shellcheck disable=SC1091
source env.tmp
echo "SITE_DOCKER_REGISTRY=us-docker.pkg.dev/${GCP_PROJECT}/private" >> env.tmp

if ! diff <(md5sum env.tmp) <(md5sum env); then
  mv env.tmp env
  cp env /etc/libops/.env
  if [ -d /mnt/disks/data/compose ]; then
    cp env /mnt/disks/data/compose/.env
  fi
fi

# generate the docker compose init/up/down commands
# used by the systemd service
SCRIPT_DIR="/mnt/disks/data"
declare -A SCRIPTS=(
  ["init"]="${DOCKER_COMPOSE_INIT_CMD}"
  ["up"]="${DOCKER_COMPOSE_UP_CMD}"
  ["down"]="${DOCKER_COMPOSE_DOWN_CMD}"
)
for name in "${!SCRIPTS[@]}"; do
  cat << EOT > "${SCRIPT_DIR}/${name}"
#!/usr/bin/env bash

set -eou pipefail

${SCRIPTS[${name}]}
EOT
  chmod +x "${SCRIPT_DIR}/${name}"
done
