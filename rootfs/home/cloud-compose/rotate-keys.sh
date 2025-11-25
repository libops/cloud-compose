#!/bin/bash

set -eou pipefail

SERVICE_ACCOUNT="$1"
PROJECT_ID="$2"
CREDENTIALS_FILE="$3"

# do not rotate if the file is less than 24h old
if [[ -f "$CREDENTIALS_FILE" ]]; then
    FILE_AGE_SECONDS=$(( $(date +%s) - $(stat -c %Y "$CREDENTIALS_FILE" 2>/dev/null || stat -f %m "$CREDENTIALS_FILE" 2>/dev/null) ))
    if [[ $FILE_AGE_SECONDS -lt 86400 ]]; then
        exit 0
    fi
fi


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

CURRENT_KEY_ID=
if [[ -f "$CREDENTIALS_FILE" ]]; then
    log_info "Reading service account from existing credentials file..."
    CURRENT_KEY_ID=$(jq -r '.private_key_id' "$CREDENTIALS_FILE")
else
    log_warn "Credentials file not found: $CREDENTIALS_FILE"
fi

log_info "Service Account: $SERVICE_ACCOUNT"
log_info "Project ID: $PROJECT_ID"
log_info "Current Key ID: $CURRENT_KEY_ID"

log_info "Getting access token from metadata server..."
ACCESS_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | jq -er '.access_token')

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "Failed to get access token from metadata server"
    exit 1
fi

SA_RESOURCE="projects/$PROJECT_ID/serviceAccounts/$SERVICE_ACCOUNT"

log_info "Listing all keys for service account..."
KEYS_RESPONSE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://iam.googleapis.com/v1/$SA_RESOURCE/keys")
USER_KEYS=$(echo "$KEYS_RESPONSE" | jq -r '.keys[] | select(.keyType == "USER_MANAGED") | .name')
KEY_COUNT=$(echo "$USER_KEYS" | grep -c "^" || true)
log_info "Found $KEY_COUNT user-managed key(s)"

log_info "Deleting old keys (keeping current key: $CURRENT_KEY_ID)..."
DELETED_COUNT=0
while IFS= read -r key_name; do
    if [[ -z "$key_name" ]]; then
        continue
    fi

    # Extract just the key ID from the full resource name
    # Format: projects/{PROJECT}/serviceAccounts/{EMAIL}/keys/{KEY_ID}
    KEY_ID=$(basename "$key_name")

    if [[ "$KEY_ID" == "$CURRENT_KEY_ID" ]]; then
        log_warn "Skipping current key: $KEY_ID"
        continue
    fi

    log_info "Deleting key: $KEY_ID"
    DELETE_RESPONSE=$(curl -s -X DELETE \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -w "\nHTTP_CODE:%{http_code}" \
        "https://iam.googleapis.com/v1/$key_name")

    HTTP_CODE=$(echo "$DELETE_RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)

    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
        log_info "Successfully deleted key: $KEY_ID"
        ((DELETED_COUNT++))
    else
        log_error "Failed to delete key: $KEY_ID (HTTP $HTTP_CODE)"
        echo "$DELETE_RESPONSE"
    fi
done <<< "$USER_KEYS"

log_info "Deleted $DELETED_COUNT old key(s)"

# Create a new key
log_info "Creating new service account key..."
NEW_KEY_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    "https://iam.googleapis.com/v1/$SA_RESOURCE/keys")

# Check if key creation was successful
if echo "$NEW_KEY_RESPONSE" | jq -e '.privateKeyData' > /dev/null 2>&1; then
    PRIVATE_KEY_DATA=$(echo "$NEW_KEY_RESPONSE" | jq -r '.privateKeyData')
    NEW_KEY_ID=$(echo "$NEW_KEY_RESPONSE" | jq -r '.name' | xargs basename)

    log_info "New key created: $NEW_KEY_ID"

    log_info "Saving new credentials to: $CREDENTIALS_FILE"
    echo "$PRIVATE_KEY_DATA" | base64 -d > "$CREDENTIALS_FILE"

    chown 100 "$CREDENTIALS_FILE"
    chmod 440 "$CREDENTIALS_FILE"

    log_info "Successfully rotated service account key!"
    log_info "Old key ID: $CURRENT_KEY_ID (deleted)"
    log_info "New key ID: $NEW_KEY_ID"
    log_info "Total keys deleted: $DELETED_COUNT"
else
    log_error "Failed to create new key"
    echo "$NEW_KEY_RESPONSE" | jq '.'
    exit 1
fi
