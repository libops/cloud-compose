#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "${CLOUD_COMPOSE_PROFILE_PATH:-/home/cloud-compose/profile.sh}"

unset BASH_ENV ENV LD_PRELOAD LD_LIBRARY_PATH
PORT="${ROLLOUT_PORT:?ROLLOUT_PORT is required}"
JWKS_URI="${ROLLOUT_JWKS_URI:?ROLLOUT_JWKS_URI is required}"
JWT_AUD="${ROLLOUT_JWT_AUD:?ROLLOUT_JWT_AUD is required}"
CUSTOM_CLAIMS="${ROLLOUT_CUSTOM_CLAIMS:-}"

if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$PORT < 1 || 10#$PORT > 65535)); then
  echo "ROLLOUT_PORT must be an integer from 1 through 65535" >&2
  exit 2
fi
if [[ ! "$JWKS_URI" =~ ^https://[^[:space:]]+$ ]]; then
  echo "ROLLOUT_JWKS_URI must be an HTTPS URL without whitespace" >&2
  exit 2
fi
if [[ "$JWT_AUD" == *$'\n'* || "$JWT_AUD" == *$'\r'* || -z "$JWT_AUD" ]]; then
  echo "ROLLOUT_JWT_AUD must be a non-empty single-line value" >&2
  exit 2
fi
if [[ -n "$CUSTOM_CLAIMS" ]] &&
  ! jq -e 'type == "object"' <<<"$CUSTOM_CLAIMS" >/dev/null; then
  echo "ROLLOUT_CUSTOM_CLAIMS must be empty or a JSON object" >&2
  exit 2
fi
export PORT JWKS_URI JWT_AUD CUSTOM_CLAIMS

exec "${CLOUD_COMPOSE_ROLLOUT_BIN:-/usr/local/bin/cloud-compose-rollout}"
