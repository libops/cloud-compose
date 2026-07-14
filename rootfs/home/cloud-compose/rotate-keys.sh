#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"

# shellcheck disable=SC1090
source "$profile_path"

log_info() {
    printf '[key-rotation] %s\n' "$1" >&2
}

log_error() {
    printf '[key-rotation] ERROR: %s\n' "$1" >&2
}

usage() {
    cat >&2 <<EOF
Usage: $0 prepare|status|audit|recover|authenticate|ready|commit|rollback|rollback-ready|retire SERVICE_ACCOUNT PROJECT_ID CREDENTIALS_FILE [RECOVERY_KEY_ID]
EOF
}

case "${CLOUD_COMPOSE_PROVIDER:-}" in
    gcp) ;;
    "")
        log_error "CLOUD_COMPOSE_PROVIDER is required for service-account key rotation"
        exit 1
        ;;
    *)
        log_info "Service-account key rotation is disabled for provider $CLOUD_COMPOSE_PROVIDER"
        exit 0
        ;;
esac

if [[ $# -lt 4 || $# -gt 5 ]]; then
    usage
    exit 2
fi

ACTION="$1"
SERVICE_ACCOUNT="$2"
PROJECT_ID="$3"
CREDENTIALS_FILE="$4"
RECOVERY_KEY_ID="${5:-}"

case "$ACTION" in
    prepare | status | audit | recover | authenticate | ready | commit | rollback | rollback-ready | retire) ;;
    *)
        usage
        exit 2
        ;;
esac
if [[ "$ACTION" != "recover" && -n "$RECOVERY_KEY_ID" ]]; then
    usage
    exit 2
fi

if [[ -z "$SERVICE_ACCOUNT" || -z "$PROJECT_ID" || -z "$CREDENTIALS_FILE" ]]; then
    log_error "Service account, project ID, and credentials path are required"
    exit 2
fi
if [[ ! "$SERVICE_ACCOUNT" =~ ^[A-Za-z0-9._@+-]+$ ]]; then
    log_error "Service account contains unsafe characters"
    exit 2
fi
if [[ ! "$PROJECT_ID" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    log_error "Project ID contains unsafe characters"
    exit 2
fi
if [[ "$CREDENTIALS_FILE" != /* || "$CREDENTIALS_FILE" == "/" ||
    "$CREDENTIALS_FILE" == *$'\n'* || "$CREDENTIALS_FILE" == *$'\r'* ||
    "$CREDENTIALS_FILE" =~ (^|/)\.\.?(/|$) ]]; then
    log_error "Credentials path is unsafe: $CREDENTIALS_FILE"
    exit 2
fi
if [[ -n "$RECOVERY_KEY_ID" && ! "$RECOVERY_KEY_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Recovery key ID contains unsafe characters"
    exit 2
fi

credentials_dir="$(dirname -- "$CREDENTIALS_FILE")"
PENDING_STATE="${CREDENTIALS_FILE}.rotation-pending.json"
STAGED_CREDENTIALS="${CREDENTIALS_FILE}.rotation-staged.json"
PREVIOUS_CREDENTIALS="${CREDENTIALS_FILE}.rotation-previous.json"
REPLACEMENT_CREDENTIALS="${CREDENTIALS_FILE}.rotation-replacement.json"
ROTATION_LOCK="${CREDENTIALS_FILE}.rotation.lock"
SA_RESOURCE="projects/$PROJECT_ID/serviceAccounts/$SERVICE_ACCOUNT"
ROTATION_MIN_AGE_SECONDS="${ROTATION_MIN_AGE_SECONDS:-86400}"
ROTATION_DISABLE_GRACE_SECONDS="${ROTATION_DISABLE_GRACE_SECONDS:-86400}"
ROTATION_AUTH_MAX_RETRIES="${ROTATION_AUTH_MAX_RETRIES:-6}"
ROTATION_AUTH_SLEEP_SECONDS="${ROTATION_AUTH_SLEEP_SECONDS:-5}"
ROTATION_RECOVERY_SETTLE_SECONDS="${ROTATION_RECOVERY_SETTLE_SECONDS:-60}"
ROTATION_CREDENTIAL_OWNER="${ROTATION_CREDENTIAL_OWNER-100}"

validate_integer_setting() {
    local name="$1" value="$2" minimum="$3" maximum="$4"

    if [[ ! "$value" =~ ^[0-9]{1,10}$ ]] ||
        ((10#$value < minimum || 10#$value > maximum)); then
        log_error "$name must be an integer from $minimum through $maximum"
        return 1
    fi
}

validate_integer_setting ROTATION_MIN_AGE_SECONDS "$ROTATION_MIN_AGE_SECONDS" 0 315360000 || exit 2
validate_integer_setting ROTATION_DISABLE_GRACE_SECONDS "$ROTATION_DISABLE_GRACE_SECONDS" 0 31536000 || exit 2
validate_integer_setting ROTATION_AUTH_MAX_RETRIES "$ROTATION_AUTH_MAX_RETRIES" 1 20 || exit 2
validate_integer_setting ROTATION_AUTH_SLEEP_SECONDS "$ROTATION_AUTH_SLEEP_SECONDS" 0 300 || exit 2
validate_integer_setting ROTATION_RECOVERY_SETTLE_SECONDS "$ROTATION_RECOVERY_SETTLE_SECONDS" 0 3600 || exit 2
if [[ -n "$ROTATION_CREDENTIAL_OWNER" &&
    ! "$ROTATION_CREDENTIAL_OWNER" =~ ^([0-9]+|[a-z_][a-z0-9_-]{0,31}\$?)$ ]]; then
    log_error "ROTATION_CREDENTIAL_OWNER must be empty, a numeric UID, or a safe local account name"
    exit 2
fi

if [[ -L "$credentials_dir" || ( -e "$credentials_dir" && ! -d "$credentials_dir" ) ]]; then
    log_error "Credentials directory is unsafe: $credentials_dir"
    exit 1
fi
install -d -m 0750 -- "$credentials_dir"
if [[ -L "$credentials_dir" || ! -d "$credentials_dir" ]]; then
    log_error "Credentials directory did not resolve to a regular directory: $credentials_dir"
    exit 1
fi

exec 9>"$ROTATION_LOCK"
if command -v flock >/dev/null 2>&1 && ! flock -w 30 9; then
    log_error "Timed out waiting for rotation lock: $ROTATION_LOCK"
    exit 1
fi

STATE_PHASE=""
STATE_CURRENT_KEY_ID=""
STATE_NEW_KEY_ID=""
STATE_NEW_KEY_NAME=""
STATE_BASELINE_KEY_NAMES='[]'
STATE_CREATED_AT=0
STATE_READY_AT=0
STATE_DISABLED_AT=0
ACCESS_TOKEN=""
KEY_OPERATION_RESULT=""

now_epoch() {
    date +%s
}

valid_iam_key_id() {
    local key_id="$1"

    [[ "$key_id" =~ ^[A-Za-z0-9_-]+$ ]]
}

credential_key_id() {
    local file="$1" key_id

    key_id="$(jq -jr '
        (.private_key_id |
            select(type == "string" and length > 0 and (explode | index(0) == null))),
        "\u001f"
    ' "$file")" || return 1
    key_id="${key_id%$'\x1f'}"
    valid_iam_key_id "$key_id" || return 1
    printf '%s\n' "$key_id"
}

valid_iam_key_name() {
    local key_name="$1"
    local prefix="$SA_RESOURCE/keys/"
    local key_id

    [[ "$key_name" == "$prefix"* ]] || return 1
    key_id="${key_name#"$prefix"}"
    valid_iam_key_id "$key_id" && [[ "$key_name" == "$prefix$key_id" ]]
}

write_state() {
    local state_tmp

    state_tmp="$(mktemp "${PENDING_STATE}.tmp.XXXXXX")" || return 1
    if ! jq -n \
        --arg phase "$STATE_PHASE" \
        --arg service_account "$SERVICE_ACCOUNT" \
        --arg project_id "$PROJECT_ID" \
        --arg credentials_file "$CREDENTIALS_FILE" \
        --arg current_key_id "$STATE_CURRENT_KEY_ID" \
        --arg new_key_id "$STATE_NEW_KEY_ID" \
        --arg new_key_name "$STATE_NEW_KEY_NAME" \
        --argjson baseline_key_names "$STATE_BASELINE_KEY_NAMES" \
        --argjson created_at "$STATE_CREATED_AT" \
        --argjson ready_at "$STATE_READY_AT" \
        --argjson disabled_at "$STATE_DISABLED_AT" \
        '{
            version: 2,
            phase: $phase,
            service_account: $service_account,
            project_id: $project_id,
            credentials_file: $credentials_file,
            current_key_id: $current_key_id,
            new_key_id: $new_key_id,
            new_key_name: $new_key_name,
            baseline_key_names: $baseline_key_names,
            created_at: $created_at,
            ready_at: $ready_at,
            disabled_at: $disabled_at
        }' >"$state_tmp"; then
        rm -f -- "$state_tmp"
        return 1
    fi
    chmod 0600 "$state_tmp"
    mv -f -- "$state_tmp" "$PENDING_STATE"
}

load_state() {
    local payload encoded_baseline_name baseline_name

    if [[ -L "$PENDING_STATE" || ! -f "$PENDING_STATE" ]]; then
        log_error "Pending rotation state is missing or unsafe: $PENDING_STATE"
        return 1
    fi
    payload="$(jq -ce \
        --arg service_account "$SERVICE_ACCOUNT" \
        --arg project_id "$PROJECT_ID" \
        --arg credentials_file "$CREDENTIALS_FILE" '
        select(
            .version == 2 and
            (.phase == "creating" or .phase == "staged" or .phase == "authenticated" or
             .phase == "ready" or .phase == "grace" or .phase == "rolling-back" or
             .phase == "rollback" or .phase == "revoke-new") and
            .service_account == $service_account and
            .project_id == $project_id and
            .credentials_file == $credentials_file and
            (.current_key_id | type == "string" and (explode | index(0) == null)) and
            (.new_key_id | type == "string" and (explode | index(0) == null)) and
            (.new_key_name | type == "string" and (explode | index(0) == null)) and
            (.baseline_key_names | type == "array") and
            all(.baseline_key_names[];
                type == "string" and (explode | index(0) == null)) and
            (.created_at | type == "number" and . >= 0 and floor == .) and
            (.ready_at | type == "number" and . >= 0 and floor == .) and
            (.disabled_at | type == "number" and . >= 0 and floor == .)
        )
    ' "$PENDING_STATE")" || {
        log_error "Pending rotation state is invalid or belongs to another target: $PENDING_STATE"
        return 1
    }

    STATE_PHASE="$(jq -r '.phase' <<<"$payload")"
    STATE_CURRENT_KEY_ID="$(jq -jr '(.current_key_id), "\u001f"' <<<"$payload")"
    STATE_CURRENT_KEY_ID="${STATE_CURRENT_KEY_ID%$'\x1f'}"
    STATE_NEW_KEY_ID="$(jq -jr '(.new_key_id), "\u001f"' <<<"$payload")"
    STATE_NEW_KEY_ID="${STATE_NEW_KEY_ID%$'\x1f'}"
    STATE_NEW_KEY_NAME="$(jq -jr '(.new_key_name), "\u001f"' <<<"$payload")"
    STATE_NEW_KEY_NAME="${STATE_NEW_KEY_NAME%$'\x1f'}"
    STATE_BASELINE_KEY_NAMES="$(jq -c '.baseline_key_names' <<<"$payload")"
    STATE_CREATED_AT="$(jq -r '.created_at' <<<"$payload")"
    STATE_READY_AT="$(jq -r '.ready_at' <<<"$payload")"
    STATE_DISABLED_AT="$(jq -r '.disabled_at' <<<"$payload")"

    if [[ -n "$STATE_CURRENT_KEY_ID" && ! "$STATE_CURRENT_KEY_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log_error "Pending rotation state contains an invalid previous key ID"
        return 1
    fi
    while IFS= read -r encoded_baseline_name; do
        baseline_name="$(
            if ! printf '%s' "$encoded_baseline_name" | base64 --decode; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        baseline_name="${baseline_name%$'\x1f'}"
        if ! valid_iam_key_name "$baseline_name"; then
            log_error "Pending rotation state contains an invalid baseline key name"
            return 1
        fi
    done < <(jq -r '.[] | @base64' <<<"$STATE_BASELINE_KEY_NAMES")

    case "$STATE_PHASE" in
        staged | authenticated | ready | grace | rolling-back | rollback | revoke-new)
            if [[ ! "$STATE_NEW_KEY_ID" =~ ^[A-Za-z0-9_-]+$ ]] ||
                [[ "$STATE_NEW_KEY_NAME" != "$SA_RESOURCE/keys/$STATE_NEW_KEY_ID" ]]; then
                log_error "Pending rotation state contains an invalid replacement key"
                return 1
            fi
            ;;
    esac
}

cleanup_state() {
    rm -f -- "$STAGED_CREDENTIALS" "$PREVIOUS_CREDENTIALS" \
        "$REPLACEMENT_CREDENTIALS" "$PENDING_STATE"
}

fetch_access_token() {
    local token_response

    token_response="$(curl -fsS --connect-timeout 2 --max-time 10 \
        -H "Metadata-Flavor: Google" \
        "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token")" || {
        log_error "Failed to get access token from metadata server"
        return 1
    }
    ACCESS_TOKEN="$(jq -er '.access_token | select(type == "string" and length > 0)' <<<"$token_response")" || {
        log_error "Metadata server returned an invalid access-token response"
        return 1
    }
}

write_access_header_file() {
    local header_tmp

    header_tmp="$(mktemp "${credentials_dir}/.iam-header.XXXXXX")" || return 1
    chmod 0600 "$header_tmp"
    printf 'Authorization: Bearer %s\n' "$ACCESS_TOKEN" >"$header_tmp"
    ACCESS_HEADER_FILE="$header_tmp"
}

list_user_keys() {
    local keys_response curl_status=0

    write_access_header_file || return 1
    keys_response="$(curl -fsS --retry 5 --retry-all-errors --retry-delay 2 --retry-max-time 120 \
        --connect-timeout 5 --max-time 30 \
        -H "@$ACCESS_HEADER_FILE" \
        "https://iam.googleapis.com/v1/$SA_RESOURCE/keys")" || curl_status=$?
    rm -f -- "$ACCESS_HEADER_FILE"
    if ((curl_status != 0)); then
        log_error "Failed to list service-account keys"
        return 1
    fi
    jq -cer --arg prefix "$SA_RESOURCE/keys/" '
        (.keys // []) as $keys |
        if ($keys | type) != "array" then error("invalid key list") else
            [$keys[] |
                select(.keyType == "USER_MANAGED") |
                select((.name | type) == "string" and (.name | startswith($prefix))) |
                {name: .name, disabled: (.disabled // false)}
            ] |
            if all(.[]; (.disabled | type) == "boolean") then . else error("invalid disabled state") end
        end
    ' <<<"$keys_response"
}

list_user_key_names() {
    list_user_keys | jq -c '[.[].name] | sort'
}

key_remote_status() {
    local key_name="$1" keys

    keys="$(list_user_keys)" || return 1
    if ! jq -e --arg name "$key_name" 'any(.[]; .name == $name)' <<<"$keys" >/dev/null; then
        printf 'absent\n'
    elif jq -e --arg name "$key_name" 'any(.[]; .name == $name and .disabled == true)' <<<"$keys" >/dev/null; then
        printf 'disabled\n'
    else
        printf 'enabled\n'
    fi
}

iam_mutation() {
    local method="$1" url="$2" status response_tmp curl_status=0
    local -a curl_args

    response_tmp="$(mktemp "${credentials_dir}/.iam-response.XXXXXX")" || return 1
    chmod 0600 "$response_tmp"
    write_access_header_file || {
        rm -f -- "$response_tmp"
        return 1
    }
    curl_args=(-sS --connect-timeout 5 --max-time 30 \
        -X "$method" \
        -H "@$ACCESS_HEADER_FILE" \
        -o "$response_tmp" -w '%{http_code}')
    if [[ "$method" == "POST" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data '{}')
    fi
    status="$(curl "${curl_args[@]}" "$url")" || curl_status=$?
    rm -f -- "$response_tmp" "$ACCESS_HEADER_FILE"
    if ((curl_status != 0)); then
        return 1
    fi
    if [[ "$status" == "404" ]]; then
        KEY_OPERATION_RESULT=absent
        return 0
    fi
    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        KEY_OPERATION_RESULT=success
        return 0
    fi
    return 1
}

delete_key() {
    local key_name="$1"

    iam_mutation DELETE "https://iam.googleapis.com/v1/$key_name"
}

disable_key() {
    local key_name="$1" remote_status

    remote_status="$(key_remote_status "$key_name")" || return 1
    case "$remote_status" in
        absent)
            KEY_OPERATION_RESULT=absent
            return 0
            ;;
        disabled)
            KEY_OPERATION_RESULT=success
            return 0
            ;;
        enabled)
            iam_mutation POST "https://iam.googleapis.com/v1/${key_name}:disable"
            ;;
    esac
}

enable_key() {
    local key_name="$1" remote_status

    remote_status="$(key_remote_status "$key_name")" || return 1
    case "$remote_status" in
        absent)
            log_error "Cannot enable absent rollback key $key_name"
            return 1
            ;;
        enabled)
            KEY_OPERATION_RESULT=success
            return 0
            ;;
        disabled)
            iam_mutation POST "https://iam.googleapis.com/v1/${key_name}:enable"
            [[ "$KEY_OPERATION_RESULT" != "absent" ]]
            ;;
    esac
}

validate_credentials_key() {
    local file="$1" expected_key_id="$2"

    [[ ! -L "$file" && -f "$file" ]] || return 1
    jq -e \
        --arg key_id "$expected_key_id" \
        --arg service_account "$SERVICE_ACCOUNT" \
        --arg project_id "$PROJECT_ID" '
        .type == "service_account" and
        .private_key_id == $key_id and
        .client_email == $service_account and
        .project_id == $project_id and
        .token_uri == "https://oauth2.googleapis.com/token" and
        (.private_key | type == "string" and startswith("-----BEGIN PRIVATE KEY-----") and contains("-----END PRIVATE KEY-----"))
    ' "$file" >/dev/null
}

install_credentials_file() {
    local source="$1" target="$2" mode="${3:-0440}"
    local credential_owner="${4-${ROTATION_CREDENTIAL_OWNER}}" target_tmp

    target_tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    if ! install -m "$mode" "$source" "$target_tmp"; then
        rm -f -- "$target_tmp"
        return 1
    fi
    if [[ -n "$credential_owner" ]] && ! chown -- "$credential_owner" "$target_tmp"; then
        rm -f -- "$target_tmp"
        return 1
    fi
    mv -f -- "$target_tmp" "$target"
}

preserve_previous_credentials() {
    if [[ -z "$STATE_CURRENT_KEY_ID" ]]; then
        return 0
    fi
    if validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID"; then
        return 0
    fi
    if [[ -e "$PREVIOUS_CREDENTIALS" || -L "$PREVIOUS_CREDENTIALS" ]]; then
        log_error "Previous credential backup is invalid or unsafe: $PREVIOUS_CREDENTIALS"
        return 1
    fi
    validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID" || {
        log_error "Current credentials cannot be preserved before replacement"
        return 1
    }
    install_credentials_file "$CREDENTIALS_FILE" "$PREVIOUS_CREDENTIALS" 0400 root
}

install_staged_credentials() {
    validate_credentials_key "$STAGED_CREDENTIALS" "$STATE_NEW_KEY_ID" || {
        log_error "Staged replacement credentials are invalid"
        return 1
    }
    preserve_previous_credentials || return 1
    install_credentials_file "$STAGED_CREDENTIALS" "$CREDENTIALS_FILE" 0440 || return 1
    rm -f -- "$STAGED_CREDENTIALS"
}

base64url() {
    base64 | tr -d '\n=' | tr '+/' '-_'
}

authenticate_credentials_once() {
    local file="$1" expected_key_id="$2"
    local email token_uri private_key_tmp request_tmp response_tmp
    local header payload signing_input signature assertion now curl_status=0

    validate_credentials_key "$file" "$expected_key_id" || return 1
    command -v openssl >/dev/null 2>&1 || {
        log_error "openssl is required to authenticate replacement credentials"
        return 1
    }
    email="$(jq -er '.client_email' "$file")" || return 1
    token_uri="$(jq -er '.token_uri' "$file")" || return 1
    private_key_tmp="$(mktemp "${credentials_dir}/.auth-key.XXXXXX")" || return 1
    request_tmp="$(mktemp "${credentials_dir}/.auth-request.XXXXXX")" || {
        rm -f -- "$private_key_tmp"
        return 1
    }
    response_tmp="$(mktemp "${credentials_dir}/.auth-response.XXXXXX")" || {
        rm -f -- "$private_key_tmp" "$request_tmp"
        return 1
    }
    chmod 0600 "$private_key_tmp" "$request_tmp" "$response_tmp"
    jq -er '.private_key' "$file" >"$private_key_tmp" || {
        rm -f -- "$private_key_tmp" "$request_tmp" "$response_tmp"
        return 1
    }

    now="$(now_epoch)"
    header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)"
    payload="$(jq -cn \
        --arg iss "$email" \
        --arg aud "$token_uri" \
        --argjson iat "$now" \
        '{iss: $iss, scope: "https://www.googleapis.com/auth/cloud-platform", aud: $aud, iat: $iat, exp: ($iat + 3600)}' | base64url)"
    signing_input="${header}.${payload}"
    signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$private_key_tmp" | base64url)" || {
        rm -f -- "$private_key_tmp" "$request_tmp" "$response_tmp"
        return 1
    }
    assertion="${signing_input}.${signature}"
    printf 'grant_type=urn%%3Aietf%%3Aparams%%3Aoauth%%3Agrant-type%%3Ajwt-bearer&assertion=%s' \
        "$assertion" >"$request_tmp"
    curl -fsS --connect-timeout 5 --max-time 30 \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary "@$request_tmp" \
        -o "$response_tmp" \
        "$token_uri" || curl_status=$?
    rm -f -- "$private_key_tmp" "$request_tmp"
    if ((curl_status != 0)) ||
        ! jq -e '.access_token | type == "string" and length > 0' "$response_tmp" >/dev/null; then
        rm -f -- "$response_tmp"
        return 1
    fi
    rm -f -- "$response_tmp"
}

authenticate_credentials_with_backoff() {
    local file="$1" expected_key_id="$2" attempt sleep_seconds

    for ((attempt = 1; attempt <= 10#$ROTATION_AUTH_MAX_RETRIES; attempt++)); do
        if authenticate_credentials_once "$file" "$expected_key_id"; then
            log_info "Authenticated service-account key $expected_key_id"
            return 0
        fi
        if ((attempt == 10#$ROTATION_AUTH_MAX_RETRIES)); then
            break
        fi
        sleep_seconds=$((10#$ROTATION_AUTH_SLEEP_SECONDS * attempt))
        log_info "Replacement credential authentication is not ready; retrying in ${sleep_seconds}s (${attempt}/${ROTATION_AUTH_MAX_RETRIES})"
        sleep "$sleep_seconds"
    done
    log_error "Replacement credentials could not authenticate after $ROTATION_AUTH_MAX_RETRIES attempts"
    return 1
}

resume_pending_prepare() {
    local recovered_key_id

    load_state || return 1
    case "$STATE_PHASE" in
        creating)
            if [[ -L "$STAGED_CREDENTIALS" || ! -f "$STAGED_CREDENTIALS" ]]; then
                log_error "Key creation has an ambiguous result; run audit, then recover with an explicitly confirmed orphan key ID"
                return 1
            fi
            recovered_key_id="$(credential_key_id "$STAGED_CREDENTIALS")" || {
                log_error "Could not recover replacement key ID from staged credentials"
                return 1
            }
            STATE_NEW_KEY_ID="$recovered_key_id"
            STATE_NEW_KEY_NAME="$SA_RESOURCE/keys/$STATE_NEW_KEY_ID"
            STATE_PHASE=staged
            write_state
            install_staged_credentials
            log_info "Recovered and installed staged key $STATE_NEW_KEY_ID"
            ;;
        staged | authenticated | ready | grace)
            validate_credentials_key "$CREDENTIALS_FILE" "$STATE_NEW_KEY_ID" || {
                if [[ "$STATE_PHASE" == "staged" ]] && validate_credentials_key "$STAGED_CREDENTIALS" "$STATE_NEW_KEY_ID"; then
                    install_staged_credentials || return 1
                else
                    log_error "Replacement key $STATE_NEW_KEY_ID is not installed at $CREDENTIALS_FILE"
                    return 1
                fi
            }
            if [[ -n "$STATE_CURRENT_KEY_ID" ]] && ! validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID"; then
                log_error "Previous credentials required for grace/rollback are missing or invalid"
                return 1
            fi
            log_info "Resuming $STATE_PHASE rotation for key $STATE_NEW_KEY_ID"
            ;;
        rolling-back)
            if ! validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID"; then
                validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID" || return 1
                install_credentials_file "$PREVIOUS_CREDENTIALS" "$CREDENTIALS_FILE" 0440 || return 1
            fi
            STATE_PHASE=rollback
            write_state
            log_info "Resumed rollback to previous key $STATE_CURRENT_KEY_ID"
            ;;
        rollback)
            validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID" || {
                log_error "Rollback credentials are not installed"
                return 1
            }
            ;;
        revoke-new)
            fetch_access_token || return 1
            if ! delete_key "$STATE_NEW_KEY_NAME"; then
                log_error "Failed to delete unusable replacement key $STATE_NEW_KEY_ID"
                return 1
            fi
            cleanup_state
            log_error "Cleaned up an unusable replacement key; retry rotation on the next run"
            return 1
            ;;
    esac
}

prepare_rotation() {
    local current_key_id="" file_modified_at file_age_seconds
    local new_key_response="" new_key_name new_key_id private_key_data staged_tmp
    local create_succeeded=true curl_status=0

    if [[ -L "$CREDENTIALS_FILE" || ( -e "$CREDENTIALS_FILE" && ! -f "$CREDENTIALS_FILE" ) ]]; then
        log_error "Credentials path is unsafe: $CREDENTIALS_FILE"
        return 1
    fi
    if [[ -e "$PENDING_STATE" || -L "$PENDING_STATE" ]]; then
        resume_pending_prepare
        return
    fi

    if [[ -f "$CREDENTIALS_FILE" ]]; then
        file_modified_at="$(stat -c %Y "$CREDENTIALS_FILE" 2>/dev/null || stat -f %m "$CREDENTIALS_FILE" 2>/dev/null)" || {
            log_error "Could not determine credentials age: $CREDENTIALS_FILE"
            return 1
        }
        file_age_seconds=$(( $(now_epoch) - file_modified_at ))
        if ((file_age_seconds < 10#$ROTATION_MIN_AGE_SECONDS)); then
            log_info "Credentials are younger than the rotation interval"
            return 0
        fi
        current_key_id="$(credential_key_id "$CREDENTIALS_FILE")" || {
            log_error "Existing credentials file is invalid: $CREDENTIALS_FILE"
            return 1
        }
        validate_credentials_key "$CREDENTIALS_FILE" "$current_key_id" || {
            log_error "Existing credentials file does not match the rotation target: $CREDENTIALS_FILE"
            return 1
        }
    fi

    fetch_access_token || return 1
    STATE_PHASE=creating
    STATE_CURRENT_KEY_ID="$current_key_id"
    STATE_NEW_KEY_ID=""
    STATE_NEW_KEY_NAME=""
    STATE_BASELINE_KEY_NAMES="$(list_user_key_names)" || return 1
    STATE_CREATED_AT="$(now_epoch)"
    STATE_READY_AT=0
    STATE_DISABLED_AT=0
    write_state

    log_info "Creating replacement key for $SERVICE_ACCOUNT"
    write_access_header_file || return 1
    new_key_response="$(curl -fsS --connect-timeout 5 --max-time 30 -X POST \
        -H "@$ACCESS_HEADER_FILE" \
        -H "Content-Type: application/json" \
        "https://iam.googleapis.com/v1/$SA_RESOURCE/keys")" || curl_status=$?
    rm -f -- "$ACCESS_HEADER_FILE"
    if ((curl_status != 0)); then
        create_succeeded=false
    fi
    if [[ "$create_succeeded" != "true" ]]; then
        log_error "Key creation had an indeterminate result; pending state prevents another key until audited recovery"
        return 1
    fi

    new_key_name="$(jq -er '.name | select(type == "string" and length > 0)' <<<"$new_key_response")" || {
        log_error "Key creation response omitted the key resource name; use audited recovery"
        return 1
    }
    new_key_id="${new_key_name##*/}"
    if [[ ! "$new_key_id" =~ ^[A-Za-z0-9_-]+$ ]] || [[ "$new_key_name" != "$SA_RESOURCE/keys/$new_key_id" ]]; then
        log_error "Key creation response contained an unexpected resource name; use audited recovery"
        return 1
    fi

    STATE_NEW_KEY_ID="$new_key_id"
    STATE_NEW_KEY_NAME="$new_key_name"
    private_key_data="$(jq -er '.privateKeyData | select(type == "string" and length > 0)' <<<"$new_key_response")" || {
        STATE_PHASE=revoke-new
        write_state
        if delete_key "$new_key_name"; then
            cleanup_state
        fi
        log_error "Key creation response omitted replacement credentials"
        return 1
    }

    staged_tmp="$(mktemp "${STAGED_CREDENTIALS}.tmp.XXXXXX")" || return 1
    if ! printf '%s' "$private_key_data" | base64 -d >"$staged_tmp" ||
        ! validate_credentials_key "$staged_tmp" "$new_key_id"; then
        rm -f -- "$staged_tmp"
        STATE_PHASE=revoke-new
        write_state
        if delete_key "$new_key_name"; then
            cleanup_state
        fi
        log_error "IAM returned invalid replacement credentials"
        return 1
    fi
    chmod 0600 "$staged_tmp"
    mv -f -- "$staged_tmp" "$STAGED_CREDENTIALS"

    STATE_PHASE=staged
    write_state
    if ! install_staged_credentials; then
        STATE_PHASE=revoke-new
        write_state
        if delete_key "$new_key_name"; then
            cleanup_state
        fi
        log_error "Could not safely preserve and install replacement credentials"
        return 1
    fi
    log_info "Installed replacement key $new_key_id; previous credentials remain available for rollback"
}

authenticate_rotation() {
    load_state || return 1
    case "$STATE_PHASE" in
        authenticated | ready | grace)
            return 0
            ;;
        staged)
            authenticate_credentials_with_backoff "$CREDENTIALS_FILE" "$STATE_NEW_KEY_ID" || return 1
            STATE_PHASE=authenticated
            write_state
            ;;
        *)
            log_error "Rotation cannot authenticate from phase $STATE_PHASE"
            return 1
            ;;
    esac
}

mark_rotation_ready() {
    load_state || return 1
    case "$STATE_PHASE" in
        ready | grace)
            return 0
            ;;
        authenticated)
            validate_credentials_key "$CREDENTIALS_FILE" "$STATE_NEW_KEY_ID" || {
                log_error "Authenticated replacement credentials are no longer installed"
                return 1
            }
            STATE_PHASE=ready
            STATE_READY_AT="$(now_epoch)"
            write_state
            log_info "Consumers are ready on authenticated replacement key $STATE_NEW_KEY_ID"
            ;;
        *)
            log_error "Rotation cannot become ready from phase $STATE_PHASE"
            return 1
            ;;
    esac
}

commit_rotation() {
    local current_key_name elapsed

    load_state || return 1
    validate_credentials_key "$CREDENTIALS_FILE" "$STATE_NEW_KEY_ID" || {
        log_error "Replacement credentials are not installed"
        return 1
    }

    if [[ "$STATE_PHASE" == "ready" ]]; then
        if [[ -z "$STATE_CURRENT_KEY_ID" ]]; then
            cleanup_state
            log_info "No previous local key was known; replacement committed without revocation"
            return 0
        fi
        if [[ "$STATE_CURRENT_KEY_ID" == "$STATE_NEW_KEY_ID" ]]; then
            log_error "Refusing to disable the installed replacement key"
            return 1
        fi
        validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID" || {
            log_error "Previous credentials are unavailable; refusing to remove rollback capability"
            return 1
        }

        current_key_name="$SA_RESOURCE/keys/$STATE_CURRENT_KEY_ID"
        fetch_access_token || return 1
        log_info "Disabling previous local key $STATE_CURRENT_KEY_ID"
        if ! disable_key "$current_key_name"; then
            log_error "Failed to disable previous local key $STATE_CURRENT_KEY_ID; ready state will retry"
            return 1
        fi
        if [[ "$KEY_OPERATION_RESULT" == "absent" ]]; then
            cleanup_state
            log_info "Previous local key was already absent; replacement committed"
            return 0
        fi
        STATE_PHASE=grace
        STATE_DISABLED_AT="$(now_epoch)"
        write_state
        log_info "Previous key is disabled and retained for a ${ROTATION_DISABLE_GRACE_SECONDS}s rollback grace period"
        return 0
    fi

    if [[ "$STATE_PHASE" != "grace" ]]; then
        log_error "Rotation cannot commit from phase $STATE_PHASE"
        return 1
    fi
    elapsed=$(( $(now_epoch) - STATE_DISABLED_AT ))
    if ((elapsed < 10#$ROTATION_DISABLE_GRACE_SECONDS)); then
        log_info "Previous key remains in rollback grace for $((10#$ROTATION_DISABLE_GRACE_SECONDS - elapsed))s"
        return 0
    fi

    current_key_name="$SA_RESOURCE/keys/$STATE_CURRENT_KEY_ID"
    fetch_access_token || return 1
    log_info "Deleting previous disabled key $STATE_CURRENT_KEY_ID after rollback grace"
    if ! delete_key "$current_key_name"; then
        log_error "Failed to delete previous key $STATE_CURRENT_KEY_ID; grace state will retry"
        return 1
    fi
    cleanup_state
    log_info "Committed replacement key $STATE_NEW_KEY_ID"
}

begin_rollback() {
    local current_key_name

    load_state || return 1
    case "$STATE_PHASE" in
        rollback)
            validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID" || return 1
            log_info "Rollback credentials are already restored; resuming consumer reload"
            return 0
            ;;
        rolling-back)
            validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID" || return 1
            if ! validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID"; then
                install_credentials_file "$PREVIOUS_CREDENTIALS" "$CREDENTIALS_FILE" 0440 || return 1
            fi
            STATE_PHASE=rollback
            write_state
            log_info "Resumed interrupted rollback to previous key $STATE_CURRENT_KEY_ID"
            return 0
            ;;
        grace) ;;
        *)
            log_error "Rollback is available only while the previous key is in grace"
            return 1
            ;;
    esac
    validate_credentials_key "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID" || {
        log_error "Previous credential backup is unavailable or invalid"
        return 1
    }
    validate_credentials_key "$CREDENTIALS_FILE" "$STATE_NEW_KEY_ID" || {
        log_error "Replacement credentials are unavailable; refusing an ambiguous rollback"
        return 1
    }

    current_key_name="$SA_RESOURCE/keys/$STATE_CURRENT_KEY_ID"
    fetch_access_token || return 1
    log_info "Re-enabling previous key $STATE_CURRENT_KEY_ID for rollback"
    enable_key "$current_key_name" || return 1
    authenticate_credentials_with_backoff "$PREVIOUS_CREDENTIALS" "$STATE_CURRENT_KEY_ID" || return 1

    install_credentials_file "$CREDENTIALS_FILE" "$REPLACEMENT_CREDENTIALS" 0400 root || return 1
    STATE_PHASE=rolling-back
    write_state
    install_credentials_file "$PREVIOUS_CREDENTIALS" "$CREDENTIALS_FILE" 0440 || return 1
    STATE_PHASE=rollback
    write_state
    log_info "Previous credentials restored; consumers must reload them before rollback completion"
}

finish_rollback() {
    load_state || return 1
    if [[ "$STATE_PHASE" != "rollback" ]]; then
        log_error "Rollback consumers cannot become ready from phase $STATE_PHASE"
        return 1
    fi
    validate_credentials_key "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID" || return 1
    authenticate_credentials_with_backoff "$CREDENTIALS_FILE" "$STATE_CURRENT_KEY_ID" || return 1
    fetch_access_token || return 1
    log_info "Disabling abandoned replacement key $STATE_NEW_KEY_ID"
    if ! disable_key "$STATE_NEW_KEY_NAME"; then
        log_error "Failed to disable abandoned replacement key; rollback state will retry"
        return 1
    fi
    if [[ "$KEY_OPERATION_RESULT" != "absent" ]]; then
        log_info "Deleting abandoned replacement key $STATE_NEW_KEY_ID"
        delete_key "$STATE_NEW_KEY_NAME" || return 1
    fi
    cleanup_state
    log_info "Rollback to key $STATE_CURRENT_KEY_ID completed"
}

retire_credentials() {
    local current_key_id current_key_name remaining_keys remaining_key_ids

    if [[ -e "$PENDING_STATE" || -L "$PENDING_STATE" ]]; then
        log_error "Resolve the pending rotation before retiring credentials: $PENDING_STATE"
        return 1
    fi
    if [[ ! -e "$CREDENTIALS_FILE" && ! -L "$CREDENTIALS_FILE" ]]; then
        # Local absence alone cannot prove revocation. The file may have been
        # removed manually while its remote private key remained valid. List
        # only USER_MANAGED keys and fail closed until the operator audits any
        # remaining IDs; never guess which externally managed key to delete.
        fetch_access_token || return 1
        remaining_keys="$(list_user_keys)" || return 1
        if [[ "$(jq -r 'length' <<<"$remaining_keys")" == "0" ]]; then
            log_info "No local credential or remote user-managed key remains; retirement is complete"
            return 0
        fi
        remaining_key_ids="$(jq -r '[.[].name | split("/")[-1]] | sort | join(", ")' <<<"$remaining_keys")" || return 1
        log_error "No local credential is available to identify the managed key, but remote user-managed keys remain: $remaining_key_ids"
        log_error "Audit and explicitly revoke the remaining key IDs before disabling managed credentials"
        return 1
    fi
    if [[ -L "$CREDENTIALS_FILE" || ! -f "$CREDENTIALS_FILE" ]]; then
        log_error "Credentials path is unsafe: $CREDENTIALS_FILE"
        return 1
    fi
    current_key_id="$(credential_key_id "$CREDENTIALS_FILE")" || {
        log_error "Existing credentials file is invalid: $CREDENTIALS_FILE"
        return 1
    }
    validate_credentials_key "$CREDENTIALS_FILE" "$current_key_id" || {
        log_error "Existing credentials do not match the retirement target"
        return 1
    }
    current_key_name="$SA_RESOURCE/keys/$current_key_id"
    fetch_access_token || return 1
    log_info "Deleting retired service-account key $current_key_id"
    if ! delete_key "$current_key_name"; then
        log_error "Failed to delete retired key $current_key_id"
        return 1
    fi
    rm -f -- "$CREDENTIALS_FILE" "$STAGED_CREDENTIALS" "$PREVIOUS_CREDENTIALS" \
        "$REPLACEMENT_CREDENTIALS"
    log_info "Retired local credentials for $SERVICE_ACCOUNT"
}

creation_candidates() {
    local current_names

    fetch_access_token || return 1
    current_names="$(list_user_key_names)" || return 1
    jq -cn --argjson before "$STATE_BASELINE_KEY_NAMES" --argjson after "$current_names" \
        '$after - $before | sort'
}

rotation_audit() {
    local candidates='[]' grace_remaining=0 elapsed

    if [[ ! -e "$PENDING_STATE" && ! -L "$PENDING_STATE" ]]; then
        jq -n '{version: 1, phase: "idle", recovery_required: false, candidate_key_ids: [], grace_remaining_seconds: 0}'
        return 0
    fi
    load_state || return 1
    if [[ "$STATE_PHASE" == "creating" ]]; then
        candidates="$(creation_candidates)" || return 1
    fi
    if [[ "$STATE_PHASE" == "grace" ]]; then
        elapsed=$(( $(now_epoch) - STATE_DISABLED_AT ))
        if ((elapsed < 10#$ROTATION_DISABLE_GRACE_SECONDS)); then
            grace_remaining=$((10#$ROTATION_DISABLE_GRACE_SECONDS - elapsed))
        fi
    fi
    jq -n \
        --arg phase "$STATE_PHASE" \
        --arg current_key_id "$STATE_CURRENT_KEY_ID" \
        --arg new_key_id "$STATE_NEW_KEY_ID" \
        --argjson candidate_names "$candidates" \
        --argjson created_at "$STATE_CREATED_AT" \
        --argjson ready_at "$STATE_READY_AT" \
        --argjson disabled_at "$STATE_DISABLED_AT" \
        --argjson grace_remaining "$grace_remaining" '
        {
            version: 1,
            phase: $phase,
            current_key_id: $current_key_id,
            new_key_id: $new_key_id,
            recovery_required: ($phase == "creating"),
            candidate_key_ids: [$candidate_names[] | split("/")[-1]],
            created_at: $created_at,
            ready_at: $ready_at,
            disabled_at: $disabled_at,
            grace_remaining_seconds: $grace_remaining
        }'
}

recover_ambiguous_creation() {
    local candidates candidate_id creation_age

    load_state || return 1
    if [[ "$STATE_PHASE" != "creating" ]]; then
        log_error "Audited recovery is valid only for an ambiguous creating state"
        return 1
    fi
    creation_age=$(( $(now_epoch) - STATE_CREATED_AT ))
    if ((creation_age < 10#$ROTATION_RECOVERY_SETTLE_SECONDS)); then
        rotation_audit
        log_error "Ambiguous creation must settle for ${ROTATION_RECOVERY_SETTLE_SECONDS}s before recovery; no key was changed"
        return 1
    fi
    candidates="$(creation_candidates)" || return 1
    if [[ "$(jq -r 'length' <<<"$candidates")" == "0" ]]; then
        cleanup_state
        log_info "Audit found no key beyond the pre-create baseline; cleared ambiguous state"
        return 0
    fi
    if [[ "$(jq -r 'length' <<<"$candidates")" != "1" ]]; then
        rotation_audit
        log_error "Recovery is ambiguous because more than one post-baseline key exists; no key was changed"
        return 1
    fi
    candidate_id="$(jq -r '.[0] | split("/")[-1]' <<<"$candidates")"
    if [[ -z "$RECOVERY_KEY_ID" || "$RECOVERY_KEY_ID" != "$candidate_id" ]]; then
        rotation_audit
        log_error "Recovery requires the single audited candidate key ID as the final argument; no key was changed"
        return 1
    fi
    fetch_access_token || return 1
    log_info "Deleting explicitly confirmed orphan key $candidate_id from ambiguous creation"
    delete_key "$SA_RESOURCE/keys/$candidate_id" || return 1
    cleanup_state
    log_info "Audited recovery completed; a later run may create a new replacement"
}

rotation_status() {
    if [[ ! -e "$PENDING_STATE" && ! -L "$PENDING_STATE" ]]; then
        printf 'idle\n'
        return 0
    fi
    load_state || return 1
    printf '%s\n' "$STATE_PHASE"
}

case "$ACTION" in
    prepare) prepare_rotation ;;
    status) rotation_status ;;
    audit) rotation_audit ;;
    recover) recover_ambiguous_creation ;;
    authenticate) authenticate_rotation ;;
    ready) mark_rotation_ready ;;
    commit) commit_rotation ;;
    rollback) begin_rollback ;;
    rollback-ready) finish_rollback ;;
    retire) retire_credentials ;;
esac
