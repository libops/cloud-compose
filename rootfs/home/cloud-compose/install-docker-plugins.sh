#!/usr/bin/env bash

set -euo pipefail

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

release_checksum() {
    local manifest="$1"
    local asset="$2"

    awk -v asset="$asset" '
        {
            filename = $2
            sub(/^\*/, "", filename)
            if (filename == asset) {
                checksum = $1
                matches++
            }
        }
        END {
            if (matches != 1) {
                exit 1
            }
            print checksum
        }
    ' "$manifest"
}

validate_release_version() {
    local name="$1"
    local version="$2"

    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        echo "invalid ${name} release version: ${version}" >&2
        return 1
    fi
}

install_docker_cli_plugin() (
    local name="$1"
    local release_url="$2"
    local asset="$3"
    local path="$4"
    local tmp_dir manifest download expected actual

    mkdir -p "$(dirname "$path")"
    if [[ -d "$path" ]]; then
        echo "Refusing Docker CLI plugin directory at file path: ${path}" >&2
        return 1
    fi
    tmp_dir="$(mktemp -d "$(dirname "$path")/.${name}.XXXXXXXXXX")"
    trap 'rm -rf -- "$tmp_dir"' EXIT
    manifest="${tmp_dir}/checksums.txt"
    download="${tmp_dir}/${asset}"

    retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 -o "$manifest" -- "${release_url}/checksums.txt"
    if ! expected="$(release_checksum "$manifest" "$asset")" ||
        [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "No unique SHA-256 checksum for ${asset} in the ${name} release manifest" >&2
        return 1
    fi

    if [[ -f "$path" && ! -L "$path" && -x "$path" ]]; then
        actual="$(sha256sum "$path")"
        actual="${actual%% *}"
        if [[ "$actual" == "$expected" ]]; then
            echo "Docker CLI plugin ${name} is already verified"
            return 0
        fi
    fi

    echo "Installing verified Docker CLI plugin ${name}"
    retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 -o "$download" -- "${release_url}/${asset}"
    printf '%s  %s\n' "$expected" "$download" | sha256sum -c -
    chmod 0755 "$download"
    mv -f -- "$download" "$path"
)

install_docker_plugins() {
    local plugin_dir="${DOCKER_CLI_PLUGIN_DIR:-/usr/local/lib/docker/cli-plugins}"
    local compose_arch buildx_asset_arch

    # renovate: datasource=github-releases depName=docker-compose packageName=docker/compose versioning=semver
    DOCKER_COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v5.3.1}"
    # renovate: datasource=github-releases depName=docker-buildx packageName=docker/buildx versioning=semver
    DOCKER_BUILDX_VERSION="${DOCKER_BUILDX_VERSION:-v0.35.0}"

    validate_release_version docker-compose "$DOCKER_COMPOSE_VERSION"
    validate_release_version docker-buildx "$DOCKER_BUILDX_VERSION"
    compose_arch="$(docker_arch)"
    buildx_asset_arch="$(buildx_arch)"
    install_docker_cli_plugin \
        docker-compose \
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}" \
        "docker-compose-linux-${compose_arch}" \
        "${plugin_dir}/docker-compose"
    install_docker_cli_plugin \
        docker-buildx \
        "https://github.com/docker/buildx/releases/download/${DOCKER_BUILDX_VERSION}" \
        "buildx-${DOCKER_BUILDX_VERSION}.linux-${buildx_asset_arch}" \
        "${plugin_dir}/docker-buildx"
}

main() {
    # shellcheck disable=SC1091
    source /home/cloud-compose/profile.sh
    install_docker_plugins "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
