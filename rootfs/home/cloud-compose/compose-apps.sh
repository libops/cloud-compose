#!/usr/bin/env bash

set -euo pipefail

COMPOSE_PROJECTS_FILE="${COMPOSE_PROJECTS_FILE:-/home/cloud-compose/compose-projects.json}"
COMPOSE_APPS_ENV_DIR="${COMPOSE_APPS_ENV_DIR:-/home/cloud-compose/apps}"

shell_env_line() {
    local name="$1"
    local value="$2"

    printf '%s=%q\n' "$name" "$value"
}

compose_app_names() {
    jq -r 'keys[]' "$COMPOSE_PROJECTS_FILE"
}

compose_app_field() {
    local app="$1"
    local field="$2"

    jq -r --arg app "$app" --arg field "$field" '.[$app][$field] // ""' "$COMPOSE_PROJECTS_FILE"
}

compose_app_array() {
    local app="$1"
    local field="$2"

    jq -r --arg app "$app" --arg field "$field" '.[$app][$field][]?' "$COMPOSE_PROJECTS_FILE"
}

compose_app_verify_args() {
    local app="$1"

    jq -r --arg app "$app" '.[$app].sitectl_verify_args // [] | join(" ")' "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_field() {
    local app="$1"
    local field="$2"

    jq -r --arg app "$app" --arg field "$field" '.[$app].ingress[$field] // ""' "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_array() {
    local app="$1"
    local field="$2"

    jq -r --arg app "$app" --arg field "$field" '.[$app].ingress[$field] // [] | .[]?' "$COMPOSE_PROJECTS_FILE"
}

sitectl_truthy() {
    local value
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
        1 | true | yes | y | on | enabled)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

write_compose_app_env() {
    local app="$1"
    local env_file="${COMPOSE_APPS_ENV_DIR}/${app}.env"

    mkdir -p "$COMPOSE_APPS_ENV_DIR"
    {
        shell_env_line APP_NAME "$app"
        shell_env_line DOCKER_COMPOSE_REPO "$(compose_app_field "$app" docker_compose_repo)"
        shell_env_line DOCKER_COMPOSE_BRANCH "$(compose_app_field "$app" docker_compose_branch)"
        shell_env_line DOCKER_COMPOSE_DIR "$(compose_app_field "$app" project_dir)"
        shell_env_line COMPOSE_PROJECT_NAME "$(compose_app_field "$app" compose_project_name)"
        shell_env_line COMPOSE_BIND_PORT "$(compose_app_field "$app" ingress_port)"
        shell_env_line SITECTL_CONTEXT_NAME "$(compose_app_field "$app" sitectl_context_name)"
        shell_env_line SITECTL_PLUGIN "$(compose_app_field "$app" sitectl_plugin)"
        shell_env_line SITECTL_ENVIRONMENT "$(compose_app_field "$app" sitectl_environment)"
        shell_env_line SITECTL_VERIFY_ARGS "$(compose_app_verify_args "$app")"
    } > "$env_file"
    chown cloud-compose:cloud-compose "$env_file" 2>/dev/null || true
    chmod 0640 "$env_file"
}

source_compose_app_env() {
    local app="$1"

    write_compose_app_env "$app"
    set -a
    # shellcheck disable=SC1090
    source "${COMPOSE_APPS_ENV_DIR}/${app}.env"
    set +a
}

target_compose_apps() {
    local lifecycle="$1"
    local target="${CLOUD_COMPOSE_APP:-${COMPOSE_APP:-${APP_NAME:-}}}"

    if [ -z "$target" ] && [ "$lifecycle" = "rollout" ]; then
        target="${CLOUD_COMPOSE_PRIMARY_APP:-}"
    fi

    if [ -n "$target" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    compose_app_names
}

clone_or_update_compose_app() {
    local app="$1"

    source_compose_app_env "$app"

    git config --global --add safe.directory "$DOCKER_COMPOSE_DIR"

    if [ ! -d "$DOCKER_COMPOSE_DIR/.git" ]; then
        echo "Directory '$DOCKER_COMPOSE_DIR' not found. Cloning repository for ${app}."
        mkdir -p "$DOCKER_COMPOSE_DIR"
        pushd "$DOCKER_COMPOSE_DIR" >/dev/null
        retry_until_success git clone -b "$DOCKER_COMPOSE_BRANCH" "$DOCKER_COMPOSE_REPO" .
        if [ "$(id -u)" -eq 0 ]; then
            chown -R cloud-compose:cloud-compose .
        fi
        popd >/dev/null
    else
        pushd "$DOCKER_COMPOSE_DIR" >/dev/null
        retry_until_success git pull origin "$DOCKER_COMPOSE_BRANCH"
        popd >/dev/null
    fi
}

configure_sitectl_app_features() {
    local app="$1"
    local letsencrypt bot_mitigation mode domain acme_email max_upload_size upload_timeout
    local configure_ingress=false
    local changed=false
    local trusted_ip

    source_compose_app_env "$app"

    letsencrypt="$(compose_app_ingress_field "$app" letsencrypt)"
    bot_mitigation="$(compose_app_ingress_field "$app" bot_mitigation)"
    mode="$(compose_app_ingress_field "$app" mode)"
    domain="$(compose_app_ingress_field "$app" domain)"
    acme_email="$(compose_app_ingress_field "$app" acme_email)"
    max_upload_size="$(compose_app_ingress_field "$app" max_upload_size)"
    upload_timeout="$(compose_app_ingress_field "$app" upload_timeout)"

    if sitectl_truthy "$letsencrypt" && [ -z "$mode" ]; then
        mode="https-letsencrypt"
    fi

    local ingress_args=(set ingress enabled --context "$SITECTL_CONTEXT_NAME" --yolo)
    if [ -n "$mode" ]; then
        ingress_args+=(--mode "$mode")
        configure_ingress=true
    fi
    if [ -n "$domain" ]; then
        ingress_args+=(--domain "$domain")
        configure_ingress=true
    fi
    if [ -n "$acme_email" ]; then
        ingress_args+=(--acme-email "$acme_email")
        configure_ingress=true
    fi
    while IFS= read -r trusted_ip; do
        if [ -n "$trusted_ip" ]; then
            ingress_args+=(--trusted-ip "$trusted_ip")
            configure_ingress=true
        fi
    done < <(compose_app_ingress_array "$app" trusted_ips)
    if [ -n "$max_upload_size" ]; then
        ingress_args+=(--max-upload-size "$max_upload_size")
        configure_ingress=true
    fi
    if [ -n "$upload_timeout" ]; then
        ingress_args+=(--upload-timeout "$upload_timeout")
        configure_ingress=true
    fi

    if [ "$configure_ingress" = true ]; then
        sitectl "${ingress_args[@]}"
        changed=true
    fi
    if sitectl_truthy "$bot_mitigation"; then
        sitectl set bot-mitigation on --context "$SITECTL_CONTEXT_NAME" --yolo
        changed=true
    fi
    if [ "$changed" = true ]; then
        sitectl converge --context "$SITECTL_CONTEXT_NAME" --yolo
    fi
}

run_compose_app_lifecycle() {
    local app="$1"
    local lifecycle="$2"
    local field="${lifecycle}_commands"
    local command

    if [ "$lifecycle" != "down" ]; then
        clone_or_update_compose_app "$app"
    else
        source_compose_app_env "$app"
    fi

    echo "Running cloud-compose ${lifecycle} for ${app}"
    pushd "$DOCKER_COMPOSE_DIR" >/dev/null
    while IFS= read -r command; do
        if [ -z "$command" ]; then
            continue
        fi
        bash -c "$command"
    done < <(compose_app_array "$app" "$field")
    popd >/dev/null
}
