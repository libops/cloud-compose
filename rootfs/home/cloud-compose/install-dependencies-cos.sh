#!/usr/bin/env bash

set -euo pipefail

# renovate: datasource=docker depName=alpine packageName=alpine versioning=docker
ALPINE_BUILD_IMAGE="alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
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
# three arguments even though the executable entrypoint below uses defaults.
# shellcheck disable=SC2120
install_cos_dependencies() {
    local cloud_compose_home="${1:-/home/cloud-compose}"
    # COS mounts both /home and /var with noexec. Keep the verified Make binary
    # on the executable persistent data disk; only the unprivileged application
    # PATH consumes the published symlink.
    local tool_state_dir="${2:-${COS_TOOL_STATE_DIR:-/mnt/disks/data/cloud-compose-tools}}"
    local docker_bin="${3:-/usr/bin/docker}"
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
    DOCKER_CLI_PLUGIN_DIR="${DOCKER_CONFIG}/cli-plugins" \
        bash "${cloud_compose_home}/install-docker-plugins.sh"
    DOCKER_CLI_PLUGIN_DIR="${cloud_compose_home}/.docker/cli-plugins" \
        bash "${cloud_compose_home}/install-docker-plugins.sh"
    chown -R cloud-compose:cloud-compose \
        "$DOCKER_CONFIG" \
        "${cloud_compose_home}/.docker" \
        "${cloud_compose_home}/bin"

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
        rm -f -- "$pending_make_path"
        # The GCP metadata deny policy is installed before this container runs.
        # Keep the build on Docker's isolated bridge: `--network host` would
        # bypass FORWARD/DOCKER-USER and expose the VM service-account token to
        # image entrypoints and network-fetched package build scripts.
        # shellcheck disable=SC2016
        if ! retry_until_success "$docker_bin" run --rm \
            -v "${tool_state_dir}:/out" \
            "$ALPINE_BUILD_IMAGE" \
            /bin/sh -euxc '
                MAKE_VERSION="4.4.1"
                MAKE_SHA256="dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3"

                # A single Alpine CDN outage must not make a healthy VM
                # replacement fail. These are HTTPS endpoints from the Alpine
                # official mirror list; apk still verifies the signed indexes
                # and packages with the keys baked into the pinned image.
                alpine_mirrors="
                    https://dl-cdn.alpinelinux.org/alpine
                    https://mirror.math.princeton.edu/pub/alpinelinux
                    https://mirror.fel.cvut.cz/alpine
                "
                packages_installed=false
                for alpine_mirror in ${alpine_mirrors}; do
                    printf "%s\n%s\n" \
                        "${alpine_mirror}/v3.22/main" \
                        "${alpine_mirror}/v3.22/community" \
                        >/etc/apk/repositories
                    rm -f /var/cache/apk/*
                    if apk update && apk add build-base curl make tar; then
                        packages_installed=true
                        break
                    fi
                    echo "Alpine package mirror failed: ${alpine_mirror}" >&2
                done
                if [ "${packages_installed}" != true ]; then
                    echo "All configured Alpine package mirrors failed" >&2
                    exit 1
                fi
                curl -fsSL --proto "=https" --proto-redir "=https" --tlsv1.2 \
                    --retry 5 --retry-all-errors --retry-delay 2 --retry-max-time 900 \
                    --connect-timeout 10 --max-time 300 \
                    "https://ftp.gnu.org/gnu/make/make-${MAKE_VERSION}.tar.gz" -o /tmp/make.tar.gz
                echo "${MAKE_SHA256}  /tmp/make.tar.gz" | sha256sum -c -
                tar -xzf /tmp/make.tar.gz -C /tmp
                cd "/tmp/make-${MAKE_VERSION}"
                LDFLAGS="-static" ./configure --disable-nls
                make -j2
                install -m 0755 make /out/.cloud-compose-make.pending
                /out/.cloud-compose-make.pending --version | grep -Fqm 1 "GNU Make ${MAKE_VERSION}"
                mv -f /out/.cloud-compose-make.pending /out/make
            '; then
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
