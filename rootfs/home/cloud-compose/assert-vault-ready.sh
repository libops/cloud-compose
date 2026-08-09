#!/usr/bin/env bash

set -euo pipefail

_cc_assert_vault_ready_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_assert_vault_ready_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_assert_vault_ready_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_assert_vault_ready_source _cc_assert_vault_ready_dir _cc_assert_vault_ready_installed_home
if [[ -n "$_cc_assert_vault_ready_installed_home" &&
    ( "$_cc_assert_vault_ready_installed_home" == "/" ||
        "$_cc_assert_vault_ready_source" == "${_cc_assert_vault_ready_installed_home%/}/"* ) ]]; then
    _cc_assert_vault_ready_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_assert_vault_ready_checked_programs="$_cc_assert_vault_ready_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_assert_vault_ready_checked_programs
# shellcheck disable=SC1090
source "$_cc_assert_vault_ready_checked_programs"
cloud_compose_bind_source_program \
    "$_cc_assert_vault_ready_source" \
    CLOUD_COMPOSE_PROFILE_PATH \
    /home/cloud-compose/profile.sh \
    "$_cc_assert_vault_ready_dir/profile.sh"
profile_path="$CLOUD_COMPOSE_PROFILE_PATH"
readonly profile_path

# shellcheck disable=SC1090
source "$profile_path"

case "${VAULT_AGENT_ENABLED:-false}" in
    false) exit 0 ;;
    true) ;;
    *)
        echo "VAULT_AGENT_ENABLED must be true or false" >&2
        exit 1
        ;;
esac

ready_marker="${VAULT_AGENT_READY_MARKER:-/run/cloud-compose/vault-agent.ready}"
if [[ -L "$ready_marker" || ! -f "$ready_marker" ]]; then
    echo "Vault Agent is enabled but has not published readiness" >&2
    exit 1
fi
if ! systemctl is-active --quiet cloud-compose-vault-agent.service; then
    echo "Vault Agent is enabled but its service is not active" >&2
    exit 1
fi
