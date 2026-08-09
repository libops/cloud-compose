#!/usr/bin/env bash

set -euo pipefail

COMPOSE_PROJECTS_FILE="${COMPOSE_PROJECTS_FILE:-/home/cloud-compose/compose-projects.json}"
COMPOSE_APPS_ENV_DIR="${COMPOSE_APPS_ENV_DIR:-/home/cloud-compose/apps}"
COMPOSE_APPS_STATE_DIR="${COMPOSE_APPS_STATE_DIR:-/home/cloud-compose/state}"
CLOUD_COMPOSE_DATA_ROOT="${CLOUD_COMPOSE_DATA_ROOT:-/mnt/disks/data}"
_cc_compose_apps_source="$(readlink -f -- "${BASH_SOURCE[0]}")"
_cc_compose_apps_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_cc_compose_apps_installed_home="$(readlink -f -- /home/cloud-compose 2>/dev/null || true)"
readonly _cc_compose_apps_source _cc_compose_apps_dir _cc_compose_apps_installed_home
if [[ -n "$_cc_compose_apps_installed_home" &&
    ( "$_cc_compose_apps_installed_home" == "/" ||
        "$_cc_compose_apps_source" == "${_cc_compose_apps_installed_home%/}/"* ) ]]; then
    _cc_compose_apps_checked_programs=/etc/cloud-compose/libexec/checked-programs.bash
else
    _cc_compose_apps_checked_programs="$_cc_compose_apps_dir/../../etc/cloud-compose/libexec/checked-programs.bash"
fi
readonly _cc_compose_apps_checked_programs
# shellcheck disable=SC1090
source "$_cc_compose_apps_checked_programs"
cloud_compose_bind_program_dir \
    "$_cc_compose_apps_source" \
    CLOUD_COMPOSE_JQ_PROGRAM_DIR \
    /etc/cloud-compose/jq \
    "$_cc_compose_apps_dir/../../etc/cloud-compose/jq" \
    compose-validate-projects.jq \
    compose-app-field.jq \
    compose-app-array.jq \
    compose-app-verify-args.jq \
    compose-app-verify-args-json.jq \
    compose-app-ingress-field.jq \
    compose-app-ingress-array.jq \
    compose-reject-host-network.jq \
    compose-project-dirs-base64.jq \
    compose-services-object-validate.jq \
    array-values-base64.jq \
    object-has-key.jq \
    object-keys-base64.jq \
    object-keys.jq \
    string-array-validate.jq
cloud_compose_bind_program \
    "$_cc_compose_apps_source" \
    CLOUD_COMPOSE_COMPOSE_SECRET_FILES_PROGRAM \
    /etc/cloud-compose/awk/compose-secret-files.awk \
    "$_cc_compose_apps_dir/../../etc/cloud-compose/awk/compose-secret-files.awk"
COMPOSE_SECRET_FILES_PROGRAM="$CLOUD_COMPOSE_COMPOSE_SECRET_FILES_PROGRAM"
readonly COMPOSE_SECRET_FILES_PROGRAM
readonly COMPOSE_LIFECYCLE_EXECUTOR="/etc/cloud-compose/libexec/run-lifecycle-program.sh"

run_compose_lifecycle_executor() {
    "$COMPOSE_LIFECYCLE_EXECUTOR" "$@"
}

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

    if ! jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-validate-projects.jq" \
        "$COMPOSE_PROJECTS_FILE" >/dev/null; then
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
    done < <(jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-keys-base64.jq" \
        "$COMPOSE_PROJECTS_FILE")

    while IFS= read -r encoded_project_dir; do
        project_dir="$(
            if ! printf '%s' "$encoded_project_dir" | base64 --decode; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        project_dir="${project_dir%$'\x1f'}"
        validate_compose_project_dir "$project_dir" || return 1
    done < <(jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-project-dirs-base64.jq" \
        "$COMPOSE_PROJECTS_FILE")
}

# Converge one already-existing manifest project without traversing or changing
# ownership below it. The low-level helper accepts numeric IDs so its filesystem
# behavior can be tested without requiring the production account locally; the
# public wrapper always selects the fixed cloud-compose identity.
_converge_compose_app_filesystem_for_ids() (
    local app="$1"
    local runtime_uid="$2"
    local runtime_gid="$3"
    local project_dir resolved_project_dir env_file env_path
    local project_fd project_fd_path project_identity
    local env_fd env_fd_path env_identity env_metadata
    local guard_uid="$EUID"
    local guard_gid

    if [[ ! "$runtime_uid" =~ ^[0-9]+$ || ! "$runtime_gid" =~ ^[0-9]+$ ]]; then
        echo "Invalid cloud-compose runtime account IDs" >&2
        return 2
    fi
    guard_gid="$(id -g)" || return 1

    compose_app_exists "$app" || return 1
    project_dir="$(compose_app_field "$app" project_dir)" || return 1
    validate_compose_project_dir "$project_dir" || return 1

    # A missing project is created later by the unprivileged source-preparation
    # phase. Existing persistent checkouts must be real directories at the
    # exact manifest path; do not follow even an in-boundary symlink as root.
    if [[ ! -e "$project_dir" && ! -L "$project_dir" ]]; then
        return 0
    fi
    if [[ -L "$project_dir" || ! -d "$project_dir" ]]; then
        echo "Compose project path is not a real directory: $project_dir" >&2
        return 1
    fi
    resolved_project_dir="$(realpath -e -- "$project_dir")" || return 1
    if [[ "$resolved_project_dir" != "$project_dir" ]]; then
        echo "Compose project path contains a symbolic-link component: $project_dir" >&2
        return 1
    fi

    # Operate through a verified descriptor. If an application account races a
    # path replacement, the descriptor cannot be redirected to another inode
    # and the final identity check fails closed.
    project_identity="$(stat -c '%d:%i' -- "$project_dir")" || return 1
    exec {project_fd}<"$project_dir" || return 1
    project_fd_path="/proc/${BASHPID}/fd/${project_fd}"
    if [[ "$(stat -Lc '%F:%d:%i' -- "$project_fd_path")" != "directory:${project_identity}" ||
        "$(stat -c '%d:%i' -- "$project_dir")" != "$project_identity" ]]; then
        echo "Compose project path changed while opening: $project_dir" >&2
        return 1
    fi

    # Freeze the opened directory before inspecting its child. The first chmod
    # removes ordinary write access; changing owner and repeating the chmod
    # closes a race with the former owner changing its mode concurrently. Only
    # state observed after the final root-owned/read-only transition is trusted.
    chmod 0555 "$project_fd_path" || return 1
    chown --dereference "${guard_uid}:${guard_gid}" "$project_fd_path" || return 1
    chmod 0555 "$project_fd_path" || return 1
    if [[ "$(stat -c '%d:%i' -- "$project_dir")" != "$project_identity" ||
        "$(stat -Lc '%u:%g:%a' -- "$project_fd_path")" != "${guard_uid}:${guard_gid}:555" ]]; then
        echo "Compose project path did not freeze safely: $project_dir" >&2
        return 1
    fi

    # Resolve .env through the verified directory descriptor. The directory is
    # no longer writable by the application identity, so this lstat-style
    # symlink rejection cannot race the subsequent open.
    env_path="${project_dir}/.env"
    env_file="${project_fd_path}/.env"
    if [[ ! -e "$env_file" && ! -L "$env_file" ]]; then
        chown --dereference "${runtime_uid}:${runtime_gid}" "$project_fd_path" || return 1
        chmod 0775 "$project_fd_path" || return 1
        return 0
    fi
    if [[ -L "$env_file" || ! -f "$env_file" ]]; then
        echo "Compose environment path is not a regular file: $env_path" >&2
        return 1
    fi
    env_metadata="$(stat -c '%F:%h' -- "$env_file")" || return 1
    if [[ "$env_metadata" != "regular file:1" ]]; then
        echo "Compose environment file must have exactly one link: $env_path" >&2
        return 1
    fi

    env_identity="$(stat -c '%d:%i' -- "$env_file")" || return 1
    exec {env_fd}<"$env_file" || return 1
    env_fd_path="/proc/${BASHPID}/fd/${env_fd}"
    if [[ "$(stat -Lc '%F:%h:%d:%i' -- "$env_fd_path")" != "regular file:1:${env_identity}" ||
        "$(stat -c '%d:%i' -- "$env_file")" != "$env_identity" ]]; then
        echo "Compose environment path changed while opening: $env_path" >&2
        return 1
    fi
    chown --dereference "${runtime_uid}:${runtime_gid}" "$env_fd_path" || return 1
    chmod 0640 "$env_fd_path" || return 1
    if [[ "$(stat -c '%d:%i' -- "$env_file")" != "$env_identity" ||
        "$(stat -Lc '%u:%g:%a:%h' -- "$env_fd_path")" != "${runtime_uid}:${runtime_gid}:640:1" ]]; then
        echo "Compose environment ownership did not converge safely: $env_path" >&2
        return 1
    fi

    chown --dereference "${runtime_uid}:${runtime_gid}" "$project_fd_path" || return 1
    chmod 0775 "$project_fd_path" || return 1
    if [[ "$(stat -c '%d:%i' -- "$project_dir")" != "$project_identity" ||
        "$(stat -Lc '%u:%g:%a' -- "$project_fd_path")" != "${runtime_uid}:${runtime_gid}:775" ]]; then
        echo "Compose project ownership did not converge safely: $project_dir" >&2
        return 1
    fi
)

converge_compose_app_filesystem() {
    local app="$1"
    local runtime_uid runtime_gid

    if ((EUID != 0)); then
        echo "Compose application filesystem convergence must run as root" >&2
        return 1
    fi
    runtime_uid="$(id -u cloud-compose)" || return 1
    runtime_gid="$(id -g cloud-compose)" || return 1
    _converge_compose_app_filesystem_for_ids "$app" "$runtime_uid" "$runtime_gid"
}

compose_app_exists() {
    local app="$1"

    validate_compose_app_name "$app" || return 1
    validate_compose_projects_manifest || return 1
    jq -e --arg key "$app" -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-has-key.jq" \
        "$COMPOSE_PROJECTS_FILE" >/dev/null || {
        echo "Cloud-compose app is not present in the manifest: $app" >&2
        return 1
    }
}

compose_app_names_array() {
    local result_name="$1"
    local names app
    local -n "result=$result_name"

    validate_compose_projects_manifest || return 1
    names="$(jq -er -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/object-keys.jq" \
        "$COMPOSE_PROJECTS_FILE")" || return 1
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
    jq -er --arg app "$app" --arg field "$field" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-field.jq" \
        "$COMPOSE_PROJECTS_FILE"
}

compose_app_array_values() {
    local app="$1"
    local field="$2"
    local result_name="$3"
    local payload encoded_lines encoded value
    local -n "result=$result_name"

    compose_app_exists "$app" || return 1
    payload="$(jq -ce --arg app "$app" --arg field "$field" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-array.jq" \
        "$COMPOSE_PROJECTS_FILE")" || {
        echo "Invalid $field array for cloud-compose app $app" >&2
        return 1
    }

    result=()
    encoded_lines="$(jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/array-values-base64.jq" \
        <<<"$payload")" || return 1
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
    jq -er --arg app "$app" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-verify-args.jq" \
        "$COMPOSE_PROJECTS_FILE"
}

compose_app_verify_args_json() {
    local app="$1"

    compose_app_exists "$app" || return 1
    jq -cer --arg app "$app" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-verify-args-json.jq" \
        "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_field() {
    local app="$1"
    local field="$2"

    compose_app_exists "$app" || return 1
    jq -er --arg app "$app" --arg field "$field" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-ingress-field.jq" \
        "$COMPOSE_PROJECTS_FILE"
}

compose_app_ingress_array_values() {
    local app="$1"
    local field="$2"
    local result_name="$3"
    local payload encoded_lines encoded value
    local -n "result=$result_name"

    compose_app_exists "$app" || return 1
    payload="$(jq -ce --arg app "$app" --arg field "$field" \
        -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-app-ingress-array.jq" \
        "$COMPOSE_PROJECTS_FILE")" || {
        echo "Invalid ingress $field array for cloud-compose app $app" >&2
        return 1
    }

    result=()
    encoded_lines="$(jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/array-values-base64.jq" \
        <<<"$payload")" || return 1
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

    for compose_file in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [ ! -f "$compose_file" ]; then
            continue
        fi

        awk -f "$COMPOSE_SECRET_FILES_PROGRAM" "$compose_file"
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
    if ! jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/string-array-validate.jq" \
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
            done < <(jq -r -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/array-values-base64.jq" \
                <<<"${SITECTL_VERIFY_ARGS_JSON:-[]}")
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

compose_checkout_diff_digest() {
    local digest digest_output diff_file

    diff_file="$(mktemp)" || return 1
    if ! git diff --binary --full-index --no-color --no-ext-diff --no-textconv HEAD -- >"$diff_file"; then
        rm -f -- "$diff_file"
        echo "Could not fingerprint managed Compose changes" >&2
        return 1
    fi
    if ! digest_output="$(sha256sum "$diff_file")"; then
        rm -f -- "$diff_file"
        echo "Could not hash managed Compose changes" >&2
        return 1
    fi
    rm -f -- "$diff_file"
    digest="${digest_output%% *}"
    if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Managed Compose change fingerprint is invalid" >&2
        return 1
    fi
    printf '%s\n' "$digest"
}

record_compose_managed_diff() {
    local app="$1"
    local digest state_file state_tmp

    validate_compose_app_name "$app" || return 1
    digest="$(compose_checkout_diff_digest)" || return 1
    install -d -m 0750 "$COMPOSE_APPS_STATE_DIR"
    state_file="${COMPOSE_APPS_STATE_DIR}/${app}.managed-diff"
    state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
    printf '%s\n' "$digest" >"$state_tmp"
    chmod 0640 "$state_tmp"
    chown cloud-compose:cloud-compose "$state_tmp" 2>/dev/null || true
    mv -f "$state_tmp" "$state_file"
}

verify_recorded_compose_managed_diff() {
    local app="$1"
    local current_digest recorded_digest state_file

    validate_compose_app_name "$app" || return 1
    state_file="${COMPOSE_APPS_STATE_DIR}/${app}.managed-diff"
    if [[ -L "$state_file" || ! -f "$state_file" ]]; then
        echo "Compose checkout contains tracked changes without recorded managed state: $state_file" >&2
        return 1
    fi
    recorded_digest="$(<"$state_file")"
    if [[ ! "$recorded_digest" =~ ^[0-9a-f]{64}$ ]]; then
        echo "Recorded managed Compose state is invalid for ${app}: $state_file" >&2
        return 1
    fi
    current_digest="$(compose_checkout_diff_digest)" || return 1
    if [[ "$current_digest" != "$recorded_digest" ]]; then
        echo "Compose checkout differs from its recorded sitectl-managed state; commit operator changes in the downstream fork before deployment" >&2
        return 1
    fi
}

restore_recorded_compose_managed_diff() {
    local app="$1"

    if git diff --quiet --ignore-submodules -- &&
        git diff --cached --quiet --ignore-submodules --; then
        return 0
    fi
    verify_recorded_compose_managed_diff "$app" || return 1
    git restore --source=HEAD --staged --worktree -- . || return 1
    if ! git diff --quiet --ignore-submodules -- ||
        ! git diff --cached --quiet --ignore-submodules --; then
        echo "Could not restore the committed Compose source before deployment" >&2
        return 1
    fi
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
    local app="${1:-}"
    local untracked_compose_control

    if ! git diff --quiet --ignore-submodules -- ||
        ! git diff --cached --quiet --ignore-submodules --; then
        if [[ -z "$app" ]]; then
            echo "Compose checkout contains tracked or staged changes; commit them in the downstream fork before deployment" >&2
            return 1
        fi
        verify_recorded_compose_managed_diff "$app" || return 1
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
    local config_json filter_status

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
    if ! jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-services-object-validate.jq" \
        <<<"$config_json" >/dev/null; then
        echo "Docker Compose returned an invalid service configuration" >&2
        return 1
    fi
    if jq -e -f "$CLOUD_COMPOSE_JQ_PROGRAM_DIR/compose-reject-host-network.jq" \
        <<<"$config_json" >/dev/null; then
        echo "Host runtime/build networking and insecure BuildKit entitlements are not allowed on GCP because they bypass container metadata isolation" >&2
        return 1
    else
        filter_status=$?
    fi
    if [[ "$filter_status" -ne 1 ]]; then
        echo "Could not evaluate Compose network isolation with the checked jq program" >&2
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
        verify_clean_compose_checkout "$app" || { popd >/dev/null; return 1; }
        if [ "$(id -u)" -eq 0 ]; then
            chown -R cloud-compose:cloud-compose . || { popd >/dev/null; return 1; }
        fi
        popd >/dev/null
    else
        pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
        verify_compose_origin || { popd >/dev/null; return 1; }
        verify_clean_compose_checkout "$app" || { popd >/dev/null; return 1; }
        restore_recorded_compose_managed_diff "$app" || { popd >/dev/null; return 1; }
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
        verify_clean_compose_checkout "$app" || { popd >/dev/null; return 1; }
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
    verify_clean_compose_checkout "$app" || { popd >/dev/null; return 1; }
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
    fi
    if [ -n "$domain" ]; then
        ingress_args+=(--domain "$domain")
    fi
    if [ -n "$acme_email" ]; then
        ingress_args+=(--acme-email "$acme_email")
    fi
    compose_app_ingress_array_values "$app" trusted_ips trusted_ips || return 1
    for trusted_ip in "${trusted_ips[@]}"; do
        if [ -n "$trusted_ip" ]; then
            ingress_args+=(--trusted-ip "$trusted_ip")
        fi
    done
    if [ -n "$max_upload_size" ]; then
        ingress_args+=(--max-upload-size "$max_upload_size")
    fi
    if [ -n "$upload_timeout" ]; then
        ingress_args+=(--upload-timeout "$upload_timeout")
    fi

    # Always initialize component desired state, including when every ingress
    # option uses its default. Verification deliberately fails when
    # .libops/site.yaml is absent, and component set initializes every
    # registered component from its declared default before applying ingress.
    sitectl "${ingress_args[@]}"
    if sitectl_truthy "$bot_mitigation"; then
        sitectl set bot-mitigation on --context "$SITECTL_CONTEXT_NAME" --yolo
    fi
    sitectl converge --context "$SITECTL_CONTEXT_NAME" --yolo
}

run_compose_app_lifecycle() {
    local app="$1"
    local lifecycle="$2"
    local field="${lifecycle}_commands"
    local command command_status
    local -a commands=()

    case "$lifecycle" in
        init | up | down | rollout) ;;
        *)
            echo "Unsupported cloud-compose lifecycle: $lifecycle" >&2
            return 2
            ;;
    esac

    # Reject the entire program set before cloning, updating, or running
    # anything so a bad later selector cannot leave partial lifecycle state.
    compose_app_array_values "$app" "$field" commands || return 1
    for command in "${commands[@]}"; do
        [[ -n "$command" ]] || continue
        run_compose_lifecycle_executor --validate "$lifecycle" "$command" || return 1
    done

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
            if [[ "$lifecycle" == "rollout" ]]; then
                pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
                restore_recorded_compose_managed_diff "$app" || { popd >/dev/null; return 1; }
                popd >/dev/null
            fi
            ;;
        down)
            source_compose_app_env "$app" || return 1
            validate_compose_git_source || return 1
            ;;
    esac

    echo "Running cloud-compose ${lifecycle} for ${app}"
    configure_sitectl_verify_argv || return 1
    pushd "$DOCKER_COMPOSE_DIR" >/dev/null || return 1
    if [[ "$lifecycle" != "down" ]]; then
        reject_host_network_compose_services || { popd >/dev/null; return 1; }
    fi
    for command in "${commands[@]}"; do
        if [ -z "$command" ]; then
            continue
        fi
        run_compose_lifecycle_executor "$lifecycle" "$command" || {
            command_status=$?
            popd >/dev/null
            return "$command_status"
        }
    done
    if [[ "$lifecycle" != "down" ]]; then
        record_compose_app_head "$app" || { popd >/dev/null; return 1; }
    fi
    if [[ "$lifecycle" == "rollout" ]]; then
        record_compose_managed_diff "$app" || { popd >/dev/null; return 1; }
    fi
    popd >/dev/null
}
