#!/usr/bin/env bash

set -euo pipefail

_cc_rotate_keys_daily_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_rotate_keys_daily_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_rotate_keys_daily_source script_dir _cc_rotate_keys_daily_installed_home
if [[ -n "$_cc_rotate_keys_daily_installed_home" &&
  ( "$_cc_rotate_keys_daily_installed_home" == "/" ||
    "$_cc_rotate_keys_daily_source" == "${_cc_rotate_keys_daily_installed_home%/}/"* ) ]]; then
  _cc_rotate_keys_daily_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
  _cc_rotate_keys_daily_checked_programs="$script_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_rotate_keys_daily_checked_programs
# shellcheck disable=SC1090
source "$_cc_rotate_keys_daily_checked_programs"
cloud_compose_bind_source_program \
  "$_cc_rotate_keys_daily_source" CLOUD_COMPOSE_PROFILE_PATH \
  /home/cloud-compose/profile.sh "$script_dir/profile.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
readonly profile_path

# shellcheck disable=SC1090
source "$profile_path"

case "${CLOUD_COMPOSE_PROVIDER:-}" in
  gcp)
    ;;
  "")
    echo "CLOUD_COMPOSE_PROVIDER is required for service-account key rotation" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac

case "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" in
  true) bash "$script_dir/rotate-keys-internal.sh" ;;
  false) ;;
  *)
    echo "LIBOPS_INTERNAL_SERVICES_ENABLED must be true or false" >&2
    exit 2
    ;;
esac

# The app wrapper is also the fail-closed stale-credential check when managed
# file credentials are disabled, so run it in both states.
bash "$script_dir/rotate-keys-app.sh"
