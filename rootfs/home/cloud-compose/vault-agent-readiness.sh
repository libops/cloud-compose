#!/usr/bin/env bash

set -euo pipefail

profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-/home/cloud-compose/profile.sh}"
# shellcheck disable=SC1090
source "$profile_path"

READY_MARKER="/run/cloud-compose/vault-agent.ready"
DEFAULT_TOKEN_PATH="/mnt/disks/data/vault/token"

vault_safe_dir() {
    printf '/mnt/disks/data/vault\n'
}

validate_vault_token_path() {
    local safe_dir safe_parent canonical_parent token_path token_name

    safe_dir="$(vault_safe_dir)"
    safe_parent="$(dirname -- "$safe_dir")"
    token_path="${VAULT_AGENT_TOKEN_PATH:-$DEFAULT_TOKEN_PATH}"
    token_name="$(basename -- "$token_path")"

    if [[ "$token_path" != "$safe_dir/$token_name" ||
        ! "$token_name" =~ ^[A-Za-z0-9._-]+$ || "$token_name" == "." || "$token_name" == ".." ]]; then
        echo "Vault Agent token path must be one file directly inside $safe_dir" >&2
        return 1
    fi
    if [[ ! -d "$safe_parent" || -L "$safe_parent" ]]; then
        echo "Vault Agent safe-directory parent is missing or unsafe: $safe_parent" >&2
        return 1
    fi
    canonical_parent="$(readlink -f -- "$safe_parent")" || return 1
    if [[ "$canonical_parent" != "$safe_parent" ]]; then
        echo "Vault Agent safe-directory parent contains a symbolic-link traversal" >&2
        return 1
    fi
    if [[ -L "$safe_dir" || ( -e "$safe_dir" && ! -d "$safe_dir" ) ]]; then
        echo "Vault Agent safe directory is not a regular directory: $safe_dir" >&2
        return 1
    fi
    if [[ -L "$token_path" || ( -e "$token_path" && ! -f "$token_path" ) ]]; then
        echo "Vault Agent token target is unsafe: $token_path" >&2
        return 1
    fi

    VAULT_SAFE_DIR="$safe_dir"
    VAULT_TOKEN_PATH="$token_path"
}

prepare_vault_agent() {
    validate_vault_token_path || return 1
    rm -f -- "$READY_MARKER"
    # A pre-existing sink token does not prove the replacement agent has
    # authenticated. Remove only the validated dedicated token file so
    # ExecStartPost must observe a fresh write from this start.
    rm -f -- "$VAULT_TOKEN_PATH"
    install -d -m 0700 -o root -g root -- "$VAULT_SAFE_DIR"
    if [[ -L "$VAULT_SAFE_DIR" || ! -d "$VAULT_SAFE_DIR" ]]; then
        echo "Vault Agent safe directory changed during preparation" >&2
        return 1
    fi
}

wait_for_vault_agent() {
    local timeout_seconds deadline

    validate_vault_token_path || return 1
    timeout_seconds="${VAULT_AGENT_START_TIMEOUT_SECONDS:-60}"
    if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || ((10#$timeout_seconds > 300)); then
        echo "VAULT_AGENT_START_TIMEOUT_SECONDS must be an integer from 1 through 300" >&2
        return 2
    fi
    deadline=$((SECONDS + 10#$timeout_seconds))
    while ((SECONDS < deadline)); do
        if [[ ! -L "$VAULT_TOKEN_PATH" && -f "$VAULT_TOKEN_PATH" && -s "$VAULT_TOKEN_PATH" ]]; then
            install -d -m 0755 -- "$(dirname -- "$READY_MARKER")"
            : >"$READY_MARKER"
            chmod 0644 "$READY_MARKER"
            return 0
        fi
        sleep 1
    done
    echo "Vault Agent did not publish a token within ${timeout_seconds}s" >&2
    return 1
}

clear_vault_agent_ready() {
    rm -f -- "$READY_MARKER"
}

main() {
    case "${1:-}" in
        prepare) prepare_vault_agent ;;
        wait) wait_for_vault_agent ;;
        clear) clear_vault_agent_ready ;;
        *)
            echo "Usage: $0 prepare|wait|clear" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
