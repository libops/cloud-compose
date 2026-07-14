#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/rootfs/home/cloud-compose/install-dependencies-cos.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

BIN_DIR="${TEST_ROOT}/bin"
CLOUD_HOME="${TEST_ROOT}/home/cloud-compose"
DATA_DIR="${TEST_ROOT}/mnt/disks/data"
DOCKER_CONFIG_DIR="${TEST_ROOT}/docker-config"
HARNESS="${TEST_ROOT}/harness.sh"
CALL_LOG="${TEST_ROOT}/calls.log"
mkdir -p "$BIN_DIR" "$CLOUD_HOME" "$DATA_DIR" "$DOCKER_CONFIG_DIR"

# Static trust contract: the build environment is an immutable multi-platform
# image, and the GNU Make archive is verified before any extraction occurs.
if ! grep -Eq '^ALPINE_BUILD_IMAGE="alpine:3\.22@sha256:[0-9a-f]{64}"$' "$INSTALLER"; then
    echo "COS bootstrap Alpine image is not digest pinned" >&2
    exit 1
fi
# Assert the literal command in the bootstrap script.
# shellcheck disable=SC2016
if ! grep -Fq 'echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -' "$INSTALLER"; then
    echo "COS bootstrap does not verify the GNU Make source archive" >&2
    exit 1
fi
checksum_line="$(grep -nF 'sha256sum -c -' "$INSTALLER" | head -n1)"
archive_line="$(grep -nF 'tar -xzf /tmp/make.tar.gz' "$INSTALLER" | head -n1)"
if (( ${checksum_line%%:*} >= ${archive_line%%:*} )); then
    echo "COS bootstrap extracts GNU Make before checksum verification" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*--network[[:space:]]+host([[:space:]\\]|$)' "$INSTALLER"; then
    echo "COS bootstrap exposes third-party build code to the host network" >&2
    exit 1
fi
grep -Fq 'iptables -C DOCKER-USER -d 169.254.169.254/32 -j DROP' "$INSTALLER" || {
    echo "COS bootstrap does not require the GCP metadata deny policy" >&2
    exit 1
}
grep -Fq 'COS_TOOL_STATE_DIR:-/mnt/disks/data/cloud-compose-tools' "$INSTALLER" || {
    echo "COS bootstrap stores an executable tool on a potentially noexec filesystem" >&2
    exit 1
}
if grep -Fq '/var/lib/cloud-compose/tools' "$INSTALLER"; then
    echo "COS bootstrap stores GNU Make on the noexec stateful /var mount" >&2
    exit 1
fi
grep -Fq '== *",noexec,"*' "$INSTALLER" || {
    echo "COS bootstrap does not reject a noexec tool-state mount" >&2
    exit 1
}

# The package bootstrap must move between independent official HTTPS mirrors,
# while retaining apk's normal index and package signature verification.
for mirror in \
    https://dl-cdn.alpinelinux.org/alpine \
    https://mirror.math.princeton.edu/pub/alpinelinux \
    https://mirror.fel.cvut.cz/alpine; do
    grep -Fq "$mirror" "$INSTALLER" || {
        echo "COS bootstrap is missing Alpine package mirror: $mirror" >&2
        exit 1
    }
done
grep -Fq 'for alpine_mirror in ${alpine_mirrors}; do' "$INSTALLER" || {
    echo "COS bootstrap does not fail over between Alpine package mirrors" >&2
    exit 1
}
grep -Fq 'if apk update && apk add build-base curl make tar; then' "$INSTALLER" || {
    echo "COS bootstrap does not validate an index before installing packages" >&2
    exit 1
}
grep -Fq 'All configured Alpine package mirrors failed' "$INSTALLER" || {
    echo "COS bootstrap accepts exhaustion of all Alpine package mirrors" >&2
    exit 1
}
if grep -Fq -- '--allow-untrusted' "$INSTALLER"; then
    echo "COS bootstrap disables Alpine package signature verification" >&2
    exit 1
fi

cat >"$HARNESS" <<'EOF'
#!/usr/bin/env bash
source "$COS_BOOTSTRAP_INSTALLER"
retry_until_success() {
    "$@"
}
export DOCKER_CONFIG="$MOCK_DOCKER_CONFIG"
install_cos_dependencies "$TEST_CLOUD_HOME" "" "$TEST_DOCKER_BIN"
EOF

cat >"${BIN_DIR}/bash" <<'EOF'
#!/bin/bash
printf 'plugin:%s:%s\n' "${DOCKER_CLI_PLUGIN_DIR:-}" "$*" >>"$MOCK_CALL_LOG"
EOF

cat >"${BIN_DIR}/chown" <<'EOF'
#!/bin/bash
printf 'chown:%s\n' "$*" >>"$MOCK_CALL_LOG"
EOF

cat >"${BIN_DIR}/docker" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'docker:' >>"$MOCK_CALL_LOG"
printf ' %q' "$@" >>"$MOCK_CALL_LOG"
printf '\n' >>"$MOCK_CALL_LOG"

output_dir=""
while (($# > 0)); do
    if [[ "$1" == "-v" ]]; then
        output_dir="${2%:/out}"
        break
    fi
    shift
done
[[ -n "$output_dir" ]]
printf '%s' partial >"${output_dir}/.cloud-compose-make.pending"
if [[ "${FAKE_DOCKER_FAIL:-false}" == "true" ]]; then
    exit 1
fi
cat >"${output_dir}/.cloud-compose-make.pending" <<'MAKE'
#!/bin/sh
echo 'GNU Make 4.4.1'
MAKE
chmod 0755 "${output_dir}/.cloud-compose-make.pending"
mv -f "${output_dir}/.cloud-compose-make.pending" "${output_dir}/make"
EOF

cat >"${BIN_DIR}/findmnt" <<'EOF'
#!/bin/bash
if [[ "${FAKE_FINDMNT_NOEXEC:-false}" == "true" ]]; then
    printf '%s\n' 'rw,nosuid,nodev,noexec,relatime'
else
    printf '%s\n' 'rw,relatime'
fi
EOF

chmod +x "$HARNESS" "${BIN_DIR}/bash" "${BIN_DIR}/chown" "${BIN_DIR}/docker" "${BIN_DIR}/findmnt"

PATH="${BIN_DIR}:$PATH" \
    COS_TOOL_STATE_DIR="$DATA_DIR" \
    COS_BOOTSTRAP_INSTALLER="$INSTALLER" \
    TEST_CLOUD_HOME="$CLOUD_HOME" \
    TEST_DATA_DIR="$DATA_DIR" \
    TEST_DOCKER_BIN="${BIN_DIR}/docker" \
    MOCK_DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
    MOCK_CALL_LOG="$CALL_LOG" \
    /bin/bash "$HARNESS"

grep -Fq "plugin:${DOCKER_CONFIG_DIR}/cli-plugins:${CLOUD_HOME}/install-docker-plugins.sh" "$CALL_LOG"
grep -Fq "plugin:${CLOUD_HOME}/.docker/cli-plugins:${CLOUD_HOME}/install-docker-plugins.sh" "$CALL_LOG"
grep -Eq 'docker: .*alpine:3\.22@sha256:[0-9a-f]{64}' "$CALL_LOG"
[[ -x "${DATA_DIR}/make" ]]
"${DATA_DIR}/make" --version | grep -Fq 'GNU Make 4.4.1'
[[ -f "${DATA_DIR}/make.state" ]]
[[ -L "${CLOUD_HOME}/bin/make" ]]
[[ "$(readlink "${CLOUD_HOME}/bin/make")" == "${DATA_DIR}/make" ]]

# A failed replacement must not promote a partial binary or leave a pending
# artifact that a later boot could mistake for a completed build.
printf '%s' known-invalid-old >"${DATA_DIR}/make"
chmod 0755 "${DATA_DIR}/make"
old_checksum="$(sha256sum "${DATA_DIR}/make")"
if PATH="${BIN_DIR}:$PATH" \
    FAKE_DOCKER_FAIL=true \
    COS_TOOL_STATE_DIR="$DATA_DIR" \
    COS_BOOTSTRAP_INSTALLER="$INSTALLER" \
    TEST_CLOUD_HOME="$CLOUD_HOME" \
    TEST_DATA_DIR="$DATA_DIR" \
    TEST_DOCKER_BIN="${BIN_DIR}/docker" \
    MOCK_DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
    MOCK_CALL_LOG="$CALL_LOG" \
    /bin/bash "$HARNESS" >/dev/null 2>&1; then
    echo "COS bootstrap accepted a failed partial Make build" >&2
    exit 1
fi
[[ "$(sha256sum "${DATA_DIR}/make")" == "$old_checksum" ]]
[[ ! -e "${DATA_DIR}/.cloud-compose-make.pending" ]]

# The production default is on an executable persistent disk. Any operator
# override that resolves to a noexec mount must fail before a build container
# or cached binary can be accepted.
docker_calls_before_noexec="$(grep -c '^docker:' "$CALL_LOG")"
if PATH="${BIN_DIR}:$PATH" \
    FAKE_FINDMNT_NOEXEC=true \
    COS_TOOL_STATE_DIR="$DATA_DIR" \
    COS_BOOTSTRAP_INSTALLER="$INSTALLER" \
    TEST_CLOUD_HOME="$CLOUD_HOME" \
    TEST_DATA_DIR="$DATA_DIR" \
    TEST_DOCKER_BIN="${BIN_DIR}/docker" \
    MOCK_DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
    MOCK_CALL_LOG="$CALL_LOG" \
    /bin/bash "$HARNESS" >/dev/null 2>&1; then
    echo "COS bootstrap accepted a noexec tool-state mount" >&2
    exit 1
fi
docker_calls_after_noexec="$(grep -c '^docker:' "$CALL_LOG")"
if [[ "$docker_calls_after_noexec" != "$docker_calls_before_noexec" ]]; then
    echo "COS bootstrap launched a build container before rejecting a noexec mount" >&2
    exit 1
fi

if grep -Eq '"\$make_path"[[:space:]]+--version' "$INSTALLER"; then
    echo "COS bootstrap executes a mutable host Make path during validation" >&2
    exit 1
fi

echo "COS bootstrap artifact trust contract passed"
