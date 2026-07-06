#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

docker_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "x86_64" ;;
        aarch64 | arm64) echo "aarch64" ;;
        *)
            echo "unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

buildx_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "arm64" ;;
        *)
            echo "unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

install_docker_cli_plugin() {
    local name="$1"
    local url="$2"
    local path="$3"

    if [ -x "$path" ]; then
        return 0
    fi

    echo "Installing Docker CLI plugin ${name}"
    mkdir -p "$(dirname "$path")"
    retry_until_success curl -fsSL "$url" -o "$path"
    chmod a+x "$path"
}

install_docker_plugins() {
    local plugin_dir="${DOCKER_CLI_PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}"
    local compose_arch buildx_asset_arch

    # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
    DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v5.3.0}"
    # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
    DOCKER_BUILDX_VERSION="${DOCKER_BUILDX_VERSION:-v0.35.0}"

    compose_arch="$(docker_arch)"
    buildx_asset_arch="$(buildx_arch)"
    install_docker_cli_plugin \
        docker-compose \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-${compose_arch}" \
        "${plugin_dir}/docker-compose"
    install_docker_cli_plugin \
        docker-buildx \
        "https://github.com/docker/buildx/releases/download/${DOCKER_BUILDX_VERSION}/buildx-${DOCKER_BUILDX_VERSION}.linux-${buildx_asset_arch}" \
        "${plugin_dir}/docker-buildx"
}

install_docker_plugins "$@"
