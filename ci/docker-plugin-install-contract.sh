#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/rootfs/home/cloud-compose/install-docker-plugins.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

BIN_DIR="${TEST_ROOT}/bin"
PLUGIN_DIR="${TEST_ROOT}/plugins"
HARNESS="${TEST_ROOT}/harness.sh"
CURL_LOG="${TEST_ROOT}/curl.log"
mkdir -p "$BIN_DIR" "$PLUGIN_DIR"

cat >"$HARNESS" <<'EOF'
#!/usr/bin/env bash
source "$DOCKER_PLUGIN_INSTALLER"
retry_until_success() {
    "$@"
}
install_docker_plugins
EOF

cat >"${BIN_DIR}/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
    printf '%s\n' x86_64
    exit 0
fi
exec /usr/bin/uname "$@"
EOF

cat >"${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""
while (($# > 0)); do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        -*) shift ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

[[ -n "$url" && -n "$output" ]]
printf '%s\n' "$url" >>"$MOCK_CURL_LOG"
asset="${url##*/}"

if [[ "$asset" == "checksums.txt" ]]; then
    version="${url%/checksums.txt}"
    version="${version##*/}"
    case "$url" in
        */docker/compose/*)
            asset="docker-compose-linux-x86_64"
            payload="$MOCK_COMPOSE_EXPECTED_PAYLOAD"
            ;;
        */docker/buildx/*)
            asset="buildx-${version}.linux-amd64"
            payload="$MOCK_BUILDX_EXPECTED_PAYLOAD"
            ;;
        *)
            echo "unexpected checksum URL: $url" >&2
            exit 1
            ;;
    esac
    checksum="$(printf '%s' "$payload" | sha256sum)"
    printf '%s *%s\n' "${checksum%% *}" "$asset" >"$output"
    exit 0
fi

case "$asset" in
    docker-compose-linux-x86_64)
        printf '%s' "$MOCK_COMPOSE_DOWNLOAD_PAYLOAD" >"$output"
        ;;
    buildx-v*.linux-amd64)
        printf '%s' "$MOCK_BUILDX_DOWNLOAD_PAYLOAD" >"$output"
        ;;
    *)
        echo "unexpected binary URL: $url" >&2
        exit 1
        ;;
esac
EOF

chmod +x "$HARNESS" "${BIN_DIR}/uname" "${BIN_DIR}/curl"

run_installer() {
    local compose_version="$1"
    local buildx_version="$2"
    local compose_expected="$3"
    local compose_download="$4"
    local buildx_expected="$5"
    local buildx_download="$6"

    PATH="${BIN_DIR}:$PATH" \
        DOCKER_PLUGIN_INSTALLER="$INSTALLER" \
        CLOUD_COMPOSE_RELEASE_CHECKSUM_PROGRAM="$ROOT_DIR/rootfs/etc/cloud-compose/awk/release-checksum.awk" \
        DOCKER_CLI_PLUGIN_DIR="$PLUGIN_DIR" \
        DOCKER_COMPOSE_VERSION="$compose_version" \
        DOCKER_BUILDX_VERSION="$buildx_version" \
        MOCK_CURL_LOG="$CURL_LOG" \
        MOCK_COMPOSE_EXPECTED_PAYLOAD="$compose_expected" \
        MOCK_COMPOSE_DOWNLOAD_PAYLOAD="$compose_download" \
        MOCK_BUILDX_EXPECTED_PAYLOAD="$buildx_expected" \
        MOCK_BUILDX_DOWNLOAD_PAYLOAD="$buildx_download" \
        bash "$HARNESS"
}

assert_content() {
    local expected="$1"
    local path="$2"
    local actual

    actual="$(<"$path")"
    if [[ "$actual" != "$expected" ]]; then
        echo "unexpected content in $path: $actual" >&2
        exit 1
    fi
}

# A valid release installs both plugins only after their selected manifest
# entries verify, and leaves executable final files.
run_installer v1.2.3 v0.10.0 \
    compose-v1 compose-v1 \
    buildx-v1 buildx-v1
assert_content compose-v1 "${PLUGIN_DIR}/docker-compose"
assert_content buildx-v1 "${PLUGIN_DIR}/docker-buildx"
[[ -x "${PLUGIN_DIR}/docker-compose" ]]
[[ -x "${PLUGIN_DIR}/docker-buildx" ]]

# An executable modified in place is not trusted merely because it exists; the
# next run repairs it from a verified download for the configured release.
printf '%s' locally-tampered >"${PLUGIN_DIR}/docker-buildx"
run_installer v1.2.3 v0.10.0 \
    compose-v1 should-not-be-downloaded \
    buildx-v1 buildx-v1
assert_content compose-v1 "${PLUGIN_DIR}/docker-compose"
assert_content buildx-v1 "${PLUGIN_DIR}/docker-buildx"

# A tampered upgrade must fail closed and preserve the previously verified
# executable instead of replacing it with the failed download.
if run_installer v2.0.0 v0.10.0 \
    compose-v2 tampered-compose \
    buildx-v1 tampered-buildx; then
    echo "tampered Docker Compose download unexpectedly installed" >&2
    exit 1
fi
assert_content compose-v1 "${PLUGIN_DIR}/docker-compose"
assert_content buildx-v1 "${PLUGIN_DIR}/docker-buildx"

# Configured version changes reconcile existing executables for both plugins.
run_installer v2.0.0 v0.11.0 \
    compose-v2 compose-v2 \
    buildx-v2 buildx-v2
assert_content compose-v2 "${PLUGIN_DIR}/docker-compose"
assert_content buildx-v2 "${PLUGIN_DIR}/docker-buildx"

if find "$PLUGIN_DIR" -mindepth 1 -maxdepth 1 -type d -name '.docker-*' -print -quit | grep -q .; then
    echo "plugin installer left a temporary directory behind" >&2
    exit 1
fi

echo "Docker CLI plugin verification contract passed"
