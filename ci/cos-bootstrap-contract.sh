#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT_DIR}/rootfs/home/cloud-compose/install-dependencies-cos.sh"
BUILD_PROGRAM="${ROOT_DIR}/rootfs/etc/cloud-compose/libexec/build-cos-make.sh"
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
if ! grep -Fqx 'ALPINE_BUILD_IMAGE="alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"' "$INSTALLER"; then
    echo "COS bootstrap Alpine image is not digest pinned" >&2
    exit 1
fi
grep -Fq '"${alpine_mirror}/v3.22/main"' "$BUILD_PROGRAM" || {
    echo "COS bootstrap Alpine main repository does not match the pinned image release" >&2
    exit 1
}
grep -Fq '"${alpine_mirror}/v3.22/community"' "$BUILD_PROGRAM" || {
    echo "COS bootstrap Alpine community repository does not match the pinned image release" >&2
    exit 1
}
# Assert the literal command in the checked-in build program.
# shellcheck disable=SC2016
if ! grep -Fq 'echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -' "$BUILD_PROGRAM"; then
    echo "COS bootstrap does not verify the GNU Make source archive" >&2
    exit 1
fi
checksum_line="$(grep -nF 'sha256sum -c -' "$BUILD_PROGRAM" | head -n1)"
archive_line="$(grep -nF 'tar -xzf /tmp/make.tar.gz' "$BUILD_PROGRAM" | head -n1)"
if (( ${checksum_line%%:*} >= ${archive_line%%:*} )); then
    echo "COS bootstrap extracts GNU Make before checksum verification" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*--network[[:space:]]+host([[:space:]\\]|$)' "$INSTALLER"; then
    echo "COS bootstrap exposes third-party build code to the host network" >&2
    exit 1
fi
[[ -x "$BUILD_PROGRAM" ]] || {
    echo "COS checked-in Make build program is not executable" >&2
    exit 1
}
grep -Fq -- '-v "${make_build_program}:/tmp/cloud-compose-build-cos-make.sh:ro"' "$INSTALLER" || {
    echo "COS bootstrap does not mount its checked-in Make build program read-only" >&2
    exit 1
}
grep -Fq '/bin/sh /tmp/cloud-compose-build-cos-make.sh; then' "$INSTALLER" || {
    echo "COS bootstrap does not invoke its checked-in Make build program by path" >&2
    exit 1
}
if grep -Eq '/bin/sh[[:space:]]+-[^[:space:]]*c[[:space:]]' "$INSTALLER"; then
    echo "COS bootstrap still embeds a shell program in a command argument" >&2
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
    grep -Fq "$mirror" "$BUILD_PROGRAM" || {
        echo "COS bootstrap is missing Alpine package mirror: $mirror" >&2
        exit 1
    }
done
grep -Fq 'for alpine_mirror in ${alpine_mirrors}; do' "$BUILD_PROGRAM" || {
    echo "COS bootstrap does not fail over between Alpine package mirrors" >&2
    exit 1
}
grep -Fq 'if apk update && apk add build-base curl make tar; then' "$BUILD_PROGRAM" || {
    echo "COS bootstrap does not validate an index before installing packages" >&2
    exit 1
}
grep -Fq 'All configured Alpine package mirrors failed' "$BUILD_PROGRAM" || {
    echo "COS bootstrap accepts exhaustion of all Alpine package mirrors" >&2
    exit 1
}
if grep -Fq -- '--allow-untrusted' "$BUILD_PROGRAM"; then
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
install_cos_dependencies "$TEST_CLOUD_HOME" "" "$TEST_DOCKER_BIN" "$TEST_BUILD_PROGRAM"
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
    TEST_BUILD_PROGRAM="$BUILD_PROGRAM" \
    MOCK_DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
    MOCK_CALL_LOG="$CALL_LOG" \
    /bin/bash "$HARNESS"

grep -Fq "plugin:${DOCKER_CONFIG_DIR}/cli-plugins:${CLOUD_HOME}/install-docker-plugins.sh" "$CALL_LOG"
grep -Fq "plugin:${CLOUD_HOME}/.docker/cli-plugins:${CLOUD_HOME}/install-docker-plugins.sh" "$CALL_LOG"
grep -Fq 'alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce' "$CALL_LOG"
grep -Fq "${BUILD_PROGRAM}:/tmp/cloud-compose-build-cos-make.sh:ro" "$CALL_LOG"
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
    TEST_BUILD_PROGRAM="$BUILD_PROGRAM" \
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
    TEST_BUILD_PROGRAM="$BUILD_PROGRAM" \
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
