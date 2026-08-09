#!/bin/sh

set -eu

nslookup dl-cdn.alpinelinux.org >/dev/null
nslookup metadata.google.internal | grep -Fq "169.254.169.254"
for metadata_port in 80 443; do
    if nc -z -w 3 169.254.169.254 "$metadata_port"; then
        echo "Container reached GCP metadata TCP port ${metadata_port}" >&2
        exit 1
    fi
done
