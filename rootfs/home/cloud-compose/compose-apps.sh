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

random_chars() {
    local chars="$1"
    local length="$2"
    local value=""

    while [ "${#value}" -lt "$length" ]; do
        value="${value}$(openssl rand -base64 "$((length * 2))" | tr -dc "$chars")"
    done

    printf '%s' "${value:0:length}"
}

random_secret() {
    local length="$1"

    random_chars 'A-Za-z0-9' "$length"
}

scaffold_secret_file() {
    local file="$1"
    local mode="${2:-0640}"

    if [ -s "$file" ]; then
        return 0
    fi

    install -d -m 0700 "$(dirname "$file")"
    echo "Creating scaffold secret: ${file}" >&2
    random_secret 32 > "$file"
    chmod "$mode" "$file"
}

scaffold_drupal_salt() {
    local file="$1"

    if [ -s "$file" ]; then
        return 0
    fi

    install -d -m 0700 "$(dirname "$file")"
    echo "Creating scaffold secret: ${file}" >&2
    random_chars 'A-Za-z0-9_-' 74 > "$file"
    chmod 0640 "$file"
}

scaffold_jwt_keys() {
    local private_key="${1:-./secrets/JWT_PRIVATE_KEY}"
    local public_key="${2:-./secrets/JWT_PUBLIC_KEY}"

    install -d -m 0700 "$(dirname "$private_key")"
    if [ ! -s "$private_key" ]; then
        echo "Creating scaffold secret: ${private_key}" >&2
        openssl genrsa 2048 > "$private_key" 2>/dev/null
        chmod 0640 "$private_key"
    fi
    if [ ! -s "$public_key" ]; then
        echo "Creating scaffold secret: ${public_key}" >&2
        openssl rsa -pubout < "$private_key" > "$public_key" 2>/dev/null
        chmod 0644 "$public_key"
    fi
}

scaffold_local_certs() {
    local cert_dir="${1:-./certs}"
    local openssl_config

    if [ -s "${cert_dir}/cert.pem" ] && [ -s "${cert_dir}/rootCA.pem" ]; then
        return 0
    fi

    install -d -m 0755 "$cert_dir"
    openssl_config="$(mktemp)"
    cat > "$openssl_config" <<'EOF'
[req]
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
CN = localhost

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *.localhost
DNS.3 = islandora.io
DNS.4 = *.islandora.io
DNS.5 = islandora.info
DNS.6 = *.islandora.info
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

    if [ ! -s "${cert_dir}/rootCA-key.pem" ] || [ ! -s "${cert_dir}/rootCA.pem" ]; then
        echo "Creating scaffold certificate authority in ${cert_dir}" >&2
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "${cert_dir}/rootCA-key.pem" \
            -out "${cert_dir}/rootCA.pem" \
            -subj "/CN=cloud-compose local root" \
            -days 3650 >/dev/null 2>&1
    fi

    if [ ! -s "${cert_dir}/privkey.pem" ] || [ ! -s "${cert_dir}/cert.pem" ]; then
        echo "Creating scaffold certificate in ${cert_dir}" >&2
        openssl req -newkey rsa:2048 -nodes \
            -keyout "${cert_dir}/privkey.pem" \
            -out "${cert_dir}/cert.csr" \
            -config "$openssl_config" >/dev/null 2>&1
        openssl x509 -req \
            -in "${cert_dir}/cert.csr" \
            -CA "${cert_dir}/rootCA.pem" \
            -CAkey "${cert_dir}/rootCA-key.pem" \
            -CAcreateserial \
            -out "${cert_dir}/cert.pem" \
            -days 825 \
            -sha256 \
            -extensions v3_req \
            -extfile "$openssl_config" >/dev/null 2>&1
        rm -f "${cert_dir}/cert.csr"
    fi

    rm -f "$openssl_config"
    chmod 0644 "${cert_dir}/cert.pem" "${cert_dir}/rootCA.pem"
    chmod 0640 "${cert_dir}/privkey.pem" "${cert_dir}/rootCA-key.pem" 2>/dev/null || true
}

compose_secret_files() {
    local compose_file

    for compose_file in docker-compose.yaml docker-compose.yml; do
        if [ ! -f "$compose_file" ]; then
            continue
        fi

        awk '
          /^[[:space:]]*services:/ { in_secrets = 0 }
          /^[^[:space:]][^:]*:/ {
            if ($0 ~ /^secrets:/) {
              in_secrets = 1
            } else if (in_secrets) {
              in_secrets = 0
            }
          }
          in_secrets && /^[[:space:]]*file:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]*file:[[:space:]]*/, "", value)
            gsub(/^["'\'']|["'\'']$/, "", value)
            print value
          }
        ' "$compose_file"
    done | sort -u
}

scaffold_compose_app_defaults() {
    local app="$1"
    local file base generated=false

    echo "Scaffolding default compose files for ${app}"
    while IFS= read -r file; do
        if [ -z "$file" ]; then
            continue
        fi

        generated=true
        base="$(basename "$file")"
        case "$file" in
            ./*) ;;
            *) file="./${file}" ;;
        esac

        case "$base" in
            cert.pem | rootCA.pem | privkey.pem | rootCA-key.pem)
                scaffold_local_certs "$(dirname "$file")"
                ;;
            UID)
                install -d -m 0755 "$(dirname "$file")"
                id -u > "$file"
                chmod 0644 "$file"
                ;;
            DRUPAL_DEFAULT_SALT)
                scaffold_drupal_salt "$file"
                ;;
            JWT_PRIVATE_KEY)
                scaffold_jwt_keys "$file" "./secrets/JWT_PUBLIC_KEY"
                ;;
            JWT_PUBLIC_KEY)
                scaffold_jwt_keys "./secrets/JWT_PRIVATE_KEY" "$file"
                ;;
            *)
                scaffold_secret_file "$file"
                ;;
        esac
    done < <(compose_secret_files)

    if [ "$generated" = false ]; then
        echo "No compose secret files declared for ${app}"
    fi
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
