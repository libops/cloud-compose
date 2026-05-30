#!/usr/bin/env bash

set -eou pipefail
set -x

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

if [ "${ROLLOUT_ENABLED:-false}" != "true" ]; then
  echo "Rollout service is disabled"
  exit 0
fi

if [ -z "${ROLLOUT_DOWNLOAD_URL:-}" ]; then
  echo "ROLLOUT_DOWNLOAD_URL is required" >&2
  exit 1
fi

if [ -z "${ROLLOUT_DOWNLOAD_SHA256:-}" ]; then
  echo "ROLLOUT_DOWNLOAD_SHA256 is required" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

retry_until_success curl -fsSL --retry 5 --retry-delay 2 -o "$tmp" "$ROLLOUT_DOWNLOAD_URL"
echo "${ROLLOUT_DOWNLOAD_SHA256}  ${tmp}" | sha256sum -c -
install -o root -g root -m 0755 "$tmp" /usr/local/bin/cloud-compose-rollout

systemctl daemon-reload
systemctl enable cloud-compose-rollout.service
systemctl restart cloud-compose-rollout.service
