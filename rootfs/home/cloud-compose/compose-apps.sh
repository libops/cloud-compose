#!/usr/bin/env bash

set -euo pipefail

COMPOSE_PROJECTS_FILE="${COMPOSE_PROJECTS_FILE:-/home/cloud-compose/compose-projects.json}"
COMPOSE_APPS_ENV_DIR="${COMPOSE_APPS_ENV_DIR:-/home/cloud-compose/apps}"
COMPOSE_APPS_STATE_DIR="${COMPOSE_APPS_STATE_DIR:-/home/cloud-compose/state}"
CLOUD_COMPOSE_DATA_ROOT="${CLOUD_COMPOSE_DATA_ROOT:-/mnt/disks/data}"

shell_env_line() {
    local name="$1"
    local value="$2"

    printf '%s=%q\n' "$name" "$value"
}

validate_compose_app_name() {
    local app="$1"

    if [[ ! "$app" =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo "Invalid cloud-compose app name: $app" >&2
        return 1
    fi
}

validate_compose_project_dir() {
    local project_dir="$1"
    local data_root resolved_project_dir resolved_data_root

    data_root="${CLOUD_COMPOSE_DATA_ROOT%/}"
    [[ -n "$data_root" && "$data_root" == /* && "$project_dir" == /* ]] || {
        echo "Compose project directory must be absolute: $project_dir" >&2
        return 1
    }
    [[ "$project_dir" != "$data_root" && "$project_dir" == "$data_root/"* ]] || {
        echo "Compose project directory is outside the managed data boundary: $project_dir" >&2
        return 1
    }
    [[ ! "$project_dir" =~ [[:cntrl:]] && "$project_dir" != *"//"* && "$project_dir" != */ ]] || {
        echo "Compose project directory contains an unsafe segment: $project_dir" >&2
        return 1
    }
    [[ ! "$project_dir" =~ (^|/)\.\.?(/|$) ]] || {
        echo "Compose project directory contains a dot segment: $project_dir" >&2
        return 1
    }

    resolved_data_root="$(realpath -m -- "$data_root")" || return 1
    resolved_project_dir="$(realpath -m -- "$project_dir")" || return 1
    [[ "$resolved_project_dir" == "$resolved_data_root/"* ]] || {
        echo "Compose project directory resolves outside the managed data boundary: $project_dir" >&2
        return 1
    }
}

validate_compose_projects_manifest() {
    if [[ -L "$COMPOSE_PROJECTS_FILE" || ! -f "$COMPOSE_PROJECTS_FILE" ]]; then
        echo "Cloud-compose project manifest is missing or unsafe: $COMPOSE_PROJECTS_FILE" >&2
        return 1
    fi

    if ! jq -e '
        type == "object" and length > 0 and
        all(to_entries[]; . as $entry |
            ($entry.key | explode | index(0) == null) and
            ($entry.value | type == "object") and
            (all($entry.value | .. | select(type == "string");
                explode | index(0) == null)) and
            ($entry.value.docker_compose_repo | type == "string" and length > 0) and
            ($entry.value.docker_compose_branch | type == "string" and length > 0) and
            ($entry.value.project_dir | type == "string" and length > 0) and
            ($entry.value.compose_project_name | type == "string" and length > 0) and
            (all(["init_commands", "up_commands", "down_commands", "rollout_commands"][];
                . as $field |
                    ($entry.value[$field] == null) or
                    (($entry.value[$field] | type) == "array" and all($entry.value[$field][]; type == "string"))
            )) and
            (($entry.value.sitectl_verify_args == null) or
                (($entry.value.sitectl_verify_args | type) == "array" and all($entry.value.sitectl_verify_args[];
                    type == "string" and
                    (explode | index(0) == null) and
                    (contains("\n") | not) and
                    (contains("\r") | not)
                ))) and
            (($entry.value.ingress == null) or ($entry.value.ingress | type == "object"))
        )
    ' "$COMPOSE_PROJECTS_FILE" >/dev/null; then
        echo "Invalid cloud-compose project manifest: $COMPOSE_PROJECTS_FILE" >&2
        return 1
    fi

    local encoded_app app encoded_project_dir project_dir
    while IFS= read -r encoded_app; do
        app="$(
            if ! printf '%s' "$encoded_app" | base64 --decode; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        app="${app%$'\x1f'}"
        validate_compose_app_name "$app" || return 1
    done < <(jq -r 'keys[] | @base64' "$COMPOSE_PROJECTS_FILE")

    while IFS= read -r encoded_project_dir; do
        project_dir="$(
            if ! printf '%s' "$encoded_project_dir" | base64 --decode; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        project_dir="${project_dir%$'\x1f'}"
        validate_compose_project_dir "$project_dir" || return 1
    done < <(jq -r '.[] | .project_dir | @base64' "$COMPOSE_PROJECTS_FILE")
}

compose_app_exists() {
    local app="$1"

    validate_compose_app_name "$app" || return 1
    validate_compose_projects_manifest || return 1
    jq -e --arg app "$app" 'has($app)' "$COMPOSE_PROJECTS_FILE" >/dev/null || {
        echo "Cloud-compose app is not present in the manifest: $app" >&2
        return 1
    }
}

compose_app_names_array() {
    local result_name="$1"
    local names app
    local -n "result=$result_name"

    validate_compose_projects_manifest || return 1
    names="$(jq -er 'keys[]' "$COMPOSE_PROJECTS_FILE")" || return 1
    result=()
    while IFS= read -r app; do
        validate_compose_app_name "$app" || return 1
        result+=("$app")
    done <<<"$names"
}

compose_app_names() {
    local -a apps=()

    compose_app_names_array apps || return 1
    printf '%s\n' "${apps[@]}"
}

compose_app_field() {
    local app="$1"
    local field="$2"

    compose_app_exists "$app" || return 1
    jq -er --arg app "$app" --arg field "$field" '
        (.[$app][$field] // "" | tostring) as $value |
        if $value | (explode | index(0) != null) or contains("\n") or contains("\r") then
            error("invalid scalar field")
        else
            $value
        end
    ' "$COMPOSE_PROJECTS_FILE"
}

compose_app_array_values() {
    local app="$1"
    local field="$2"
    local result_name="$3"
    local payload encoded_lines encoded value
    local -n "result=$result_name"

    compose_app_exists "$app" || return 1
    payload="$(jq -ce --arg app "$app" --arg field "$field" '
        (.[$app][$field] // []) as $values |
        if ($values | type) != "array" or any($values[]; type != "string") then
            error("invalid string array")
        else
            $values
        end
    ' "$COMPOSE_PROJECTS_FILE")" || {
        echo "Invalid $field array for cloud-compose app $app" >&2
        return 1
    }

    result=()
    encoded_lines="$(jq -r '.[] | @base64' <<<"$payload")" || return 1
    if [[ -z "$encoded_lines" ]]; then
        return 0
    fi
    while IFS= read -r encoded; do
        value="$(
            if ! printf '%s' "$encoded" | base64 -d; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        value="${value%$'\x1f'}"
        result+=("$value")
    done <<<"$encoded_lines"
}

compose_app_array() {
    local app="$1"
    local field="$2"
    local value
    local -a values=()

    compose_app_array_values "$app" "$field" values || return 1
    for value in "${values[@]}"; do
        printf '%s\n' "$value"
    done
}

compose_app_verify_args() {
    local app="$1"

    compose_app_exists "$app" || return 1
    jq -er --arg app "$app" '
        (.[$app].sitectl_verify_args // []) as $values |
        if ($values | type) != "array" or any($values[]; type != "string") then
            error("invalid verify args")
        else
            $values | join(" ")
        end
    ' "$COMPOSE_PROJECTS_FILE"
}

compose_app_verify_args_json() {
    local app="$1"

    compose_app_exists "$app" || return 1
    jq -cer --arg app "$app" '
        (.[$app].sitectl_verify_args // []) as $values |
        if ($values | type) != "array" or any($values[];
            type != "string" or (explode | index(0) != null) or contains("\n") or contains("\r")
        ) then
            error("invalid verify args")
        else
            $values
        end
    ' "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_field() {
    local app="$1"
    local field="$2"

    compose_app_exists "$app" || return 1
    jq -er --arg app "$app" --arg field "$field" '
        (.[$app].ingress[$field] // "" | tostring) as $value |
        if $value | (explode | index(0) != null) or contains("\n") or contains("\r") then
            error("invalid ingress scalar field")
        else
            $value
        end
    ' "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_array_values() {
    local app="$1"
    local field="$2"
    local result_name="$3"
    local payload encoded_lines encoded value
    local -n "result=$result_name"

    compose_app_exists "$app" || return 1
    payload="$(jq -ce --arg app "$app" --arg field "$field" '
        (.[$app].ingress[$field] // []) as $values |
        if ($values | type) != "array" or any($values[]; type != "string") then
            error("invalid ingress string array")
        else
            $values
        end
    ' "$COMPOSE_PROJECTS_FILE")" || {
        echo "Invalid ingress $field array for cloud-compose app $app" >&2
        return 1
    }

    result=()
    encoded_lines="$(jq -r '.[] | @base64' <<<"$payload")" || return 1
    if [[ -z "$encoded_lines" ]]; then
        return 0
    fi
    while IFS= read -r encoded; do
        value="$(
            if ! printf '%s' "$encoded" | base64 -d; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        value="${value%$'\x1f'}"
        result+=("$value")
    done <<<"$encoded_lines"
}

compose_app_ingress_array() {
    local app="$1"
    local field="$2"
    local value
    local -a values=()

    compose_app_ingress_array_values "$app" "$field" values || return 1
    for value in "${values[@]}"; do
        printf '%s\n' "$value"
    done
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
    local env_tmp

    compose_app_exists "$app" || return 1
    install -d -m 0750 "$COMPOSE_APPS_ENV_DIR"
    env_tmp="$(mktemp "${env_file}.tmp.XXXXXX")" || return 1
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
        # SITECTL_VERIFY_ARGS remains an empty compatibility scalar. Lifecycle
        # shells use the JSON array below through an exported sitectl wrapper so
        # an argument containing spaces remains exactly one argv element.
        shell_env_line SITECTL_VERIFY_ARGS ""
        shell_env_line SITECTL_VERIFY_ARGS_JSON "$(compose_app_verify_args_json "$app")"
    } > "$env_tmp"
    chown cloud-compose:cloud-compose "$env_tmp" 2>/dev/null || true
    chmod 0640 "$env_tmp"
    mv -f -- "$env_tmp" "$env_file"
}

source_compose_app_env() {
    local app="$1"

    compose_app_exists "$app" || return 1
    if ((EUID != 0)); then
        write_compose_app_env "$app" || return 1
    fi

    # Privileged callers must never source a shell file from the app-writable
    # env directory. Materialize the same validated manifest values as data.
    APP_NAME="$app"
    DOCKER_COMPOSE_REPO="$(compose_app_field "$app" docker_compose_repo)"
    DOCKER_COMPOSE_BRANCH="$(compose_app_field "$app" docker_compose_branch)"
    DOCKER_COMPOSE_DIR="$(compose_app_field "$app" project_dir)"
    COMPOSE_PROJECT_NAME="$(compose_app_field "$app" compose_project_name)"
    COMPOSE_BIND_PORT="$(compose_app_field "$app" ingress_port)"
    SITECTL_CONTEXT_NAME="$(compose_app_field "$app" sitectl_context_name)"
    SITECTL_PLUGIN="$(compose_app_field "$app" sitectl_plugin)"
    SITECTL_ENVIRONMENT="$(compose_app_field "$app" sitectl_environment)"
    SITECTL_VERIFY_ARGS=""
    SITECTL_VERIFY_ARGS_JSON="$(compose_app_verify_args_json "$app")"
    export APP_NAME DOCKER_COMPOSE_REPO DOCKER_COMPOSE_BRANCH DOCKER_COMPOSE_DIR
    export COMPOSE_PROJECT_NAME COMPOSE_BIND_PORT SITECTL_CONTEXT_NAME SITECTL_PLUGIN
    export SITECTL_ENVIRONMENT SITECTL_VERIFY_ARGS SITECTL_VERIFY_ARGS_JSON
}

configure_sitectl_verify_argv() {
    # Resolve eagerly when available, but allow lifecycle command sets that do
    # not invoke sitectl (for example a source-policy contract). The exported
    # wrapper fails at the actual call site if the executable is missing.
    SITECTL_EXECUTABLE="$(type -P sitectl || true)"
    if ! jq -e 'type == "array" and all(.[]; type == "string")' \
        <<<"${SITECTL_VERIFY_ARGS_JSON:-[]}" >/dev/null; then
        echo "Invalid sitectl verify argument JSON for ${APP_NAME:-unknown app}" >&2
        return 1
    fi

    sitectl() {
        local encoded decoded executable
        local -a configured_verify_args=()

        executable="${SITECTL_EXECUTABLE:-}"
        if [[ -z "$executable" ]]; then
            executable="$(type -P sitectl || true)"
        fi
        if [[ -z "$executable" ]]; then
            echo "sitectl is not installed" >&2
            return 127
        fi
        if [[ "${1:-}" == "verify" ]]; then
            while IFS= read -r encoded; do
                [[ -n "$encoded" ]] || continue
                decoded="$(printf '%s' "$encoded" | base64 -d)" || return 1
                configured_verify_args+=("$decoded")
            done < <(jq -r '.[] | @base64' <<<"${SITECTL_VERIFY_ARGS_JSON:-[]}")
        fi
        "$executable" "$@" "${configured_verify_args[@]}"
    }
    export SITECTL_EXECUTABLE SITECTL_VERIFY_ARGS SITECTL_VERIFY_ARGS_JSON
    export -f sitectl
}

target_compose_apps() {
    local lifecycle="$1"
    local -a apps=()

    target_compose_apps_array "$lifecycle" apps || return 1
    printf '%s\n' "${apps[@]}"
}

target_compose_apps_array() {
    local lifecycle="$1"
    local result_name="$2"
    local target="${CLOUD_COMPOSE_APP:-${COMPOSE_APP:-${APP_NAME:-}}}"
    local -n "result=$result_name"

    if [[ -z "$target" && "$lifecycle" == "rollout" ]]; then
        target="${CLOUD_COMPOSE_PRIMARY_APP:-}"
    fi
    if [[ -n "$target" ]]; then
        compose_app_exists "$target" || return 1
        result=("$target")
        return 0
    fi
    compose_app_names_array "$result_name"
}

compose_ref_is_full_commit() {
    [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

validate_compose_git_source() {
    validate_compose_project_dir "$DOCKER_COMPOSE_DIR" || return 1
    if [[ -z "$DOCKER_COMPOSE_REPO" || "$DOCKER_COMPOSE_REPO" == -* ||
        "$DOCKER_COMPOSE_REPO" == *$'\n'* || "$DOCKER_COMPOSE_REPO" == *$'\r'* ]]; then
        echo "Invalid Compose repository location for $DOCKER_COMPOSE_DIR" >&2
        return 1
    fi
    if compose_ref_is_full_commit "$DOCKER_COMPOSE_BRANCH"; then
        return 0
    fi
    if [[ "$DOCKER_COMPOSE_BRANCH" == -* ]] ||
        ! git check-ref-format "refs/cloud-compose/$DOCKER_COMPOSE_BRANCH" >/dev/null 2>&1; then
        echo "Invalid Compose Git ref: $DOCKER_COMPOSE_BRANCH" >&2
        return 1
    fi
}

record_compose_app_head() {
    local app="$1"
    local head state_file state_tmp

    validate_compose_app_name "$app" || return 1
    head="$(git rev-parse --verify HEAD)"
    if [[ ! "$head" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Could not resolve a full deployed Git commit for ${app}" >&2
        return 1
    fi

    install -d -m 0750 "$COMPOSE_APPS_STATE_DIR"
    state_file="${COMPOSE_APPS_STATE_DIR}/${app}.deployed-head"
    state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
    printf '%s\n' "$head" > "$state_tmp"
    chmod 0640 "$state_tmp"
    chown cloud-compose:cloud-compose "$state_tmp" 2>/dev/null || true
    mv -f "$state_tmp" "$state_file"
}

checkout_exact_compose_commit() {
    local app="$1"
    local requested_commit="$2"
    local deployed_head

    retry_until_success git fetch --force --no-tags -- origin "$requested_commit" || return 1
    if ! git cat-file -e "${requested_commit}^{commit}" 2>/dev/null; then
        echo "Configured commit ${requested_commit} is not a commit in ${DOCKER_COMPOSE_REPO}" >&2
        return 1
    fi

    git checkout --detach "$requested_commit" || return 1
    deployed_head="$(git rev-parse --verify HEAD)" || return 1
    if [[ "${deployed_head,,}" != "${requested_commit,,}" ]]; then
        echo "Expected ${app} at ${requested_commit}, but Git checked out ${deployed_head}" >&2
        return 1
    fi

    echo "Checked out ${app} at pinned commit ${deployed_head} (detached HEAD)."
}

verify_compose_origin() {
    local actual_origin

    actual_origin="$(git remote get-url origin 2>/dev/null)" || {
        echo "Compose repository has no origin remote: $DOCKER_COMPOSE_DIR" >&2
        return 1
    }
    if [[ "$actual_origin" != "$DOCKER_COMPOSE_REPO" ]]; then
        echo "Compose origin mismatch for $DOCKER_COMPOSE_DIR: expected $DOCKER_COMPOSE_REPO, found $actual_origin" >&2
        return 1
    fi
}

verify_clean_compose_checkout() {
    local untracked_compose_control

    if ! git diff --quiet --ignore-submodules -- ||
        ! git diff --cached --quiet --ignore-submodules --; then
        echo "Compose checkout contains tracked or staged changes; commit them in the downstream fork before deployment" >&2
        return 1
    fi
    untracked_compose_control="$(git ls-files --others --exclude-standard -- \
        ':(glob)**/compose*.yml' ':(glob)**/compose*.yaml' \
        ':(glob)**/docker-compose*.yml' ':(glob)**/docker-compose*.yaml')" || return 1
    if [[ -n "$untracked_compose_control" ]]; then
        echo "Compose checkout contains an untracked Compose control file: $untracked_compose_control" >&2
        return 1
    fi
}

reject_host_network_compose_services() {
    local config_json

    if [[ "${CLOUD_COMPOSE_PROVIDER:-}" != "gcp" ]]; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker is required to validate Compose network isolation" >&2
        return 1
    fi
    config_json="$(docker compose config --format json)" || {
        echo "Could not render Compose configuration for metadata-isolation validation" >&2
        return 1
    }
    if ! jq -e '.services | type == "object"' <<<"$config_json" >/dev/null; then
        echo "Docker Compose returned an invalid service configuration" >&2
        return 1
    fi
    if jq -e '
        any(.services[];
            (.network_mode // "") == "host" or
            (
                (.build | type) == "object" and
                (
                    (.build.network // "") == "host" or
                    any((.build.entitlements // [])[];
                        . == "network.host" or . == "security.insecure"
                    )
                )
            )
        )
    ' <<<"$config_json" >/dev/null; then
        echo "Host runtime/build networking and insecure BuildKit entitlements are not allowed on GCP because they bypass container metadata isolation" >&2
        return 1
    fi
}

clone_or_update_compose_app() {
    local app="$1"
    local local_head fetched_head recorded_head=""
    local deployed_state_file="${COMPOSE_APPS_STATE_DIR}/${app}.deployed-head"

    source_compose_app_env "$app" || return 1
    validate_compose_git_source || return 1

    if [ ! -d "$DOCKER_COMPOSE_DIR/.git" ]; then
        echo "Directory '$DOCKER_COMPOSE_DIR' not found. Cloning repository for ${app}."
        mkdir -p "$DOCKER_COMPOSE_DIR" || return 1
        pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
        if compose_ref_is_full_commit "$DOCKER_COMPOSE_BRANCH"; then
            git init . || { popd >/dev/null; return 1; }
            git remote add -- origin "$DOCKER_COMPOSE_REPO" || { popd >/dev/null; return 1; }
            checkout_exact_compose_commit "$app" "$DOCKER_COMPOSE_BRANCH" || { popd >/dev/null; return 1; }
        else
            retry_until_success git clone -b "$DOCKER_COMPOSE_BRANCH" -- "$DOCKER_COMPOSE_REPO" . || {
                popd >/dev/null
                return 1
            }
        fi
        verify_clean_compose_checkout || { popd >/dev/null; return 1; }
        if [ "$(id -u)" -eq 0 ]; then
            chown -R cloud-compose:cloud-compose . || { popd >/dev/null; return 1; }
        fi
        popd >/dev/null
    else
        pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
        verify_compose_origin || { popd >/dev/null; return 1; }
        verify_clean_compose_checkout || { popd >/dev/null; return 1; }
        if compose_ref_is_full_commit "$DOCKER_COMPOSE_BRANCH"; then
            checkout_exact_compose_commit "$app" "$DOCKER_COMPOSE_BRANCH" || { popd >/dev/null; return 1; }
        else
            retry_until_success git fetch --prune -- origin "$DOCKER_COMPOSE_BRANCH" || {
                popd >/dev/null
                return 1
            }
            local_head="$(git rev-parse --verify HEAD)" || { popd >/dev/null; return 1; }
            if ! git merge-base --is-ancestor HEAD FETCH_HEAD; then
                if [[ -e "$deployed_state_file" || -L "$deployed_state_file" ]]; then
                    if [[ -L "$deployed_state_file" || ! -f "$deployed_state_file" ]]; then
                        echo "Recorded Compose deployment state is unsafe for ${app}: $deployed_state_file" >&2
                        popd >/dev/null
                        return 1
                    fi
                    recorded_head="$(<"$deployed_state_file")"
                    if [[ ! "$recorded_head" =~ ^[0-9a-f]{40}$ ]]; then
                        echo "Recorded Compose deployment state is invalid for ${app}: $deployed_state_file" >&2
                        popd >/dev/null
                        return 1
                    fi
                fi
                if [[ -n "$recorded_head" && "$local_head" == "$recorded_head" ]]; then
                    # A successful rollout may intentionally leave a detached
                    # feature/PR commit divergent from the baseline. Explicit
                    # source preparation or init may restore that baseline, but
                    # only when HEAD is exactly the commit we previously
                    # recorded after a successful lifecycle.
                    git checkout --detach FETCH_HEAD || { popd >/dev/null; return 1; }
                else
                    echo "Local Compose HEAD is not an ancestor of origin/$DOCKER_COMPOSE_BRANCH and does not match the recorded deployment; refusing a local-ahead or divergent deployment" >&2
                    popd >/dev/null
                    return 1
                fi
            else
                git merge --ff-only FETCH_HEAD || { popd >/dev/null; return 1; }
            fi
            local_head="$(git rev-parse --verify HEAD)" || { popd >/dev/null; return 1; }
            fetched_head="$(git rev-parse --verify 'FETCH_HEAD^{commit}')" || { popd >/dev/null; return 1; }
            if [[ "$local_head" != "$fetched_head" ]]; then
                echo "Compose checkout did not converge exactly to fetched origin/$DOCKER_COMPOSE_BRANCH" >&2
                popd >/dev/null
                return 1
            fi
        fi
        verify_clean_compose_checkout || { popd >/dev/null; return 1; }
        popd >/dev/null
    fi
}

verify_existing_compose_app_checkout() {
    local app="$1"
    local current_head

    source_compose_app_env "$app" || return 1
    validate_compose_git_source || return 1
    if [[ ! -d "$DOCKER_COMPOSE_DIR/.git" ]]; then
        echo "Compose checkout is missing for ${app}: $DOCKER_COMPOSE_DIR" >&2
        return 1
    fi

    pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
    verify_compose_origin || { popd >/dev/null; return 1; }
    verify_clean_compose_checkout || { popd >/dev/null; return 1; }
    current_head="$(git rev-parse --verify 'HEAD^{commit}')" || {
        echo "Compose checkout has no deployed commit for ${app}: $DOCKER_COMPOSE_DIR" >&2
        popd >/dev/null
        return 1
    }
    if [[ ! "$current_head" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Compose checkout resolved an invalid commit for ${app}: $current_head" >&2
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

configure_sitectl_app_features() {
    local app="$1"
    local letsencrypt bot_mitigation mode domain acme_email max_upload_size upload_timeout
    local configure_ingress=false
    local changed=false
    local trusted_ip
    local -a trusted_ips=()

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
    compose_app_ingress_array_values "$app" trusted_ips trusted_ips || return 1
    for trusted_ip in "${trusted_ips[@]}"; do
        if [ -n "$trusted_ip" ]; then
            ingress_args+=(--trusted-ip "$trusted_ip")
            configure_ingress=true
        fi
    done
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
    local command command_status
    local -a commands=()

    case "$lifecycle" in
        init)
            # Initialization is the explicit baseline-source convergence phase.
            # It follows a configured moving ref or restores a configured pin.
            clone_or_update_compose_app "$app" || return 1
            ;;
        up | rollout)
            source_compose_app_env "$app" || return 1
            validate_compose_git_source || return 1
            if [[ -d "$DOCKER_COMPOSE_DIR/.git" ]]; then
                # Preserve the revision selected by the last successful
                # rollout. In particular, do not force a detached PR/feature
                # commit back through the configured baseline branch before a
                # service restart or the next rollout can operate on it.
                verify_existing_compose_app_checkout "$app" || return 1
            else
                clone_or_update_compose_app "$app" || return 1
            fi
            ;;
        down)
            source_compose_app_env "$app" || return 1
            validate_compose_git_source || return 1
            ;;
        *)
            echo "Unsupported cloud-compose lifecycle: $lifecycle" >&2
            return 2
            ;;
    esac

    echo "Running cloud-compose ${lifecycle} for ${app}"
    compose_app_array_values "$app" "$field" commands || return 1
    configure_sitectl_verify_argv || return 1
    pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
    if [[ "$lifecycle" != "down" ]]; then
        reject_host_network_compose_services || { popd >/dev/null; return 1; }
    fi
    for command in "${commands[@]}"; do
        if [ -z "$command" ]; then
            continue
        fi
        bash -c "$command" || {
            command_status=$?
            popd >/dev/null
            return "$command_status"
        }
    done
    if [[ "$lifecycle" != "down" ]]; then
        record_compose_app_head "$app" || { popd >/dev/null; return 1; }
    fi
    popd >/dev/null
}
