#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

LOG_PREFIX="[libops-managed-runtime]"
STATE_DIR="/mnt/disks/data/libops-managed"
BIN_DIR="${STATE_DIR}/bin"
TMP_DIR="${STATE_DIR}/tmp"
PACKAGE_STATE_DIR="${STATE_DIR}/packages"
ARTIFACT_STATE_DIR="${STATE_DIR}/artifacts"
ARTIFACT_MANIFEST="/home/cloud-compose/managed-runtime-artifacts.tsv"
GITHUB_OWNER="${SITECTL_GITHUB_OWNER:-libops}"

log() {
    echo "${LOG_PREFIX} $*" >&2
}

enabled() {
    case "${LIBOPS_MANAGED_RUNTIME_ENABLED:-true}" in
        true | TRUE | 1 | yes | YES) return 0 ;;
        *) return 1 ;;
    esac
}

mkdirs() {
    mkdir -p "$BIN_DIR" "$TMP_DIR" "$PACKAGE_STATE_DIR" "$ARTIFACT_STATE_DIR" /home/cloud-compose/bin
}

with_lock() {
    local action="$1"
    shift

    mkdirs
    if command -v flock >/dev/null 2>&1; then
        exec 9>"${STATE_DIR}/runtime.lock"
        if ! flock -n 9; then
            log "managed runtime update already running"
            return 0
        fi
    fi

    "$action" "$@"
}

machine_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "x86_64" ;;
        aarch64 | arm64) echo "arm64" ;;
        *)
            log "unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac
}

release_base_url() {
    local package="$1"
    local version="$2"

    if [ "$version" = "latest" ]; then
        echo "https://github.com/${GITHUB_OWNER}/${package}/releases/latest/download"
    else
        echo "https://github.com/${GITHUB_OWNER}/${package}/releases/download/${version}"
    fi
}

latest_release_tag() {
    local package="$1"
    local metadata
    metadata="$(mktemp "${TMP_DIR}/${package}.latest.XXXXXX.json")"

    if ! retry_until_success curl -fsSL -o "$metadata" "https://api.github.com/repos/${GITHUB_OWNER}/${package}/releases/latest"; then
        rm -f "$metadata"
        return 1
    fi

    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata" | head -n 1
    rm -f "$metadata"
}

installed_release_tag() {
    local package="$1"
    local state_file="${PACKAGE_STATE_DIR}/${package}.version"

    if [ -f "$state_file" ]; then
        cat "$state_file"
    fi
}

write_installed_release_tag() {
    local package="$1"
    local version="$2"

    printf '%s\n' "$version" > "${PACKAGE_STATE_DIR}/${package}.version"
}

install_release_package() {
    local package="$1"
    local version="${SITECTL_VERSION:-latest}"
    local arch archive base_url tag installed tmp checksum_file binary

    if [ -z "$package" ]; then
        return 0
    fi
    case "$package" in
        sitectl | sitectl-*) ;;
        *)
            log "skipping invalid sitectl package name: ${package}"
            return 1
            ;;
    esac

    arch="$(machine_arch)"
    archive="${package}_Linux_${arch}.tar.gz"
    base_url="$(release_base_url "$package" "$version")"
    tag="$version"
    if [ "$version" = "latest" ]; then
        tag="$(latest_release_tag "$package" || true)"
    fi
    installed="$(installed_release_tag "$package" || true)"

    if [ -n "$tag" ] && [ "$installed" = "$tag" ] && [ -x "${BIN_DIR}/${package}" ]; then
        ln -sf "${BIN_DIR}/${package}" "/home/cloud-compose/bin/${package}"
        log "${package} is already ${tag}"
        return 0
    fi

    tmp="$(mktemp -d "${TMP_DIR}/${package}.XXXXXX")"

    log "installing ${package} from ${base_url}/${archive}"
    retry_until_success curl -fsSL -o "${tmp}/${archive}" "${base_url}/${archive}"
    retry_until_success curl -fsSL -o "${tmp}/checksums.txt" "${base_url}/checksums.txt"

    checksum_file="${tmp}/checksums.selected.txt"
    grep -E "[[:space:]]${archive}$" "${tmp}/checksums.txt" > "$checksum_file"
    (cd "$tmp" && sha256sum -c "$(basename "$checksum_file")")

    tar -xzf "${tmp}/${archive}" -C "$tmp"
    binary="$(find "$tmp" -type f -name "$package" | head -n 1)"
    if [ -z "$binary" ]; then
        log "release archive did not contain ${package}"
        return 1
    fi

    install -m 0755 "$binary" "${BIN_DIR}/${package}"
    ln -sf "${BIN_DIR}/${package}" "/home/cloud-compose/bin/${package}"
    if [ -n "$tag" ]; then
        write_installed_release_tag "$package" "$tag"
        log "installed ${package} ${tag}"
    else
        log "installed ${package}"
    fi
    rm -rf "$tmp"
}

sitectl_package_list() {
    local packages="${SITECTL_PACKAGES:-sitectl}"
    local seen=" "
    local package

    for package in sitectl $packages; do
        if [ -z "$package" ]; then
            continue
        fi
        if [[ "$seen" == *" $package "* ]]; then
            continue
        fi
        seen="${seen}${package} "
        echo "$package"
    done
}

install_sitectl_packages() {
    local package

    while read -r package; do
        install_release_package "$package"
    done < <(sitectl_package_list)
}

install_managed_artifacts() {
    local name url sha path mode owner group restart
    local state_file tmp

    if [ ! -f "$ARTIFACT_MANIFEST" ]; then
        return 0
    fi

    while IFS=$'\t' read -r name url sha path mode owner group restart || [ -n "${name:-}" ]; do
        if [ -z "${name:-}" ] || [[ "$name" == \#* ]]; then
            continue
        fi
        mode="${mode:-0755}"
        owner="${owner:-root}"
        group="${group:-root}"
        restart="${restart:-}"
        state_file="${ARTIFACT_STATE_DIR}/${name}.sha256"

        if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$sha" ] && [ -e "$path" ]; then
            log "${name} artifact is already installed"
            continue
        fi

        tmp="$(mktemp "${TMP_DIR}/${name}.XXXXXX")"
        log "installing managed artifact ${name}"
        retry_until_success curl -fsSL -o "$tmp" "$url"
        echo "${sha}  ${tmp}" | sha256sum -c -
        install -o "$owner" -g "$group" -m "$mode" "$tmp" "$path"
        rm -f "$tmp"
        printf '%s\n' "$sha" > "$state_file"

        if [ -n "$restart" ]; then
            systemctl try-restart "$restart" || true
        fi
    done < "$ARTIFACT_MANIFEST"
}

update_internal_services() {
    case "${LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE:-true}" in
        true | TRUE | 1 | yes | YES) ;;
        *) return 0 ;;
    esac

    if [ ! -f /mnt/disks/data/libops-internal/docker-compose.yaml ]; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log "docker is not available; skipping internal service update"
        return 0
    fi

    pushd /mnt/disks/data/libops-internal >/dev/null
    log "updating internal LibOps services"
    retry_until_success docker compose pull
    if systemctl is-active --quiet internal-services.service; then
        systemctl restart internal-services.service
    else
        docker compose up -d --remove-orphans
    fi
    popd >/dev/null
}

run_install_tools() {
    if ! enabled; then
        log "managed runtime disabled"
        return 0
    fi
    install_sitectl_packages
    install_managed_artifacts
}

run_update() {
    if ! enabled; then
        log "managed runtime disabled"
        return 0
    fi
    install_sitectl_packages
    install_managed_artifacts
    update_internal_services
}

main() {
    local command="${1:-update}"

    case "$command" in
        install-tools)
            with_lock run_install_tools
            ;;
        update)
            with_lock run_update
            ;;
        *)
            log "unknown command: ${command}"
            return 2
            ;;
    esac
}

main "$@"
