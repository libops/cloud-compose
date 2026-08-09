#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: gcp-upgrade-verify-metadata-isolation.sh CONTAINER_PROGRAM" >&2
    exit 2
fi

container_program="$1"
metadata_address="169.254.169.254"
metadata_header="Metadata-Flavor: Google"
alpine_image="alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"

[[ "$container_program" == /home/cloud-compose/.cache/libops-ci/gcp-upgrade-container-metadata-isolation.sh &&
    -f "$container_program" && ! -L "$container_program" ]] || {
    echo "Container metadata-isolation program is missing or unsafe" >&2
    exit 1
}

docker run --rm --network bridge \
    --mount "type=bind,src=${container_program},dst=/usr/local/bin/cloud-compose-metadata-isolation,readonly" \
    "$alpine_image" \
    /bin/sh /usr/local/bin/cloud-compose-metadata-isolation

for metadata_scheme in http https; do
    if curl -kfsS --connect-timeout 3 --max-time 5 \
        --header "$metadata_header" \
        "${metadata_scheme}://${metadata_address}/computeMetadata/v1/instance/id" \
        >/dev/null 2>&1; then
        echo "Unprivileged host process reached GCP metadata ${metadata_scheme}" >&2
        exit 1
    fi
done
