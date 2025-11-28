#!/usr/bin/env bash

set -euo pipefail

cleanup() {
  rm tmp.attr env.tmp || echo ""
  popd
}

# make sure out internal services dir exists
DIR=/mnt/disks/data/libops
if [ ! -d "$DIR" ]; then
  mkdir "$DIR"
fi
cp /etc/libops/docker-compose.yaml /mnt/disks/data/libops

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
  if [[ "$V" =~ [[:space:]\$\`\\\"\'\(\)\{\}\[\]\|\&\;\<\>\*\?] ]]; then
    echo "$K=\"$V\"" >> env.tmp
  else
    echo "$K=$V" >> env.tmp
  fi
done

{
  echo "GCP_PUBLIC_IP=$(jq -r '.instance.networkInterfaces[0].accessConfigs[0].externalIp' tmp.attr)"
  echo "GCP_PRIVATE_IP=$(jq -r '.instance.networkInterfaces[0].ip' tmp.attr)"
} >> env.tmp

if ! diff <(md5sum env.tmp) <(md5sum env); then
  mv env.tmp env
  cp env /mnt/disks/data/libops/.env
fi

# shellcheck disable=SC1091
. ./env

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

echo "Running dokcer compose ${name}"
${SCRIPTS[${name}]}
EOT
  chmod +x "${SCRIPT_DIR}/${name}"
done
