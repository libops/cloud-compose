#!/usr/bin/env bash

set -euo pipefail

_cc_run_rollout_service_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_run_rollout_service_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_run_rollout_service_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_run_rollout_service_source _cc_run_rollout_service_dir _cc_run_rollout_service_installed_home
if [[ -n "$_cc_run_rollout_service_installed_home" &&
  ( "$_cc_run_rollout_service_installed_home" == "/" ||
    "$_cc_run_rollout_service_source" == "${_cc_run_rollout_service_installed_home%/}/"* ) ]]; then
  _cc_run_rollout_service_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
  _cc_run_rollout_service_checked_programs="$_cc_run_rollout_service_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_run_rollout_service_checked_programs
# shellcheck disable=SC1090
source "$_cc_run_rollout_service_checked_programs"
cloud_compose_bind_source_program \
  "$_cc_run_rollout_service_source" \
  CLOUD_COMPOSE_PROFILE_PATH \
  /home/cloud-compose/profile.sh \
  "$_cc_run_rollout_service_dir/profile.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
readonly profile_path

# shellcheck disable=SC1090,SC1091
source "$profile_path"

# Reload the fixed resolver after the profile before binding data programs.
# shellcheck disable=SC1090
source "$_cc_run_rollout_service_checked_programs"
cloud_compose_bind_program_dir \
  "$_cc_run_rollout_service_source" \
  CLOUD_COMPOSE_JQ_PROGRAM_DIR \
  /etc/cloud-compose/jq \
  "$_cc_run_rollout_service_dir/../../etc/cloud-compose/jq" \
  json-object-validate.jq

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
  ! jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/json-object-validate.jq" \
    <<<"$CUSTOM_CLAIMS" >/dev/null; then
  echo "ROLLOUT_CUSTOM_CLAIMS must be empty or a JSON object" >&2
  exit 2
fi
export PORT JWKS_URI JWT_AUD CUSTOM_CLAIMS

exec "${CLOUD_COMPOSE_ROLLOUT_BIN:-/usr/local/bin/cloud-compose-rollout}"
