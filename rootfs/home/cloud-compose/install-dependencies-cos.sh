#!/usr/bin/env bash

set -euo pipefail

# renovate: datasource=docker depName=alpine packageName=alpine versioning=docker
ALPINE_BUILD_IMAGE="alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce"
MAKE_VERSION="4.4.1"

valid_make_binary() {
    local make_path="$1" state_path="$2" state_version state_sha actual_sha

    [[ ! -L "$make_path" && -f "$make_path" && -x "$make_path" ]] || return 1
    [[ ! -L "$state_path" && -f "$state_path" ]] || return 1
    read -r state_version state_sha <"$state_path" || return 1
    [[ "$state_version" == "$MAKE_VERSION" && "$state_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_sha="$(sha256sum -- "$make_path")" || return 1
    [[ "${actual_sha%% *}" == "$state_sha" ]]
}

# This function is sourced by the COS bootstrap contract, which supplies all
# four arguments even though the executable entrypoint below uses defaults.
# shellcheck disable=SC2120
install_cos_dependencies() {
    local cloud_compose_home="${1:-/home/cloud-compose}"
    # COS mounts both /home and /var with noexec. Keep the verified Make binary
    # on the executable persistent data disk; only the unprivileged application
    # PATH consumes the published symlink.
    local tool_state_dir="${2:-${COS_TOOL_STATE_DIR:-/mnt/disks/data/libops-managed/bin}}"
    local docker_bin="${3:-/usr/bin/docker}"
    local make_build_program="${4:-/etc/cloud-compose/libexec/build-cos-make.sh}"
    local make_path pending_make_path make_state_path make_state_tmp make_sha
    local tool_mount_options installer_uid installer_gid

    if ! command -v openssl >/dev/null 2>&1; then
        echo "COS must provide openssl for service-account authentication and application key scaffolding" >&2
        return 1
    fi

    if [[ "$tool_state_dir" != /* || "$tool_state_dir" == "/" || -L "$tool_state_dir" ||
        "$tool_state_dir" =~ (^|/)\.\.?(/|$) ]]; then
        echo "COS tool state directory is unsafe: $tool_state_dir" >&2
        return 1
    fi
    mkdir -p \
        "${DOCKER_CONFIG}/cli-plugins" \
        "${cloud_compose_home}/.docker/cli-plugins" \
        "${cloud_compose_home}/bin"
    mkdir -p -- "$tool_state_dir"
    if [[ -L "$tool_state_dir" || ! -d "$tool_state_dir" ]]; then
        echo "COS tool state directory is unsafe: $tool_state_dir" >&2
        return 1
    fi
    tool_mount_options="$(findmnt -n -o OPTIONS --target "$tool_state_dir")" || {
        echo "Could not inspect COS tool state mount: $tool_state_dir" >&2
        return 1
    }
    if [[ ",${tool_mount_options}," == *",noexec,"* ]]; then
        echo "COS tool state directory is on a noexec filesystem: $tool_state_dir" >&2
        return 1
    fi
    installer_uid="$(id -u)"
    installer_gid="$(id -g)"
    chown "${installer_uid}:${installer_gid}" "$tool_state_dir"
    chmod 0755 "$tool_state_dir"
    # This directory is on the privileged host PATH. Close legacy
    # application ownership before publishing any verified tool link. The
    # installer is root in production; the numeric identity keeps the
    # standalone contract harness unprivileged.
    chown "${installer_uid}:${installer_gid}" "${cloud_compose_home}/bin"
    chmod 0755 "${cloud_compose_home}/bin"
    DOCKER_CLI_PLUGIN_DIR="${DOCKER_CONFIG}/cli-plugins" \
        bash "${cloud_compose_home}/install-docker-plugins.sh"
    DOCKER_CLI_PLUGIN_DIR="${cloud_compose_home}/.docker/cli-plugins" \
        bash "${cloud_compose_home}/install-docker-plugins.sh"
    chown -R cloud-compose:cloud-compose \
        "$DOCKER_CONFIG" \
        "${cloud_compose_home}/.docker"

    make_path="${tool_state_dir}/make"
    make_state_path="${tool_state_dir}/make.state"
    pending_make_path="${tool_state_dir}/.cloud-compose-make.pending"
    if ! valid_make_binary "$make_path" "$make_state_path"; then
        if [[ "${CLOUD_COMPOSE_PROVIDER:-}" == "gcp" ]]; then
            if ! command -v iptables >/dev/null 2>&1 ||
                ! iptables -C DOCKER-USER -d 169.254.169.254/32 -j DROP >/dev/null 2>&1; then
                echo "Refusing COS bootstrap container before the GCP metadata deny policy is active" >&2
                return 1
            fi
        fi
        if [[ -L "$make_build_program" || ! -f "$make_build_program" || ! -x "$make_build_program" ]]; then
            echo "COS Make build program is missing or unsafe: $make_build_program" >&2
            return 1
        fi
        rm -f -- "$pending_make_path"
        # The GCP metadata deny policy is installed before this container runs.
        # Keep the build on Docker's isolated bridge: `--network host` would
        # bypass FORWARD/DOCKER-USER and expose the VM service-account token to
        # image entrypoints and network-fetched package build scripts.
        # shellcheck disable=SC2016
        if ! retry_until_success "$docker_bin" run --rm \
            -v "${tool_state_dir}:/out" \
            -v "${make_build_program}:/tmp/cloud-compose-build-cos-make.sh:ro" \
            "$ALPINE_BUILD_IMAGE" \
            /bin/sh /tmp/cloud-compose-build-cos-make.sh; then
            rm -f -- "$pending_make_path"
            return 1
        fi
        rm -f -- "$pending_make_path"
        if [[ -L "$make_path" || ! -f "$make_path" || ! -x "$make_path" ]]; then
            echo "COS bootstrap did not produce a regular executable Make artifact" >&2
            return 1
        fi
        make_sha="$(sha256sum -- "$make_path")" || return 1
        make_sha="${make_sha%% *}"
        make_state_tmp="$(mktemp "${make_state_path}.tmp.XXXXXX")" || return 1
        printf '%s %s\n' "$MAKE_VERSION" "$make_sha" >"$make_state_tmp"
        chmod 0644 "$make_state_tmp"
        mv -f -- "$make_state_tmp" "$make_state_path"
    fi
    if ! valid_make_binary "$make_path" "$make_state_path"; then
        echo "COS bootstrap did not produce a valid GNU Make ${MAKE_VERSION} binary" >&2
        return 1
    fi
    ln -sfn "$make_path" "${cloud_compose_home}/bin/make"
}

main() {
    # shellcheck disable=SC1091
    source /home/cloud-compose/profile.sh
    install_cos_dependencies
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
