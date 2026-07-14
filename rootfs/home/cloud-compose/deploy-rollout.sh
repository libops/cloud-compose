#!/usr/bin/env bash

set -eou pipefail

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
if [[ ! "$ROLLOUT_DOWNLOAD_URL" =~ ^https://[^[:space:]]+$ ]]; then
  echo "ROLLOUT_DOWNLOAD_URL must be an HTTPS URL without whitespace" >&2
  exit 2
fi
if [[ ! "$ROLLOUT_DOWNLOAD_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ROLLOUT_DOWNLOAD_SHA256 must be a lowercase SHA-256 digest" >&2
  exit 2
fi

tmp="$(mktemp)"
install_tmp=""
trap 'rm -f -- "$tmp" "$install_tmp"' EXIT

retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 5 --retry-all-errors --retry-delay 2 \
  --connect-timeout 10 --max-time 300 -o "$tmp" -- "$ROLLOUT_DOWNLOAD_URL"
printf '%s  %s\n' "$ROLLOUT_DOWNLOAD_SHA256" "$tmp" | sha256sum -c -
install_tmp="$(mktemp /usr/local/bin/.cloud-compose-rollout.XXXXXXXXXX)"
install -o root -g root -m 0755 "$tmp" "$install_tmp"
printf '%s  %s\n' "$ROLLOUT_DOWNLOAD_SHA256" "$install_tmp" | sha256sum -c -
mv -f -- "$install_tmp" /usr/local/bin/cloud-compose-rollout
install_tmp=""

systemctl daemon-reload
systemctl enable cloud-compose-rollout.service
systemctl restart cloud-compose-rollout.service
