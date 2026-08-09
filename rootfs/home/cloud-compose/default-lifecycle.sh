#!/usr/bin/env bash

set -euo pipefail

_cc_default_lifecycle_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_default_lifecycle_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_default_lifecycle_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_default_lifecycle_source _cc_default_lifecycle_dir _cc_default_lifecycle_installed_home
if [[ -n "$_cc_default_lifecycle_installed_home" &&
    ( "$_cc_default_lifecycle_installed_home" == "/" ||
        "$_cc_default_lifecycle_source" == "${_cc_default_lifecycle_installed_home%/}/"* ) ]]; then
    _cc_default_lifecycle_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_default_lifecycle_checked_programs="$_cc_default_lifecycle_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_default_lifecycle_checked_programs
# shellcheck disable=SC1090
source "$_cc_default_lifecycle_checked_programs"
cloud_compose_bind_program \
    "$_cc_default_lifecycle_source" \
    CLOUD_COMPOSE_SITECTL_VERIFY_ARGS_PROGRAM \
    /etc/cloud-compose/jq/sitectl-verify-args.jq \
    "$_cc_default_lifecycle_dir/../../etc/cloud-compose/jq/sitectl-verify-args.jq"
sitectl_verify_args_program="$CLOUD_COMPOSE_SITECTL_VERIFY_ARGS_PROGRAM"
readonly sitectl_verify_args_program

action="${1:-}"
if [[ "$#" -ne 1 ]]; then
    echo "usage: default-lifecycle.sh init|up|down|rollout" >&2
    exit 2
fi

case "$action" in
    init | up | down | rollout) ;;
    *)
        echo "unknown default lifecycle action: $action" >&2
        exit 2
        ;;
esac

context="${SITECTL_CONTEXT_NAME:?SITECTL_CONTEXT_NAME is required}"

run_sitectl() {
    if [[ -n "${SITECTL_EXECUTABLE:-}" ]]; then
        "${SITECTL_EXECUTABLE}" "$@"
        return
    fi
    command sitectl "$@"
}

verify_nonproduction() {
    local encoded decoded encoded_args
    local -a verify_args=()

    if [[ "${SITECTL_ENVIRONMENT:?SITECTL_ENVIRONMENT is required}" != "production" ]]; then
        if ! encoded_args="$(jq -r -f "$sitectl_verify_args_program" \
            <<<"${SITECTL_VERIFY_ARGS_JSON:-[]}")"; then
            echo "SITECTL_VERIFY_ARGS_JSON must be an array of strings" >&2
            return 1
        fi
        while IFS= read -r encoded; do
            [[ -n "$encoded" ]] || continue
            decoded="$(printf '%s' "${encoded#x}" | base64 -d)"
            verify_args+=("$decoded")
        done <<<"$encoded_args"
        run_sitectl verify --context "$context" "${verify_args[@]}"
    fi
}

case "$action" in
    init)
        run_sitectl config set-context "$context" \
            --type local \
            --project-dir "${DOCKER_COMPOSE_DIR:?DOCKER_COMPOSE_DIR is required}" \
            --site "${CLOUD_COMPOSE_INSTANCE_NAME:?CLOUD_COMPOSE_INSTANCE_NAME is required}" \
            --plugin "${SITECTL_PLUGIN:?SITECTL_PLUGIN is required}" \
            --environment "${SITECTL_ENVIRONMENT:?SITECTL_ENVIRONMENT is required}" \
            --compose-project-name "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}" \
            --docker-socket /var/run/docker.sock \
            --env-file .env \
            --yolo \
            --default
        ;;
    up)
        run_sitectl compose --context "$context" up -d --remove-orphans
        run_sitectl healthcheck --context "$context" --persist
        verify_nonproduction
        ;;
    down)
        run_sitectl compose --context "$context" down
        ;;
    rollout)
        commit_sha="${GIT_COMMIT_SHA:-}"
        if [[ -n "$commit_sha" && ! "$commit_sha" =~ ^[0-9a-f]{40}$ ]]; then
            echo "GIT_COMMIT_SHA must be an exact lowercase 40-character commit SHA" >&2
            exit 2
        fi
        target_ref="${commit_sha:-${GIT_REF:-${GIT_BRANCH:-}}}"
        if [[ -n "$target_ref" ]]; then
            run_sitectl deploy --context "$context" --ref "$target_ref"
        else
            run_sitectl deploy --context "$context" --skip-git
        fi
        run_sitectl healthcheck --context "$context" --persist
        verify_nonproduction
        ;;
esac
