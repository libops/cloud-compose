#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1090
source "${CLOUD_COMPOSE_PROFILE_PATH:-/home/cloud-compose/profile.sh}"

LOG_PREFIX="[libops-managed-runtime]"
STATE_DIR="/mnt/disks/data/libops-managed"
BIN_DIR="${STATE_DIR}/bin"
TMP_DIR="${STATE_DIR}/tmp"
PACKAGE_STATE_DIR="${STATE_DIR}/packages"
ARTIFACT_STATE_DIR="${STATE_DIR}/artifacts"
ARTIFACT_MANIFEST="/home/cloud-compose/managed-runtime-artifacts.tsv"
GITHUB_OWNER="${SITECTL_GITHUB_OWNER:-libops}"
PUBLISHED_BIN_DIR="/home/cloud-compose/bin"

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
    local expected_uid expected_gid path mode allow_owner_migration spec
    local -a directory_specs

    expected_uid="$EUID"
    expected_gid="$(id -g)"
    if [[ "$STATE_DIR" == "/mnt/disks/data/libops-managed" ||
        "$PUBLISHED_BIN_DIR" == "/home/cloud-compose/bin" ]]; then
        if ((EUID != 0)); then
            log "production managed runtime directories require a root updater"
            return 1
        fi
        expected_uid=0
        expected_gid=0
    fi

    # The managed binary is published through /home/cloud-compose/bin and must
    # remain traversable after a root-owned bootstrap drops to cloud-compose.
    # Refuse redirected, non-directory, non-owner-controlled, or writable
    # state before creating package staging files beneath the shared data mount.
    directory_specs=(
        "$STATE_DIR:0755:false"
        "$BIN_DIR:0755:false"
        "$TMP_DIR:0700:false"
        "$PACKAGE_STATE_DIR:0700:false"
        "$ARTIFACT_STATE_DIR:0700:false"
        "$PUBLISHED_BIN_DIR:0755:true"
    )
    for spec in "${directory_specs[@]}"; do
        IFS=: read -r path mode allow_owner_migration <<<"$spec"
        prepare_managed_runtime_directory \
            "$path" "$mode" "$expected_uid" "$expected_gid" "$allow_owner_migration" || return 1
    done
}

prepare_managed_runtime_directory() {
    local path="$1" mode="$2" expected_uid="$3" expected_gid="$4"
    local allow_owner_migration="$5" metadata owner_uid group_gid actual_mode kind resolved desired_mode
    local created=false

    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        log "managed runtime path is not a real directory: ${path}"
        return 1
    fi
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        # mkdir is the creation boundary: if an unprivileged process wins the
        # name between inspection and creation, fail rather than adopting its
        # pre-populated directory with install -d.
        if ! mkdir -m "$mode" -- "$path"; then
            log "managed runtime directory appeared during creation: ${path}"
            return 1
        fi
        created=true
    fi
    if [[ "$created" != "true" ]]; then
        if [[ -L "$path" || ! -d "$path" ]]; then
            log "managed runtime path changed during validation: ${path}"
            return 1
        fi
        metadata="$(stat -c '%u:%g:%a:%F' -- "$path")" || return 1
        IFS=: read -r owner_uid group_gid actual_mode kind <<<"$metadata"
        if [[ "$kind" != "directory" || ! "$actual_mode" =~ ^[0-7]{3,4}$ ||
            $((8#$actual_mode & 0022)) -ne 0 ]]; then
            log "managed runtime directory is writable by another account: ${path}"
            return 1
        fi
        if [[ ( "$allow_owner_migration" != "true" || EUID -ne 0 ) &&
            ( "$owner_uid" != "$expected_uid" || "$group_gid" != "$expected_gid" ) ]]; then
            log "managed runtime directory is not owned by the updater: ${path}"
            return 1
        fi
        if [[ "$allow_owner_migration" == "true" ]]; then
            # Close the legacy application-owned PATH directory before walking
            # its entries. The bootstrap libexec boundary has already made its
            # parent root-owned, so an old owner cannot race validation.
            if ((EUID == 0)); then
                install -d -m "$mode" -o "$expected_uid" -g "$expected_gid" -- "$path" || return 1
            else
                chmod "$mode" -- "$path" || return 1
            fi
            validate_published_bin_directory "$path" || return 1
        fi
    fi

    if ((EUID == 0)); then
        install -d -m "$mode" -o "$expected_uid" -g "$expected_gid" -- "$path" || return 1
    else
        chmod "$mode" -- "$path" || return 1
    fi
    resolved="$(readlink -f -- "$path")" || return 1
    desired_mode="$(printf '%o' "$((8#$mode))")"
    metadata="$(stat -c '%u:%g:%a:%F' -- "$path")" || return 1
    if [[ "$resolved" != "$path" || "$metadata" != "${expected_uid}:${expected_gid}:${desired_mode}:directory" ||
        -L "$path" ]]; then
        log "managed runtime directory did not converge safely: ${path}"
        return 1
    fi
}

validate_published_bin_directory() {
    local path="$1" entry name target
    local -a entries

    # /home/cloud-compose/bin was application-owned on older hosts. Preserve
    # only the generated sitectl links whose targets remain under the validated
    # root-owned package directory; reject every other inherited PATH entry.
    shopt -s nullglob dotglob
    entries=("$path"/*)
    shopt -u nullglob dotglob
    for entry in "${entries[@]}"; do
        name="${entry##*/}"
        if [[ ! "$name" =~ ^sitectl(-[a-z0-9]+)*$ || ! -L "$entry" ]]; then
            log "published command directory contains an unmanaged entry: ${entry}"
            return 1
        fi
        target="$(readlink -- "$entry")" || return 1
        if [[ "$target" != "${BIN_DIR}/${name}" ]]; then
            log "published command has an unsafe target: ${entry}"
            return 1
        fi
    done
}

with_lock() {
    local action="$1"
    shift

    mkdirs || return 1
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
    local metadata tag
    metadata="$(mktemp "${TMP_DIR}/${package}.latest.XXXXXX.json")"

    if ! retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 -o "$metadata" -- \
        "https://api.github.com/repos/${GITHUB_OWNER}/${package}/releases/latest"; then
        rm -f "$metadata"
        return 1
    fi

    if ! tag="$(jq -jr '
        (.tag_name | select(type == "string" and length > 0 and (explode | index(0) == null))),
        "\u001f"
    ' "$metadata")"; then
        log "latest release metadata for ${package} did not contain a tag"
        rm -f "$metadata"
        return 1
    fi
    tag="${tag%$'\x1f'}"
    rm -f "$metadata"
    if [[ "$tag" == "latest" ]] || ! valid_sitectl_version "$tag"; then
        log "latest release metadata for ${package} contained an invalid tag"
        return 1
    fi
    printf '%s\n' "$tag"
}

installed_release_tag() {
    local package="$1"
    local state_file="${PACKAGE_STATE_DIR}/${package}.version"

    if [ -f "$state_file" ]; then
        cat "$state_file"
    fi
}

installed_release_sha256() {
    local package="$1"
    local state_file="${PACKAGE_STATE_DIR}/${package}.sha256"

    if [ -f "$state_file" ]; then
        cat "$state_file"
    fi
}

write_installed_release_state() {
    local package="$1"
    local version="$2"
    local binary="$3"
    local version_file="${PACKAGE_STATE_DIR}/${package}.version"
    local sha_file="${PACKAGE_STATE_DIR}/${package}.sha256"
    local version_tmp sha_tmp binary_sha

    binary_sha="$(sha256sum -- "$binary")" || return 1
    binary_sha="${binary_sha%% *}"
    version_tmp="$(mktemp "${version_file}.tmp.XXXXXX")" || return 1
    sha_tmp="$(mktemp "${sha_file}.tmp.XXXXXX")" || {
        rm -f -- "$version_tmp"
        return 1
    }
    printf '%s\n' "$version" >"$version_tmp"
    printf '%s\n' "$binary_sha" >"$sha_tmp"
    chmod 0640 "$version_tmp" "$sha_tmp"
    mv -f -- "$version_tmp" "$version_file"
    mv -f -- "$sha_tmp" "$sha_file"
}

install_release_package() {
    local package="$1"
    local target_bin_dir="${2:-$BIN_DIR}"
    local publish="${3:-true}"
    local version
    local arch archive base_url tag installed installed_sha actual_sha tmp checksum_file archive_listing binary target_tmp

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

    version="$(sitectl_package_version "$package")"

    arch="$(machine_arch)"
    archive="${package}_Linux_${arch}.tar.gz"
    tag="$version"
    if [ "$version" = "latest" ]; then
        tag="$(latest_release_tag "$package")"
        if [ "$tag" = "latest" ] || ! valid_sitectl_version "$tag"; then
            log "latest release for ${package} returned an invalid tag: ${tag}"
            return 1
        fi
    fi
    base_url="$(release_base_url "$package" "$tag")"
    installed="$(installed_release_tag "$package" || true)"
    installed_sha="$(installed_release_sha256 "$package" || true)"

    mkdir -p -- "$target_bin_dir"
    if [ -n "$tag" ] && [ "$installed" = "$tag" ] &&
        [[ "$installed_sha" =~ ^[0-9a-f]{64}$ ]] &&
        [[ ! -L "${BIN_DIR}/${package}" && -f "${BIN_DIR}/${package}" && -x "${BIN_DIR}/${package}" ]]; then
        actual_sha="$(sha256sum -- "${BIN_DIR}/${package}")" || return 1
        actual_sha="${actual_sha%% *}"
        if [[ "$actual_sha" == "$installed_sha" ]]; then
            if [[ "$target_bin_dir" != "$BIN_DIR" ]]; then
                target_tmp="$(mktemp "${target_bin_dir}/.${package}.XXXXXX")" || return 1
                install -m 0755 "${BIN_DIR}/${package}" "$target_tmp" || {
                    rm -f -- "$target_tmp"
                    return 1
                }
                mv -f -- "$target_tmp" "${target_bin_dir}/${package}"
            elif [[ "$publish" == "true" ]]; then
                ln -sfn "${BIN_DIR}/${package}" "${PUBLISHED_BIN_DIR}/${package}"
            fi
            RELEASE_PACKAGE_TAG="$tag"
            RELEASE_PACKAGE_SHA256="$installed_sha"
            log "${package} is already ${tag}"
            return 0
        fi
    fi

    tmp="$(mktemp -d "${TMP_DIR}/${package}.XXXXXX")"

    log "installing ${package} from ${base_url}/${archive}"
    retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 -o "${tmp}/${archive}" -- "${base_url}/${archive}"
    retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 300 -o "${tmp}/checksums.txt" -- "${base_url}/checksums.txt"

    checksum_file="${tmp}/checksums.selected.txt"
    awk -v archive="$archive" '$2 == archive { print }' "${tmp}/checksums.txt" >"$checksum_file"
    if [[ "$(wc -l <"$checksum_file")" -ne 1 ]]; then
        log "release checksums must contain exactly one entry for ${archive}"
        rm -rf -- "$tmp"
        return 1
    fi
    (cd "$tmp" && sha256sum -c "$(basename "$checksum_file")")

    # Extract only the exact top-level binary. Release archives also contain
    # documentation, but no other member needs filesystem access on the host.
    archive_listing="${tmp}/archive.list"
    tar -tzf "${tmp}/${archive}" >"$archive_listing"
    if [[ "$(grep -Fxc -- "$package" "$archive_listing")" -ne 1 ]]; then
        log "release archive must contain exactly one top-level ${package} binary"
        rm -rf -- "$tmp"
        return 1
    fi
    tar -xzf "${tmp}/${archive}" -C "$tmp" -- "$package"
    binary="${tmp}/${package}"
    if [[ -L "$binary" || ! -f "$binary" ]]; then
        log "release archive member ${package} is not a regular file"
        rm -rf -- "$tmp"
        return 1
    fi

    target_tmp="$(mktemp "${target_bin_dir}/.${package}.XXXXXX")" || return 1
    install -m 0755 "$binary" "$target_tmp" || {
        rm -f -- "$target_tmp"
        rm -rf -- "$tmp"
        return 1
    }
    actual_sha="$(sha256sum -- "$target_tmp")" || {
        rm -f -- "$target_tmp"
        return 1
    }
    actual_sha="${actual_sha%% *}"
    mv -f -- "$target_tmp" "${target_bin_dir}/${package}"
    RELEASE_PACKAGE_TAG="$tag"
    RELEASE_PACKAGE_SHA256="$actual_sha"
    if [[ "$publish" == "true" ]]; then
        ln -sfn "${BIN_DIR}/${package}" "${PUBLISHED_BIN_DIR}/${package}"
        write_installed_release_state "$package" "$tag" "${target_bin_dir}/${package}"
        log "installed ${package} ${tag}"
    fi
    rm -rf -- "$tmp"
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

valid_sitectl_version() {
    local version="$1"

    [[ "$version" == "latest" || "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]
}

sitectl_package_versions_json() {
    if [ -n "${SITECTL_PACKAGE_VERSIONS:-}" ]; then
        printf '%s\n' "$SITECTL_PACKAGE_VERSIONS"
    else
        printf '%s\n' '{}'
    fi
}

sitectl_package_version() {
    local package="$1"
    local fallback="${SITECTL_VERSION:-latest}"

    jq -er --arg package "$package" --arg fallback "$fallback" \
        '.[$package] // $fallback' \
        <<<"$(sitectl_package_versions_json)"
}

validate_sitectl_configuration() {
    local fallback="${SITECTL_VERSION:-latest}"
    local versions_json package encoded_override override override_version
    local -A installed_packages=()

    if ! valid_sitectl_version "$fallback"; then
        log "invalid SITECTL_VERSION: ${fallback}"
        return 1
    fi

    versions_json="$(sitectl_package_versions_json)"
    if ! jq -e '
        type == "object" and
        all(to_entries[];
            (.key | explode | index(0) == null) and
            (.value | type == "string") and
            (.value | explode | index(0) == null)
        )
    ' <<<"$versions_json" >/dev/null; then
        log "SITECTL_PACKAGE_VERSIONS must be a JSON object of sitectl package names to latest or exact semantic-version release tags"
        return 1
    fi

    while read -r package; do
        if [[ ! "$package" =~ ^sitectl(-[a-z0-9]+)*$ ]]; then
            log "invalid package in SITECTL_PACKAGES: ${package}"
            return 1
        fi
        installed_packages["$package"]=true
    done < <(sitectl_package_list)

    while IFS= read -r encoded_override; do
        override="$(
            if ! printf '%s' "$encoded_override" | base64 --decode; then
                exit 1
            fi
            printf '\037'
        )" || return 1
        override="${override%$'\x1f'}"
        if [[ ! "$override" =~ ^sitectl(-[a-z0-9]+)*$ ]]; then
            log "SITECTL_PACKAGE_VERSIONS contains an invalid package name: ${override}"
            return 1
        fi
        override_version="$(jq -jr --arg package "$override" '(.[$package]), "\u001f"' <<<"$versions_json")" || return 1
        override_version="${override_version%$'\x1f'}"
        if ! valid_sitectl_version "$override_version"; then
            log "SITECTL_PACKAGE_VERSIONS contains an invalid release tag for ${override}: ${override_version}"
            return 1
        fi
        if [[ -z "${installed_packages[$override]:-}" ]]; then
            log "SITECTL_PACKAGE_VERSIONS contains an uninstalled package: ${override}"
            return 1
        fi
    done < <(jq -r 'keys[] | @base64' <<<"$versions_json")
}

validate_stale_managed_sitectl_package() {
    local package="$1"
    local version_file="${PACKAGE_STATE_DIR}/${package}.version"
    local sha_file="${PACKAGE_STATE_DIR}/${package}.sha256"
    local binary="${BIN_DIR}/${package}"
    local published="${PUBLISHED_BIN_DIR}/${package}"
    local version expected_sha actual_sha published_target

    if [[ "$package" == "sitectl" || ! "$package" =~ ^sitectl(-[a-z0-9]+)+$ ]]; then
        log "refusing to prune invalid managed package name: ${package}"
        return 1
    fi
    if [[ -L "$version_file" || ! -f "$version_file" ||
        -L "$sha_file" || ! -f "$sha_file" ||
        -L "$binary" || ! -f "$binary" || ! -x "$binary" ]]; then
        log "refusing to prune ${package}: binary and regular version/checksum state are required"
        return 1
    fi

    version="$(<"$version_file")"
    expected_sha="$(<"$sha_file")"
    if [[ "$version" == "latest" ]] || ! valid_sitectl_version "$version" ||
        [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        log "refusing to prune ${package}: installed release state is invalid"
        return 1
    fi
    actual_sha="$(sha256sum -- "$binary")" || return 1
    actual_sha="${actual_sha%% *}"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        log "refusing to prune ${package}: binary does not match managed checksum state"
        return 1
    fi

    if [[ -e "$published" || -L "$published" ]]; then
        if [[ ! -L "$published" ]]; then
            log "refusing to prune ${package}: published command is not a managed symlink"
            return 1
        fi
        published_target="$(readlink -- "$published")" || return 1
        if [[ "$published_target" != "$binary" ]]; then
            log "refusing to prune ${package}: published command targets ${published_target}"
            return 1
        fi
    fi
}

install_sitectl_packages() {
    local package path name stage_dir payload_dir tags_dir backup_dir
    local promotion_failed=false
    local -a packages=() candidate_paths=() stale_packages=() transaction_packages=()
    local -A desired_packages=() stale_seen=()

    validate_sitectl_configuration
    mkdirs || return 1

    mapfile -t packages < <(sitectl_package_list)
    for package in "${packages[@]}"; do
        desired_packages["$package"]=true
    done
    stage_dir="$(mktemp -d "${TMP_DIR}/sitectl-generation.XXXXXX")" || return 1
    payload_dir="${stage_dir}/payload"
    tags_dir="${stage_dir}/tags"
    backup_dir="${stage_dir}/backup"
    mkdir -p "$payload_dir" "$tags_dir" "$backup_dir/bin" "$backup_dir/state"

    # Download or copy every verified package before replacing any live binary.
    # A later plugin failure therefore leaves the complete previous set active.
    for package in "${packages[@]}"; do
        if ! install_release_package "$package" "$payload_dir" false; then
            rm -rf -- "$stage_dir"
            return 1
        fi
        printf '%s\n' "$RELEASE_PACKAGE_TAG" >"${tags_dir}/${package}.version"
        printf '%s\n' "$RELEASE_PACKAGE_SHA256" >"${tags_dir}/${package}.sha256"
    done

    # Downloads and checksum verification do not mutate the live set. Take the
    # application lock only for the backup/promotion window so a slow release
    # download cannot block an unrelated restart, rollout, or database backup.
    if declare -F acquire_cloud_compose_lifecycle_lock >/dev/null 2>&1; then
        if ! acquire_cloud_compose_lifecycle_lock managed-runtime-package-update; then
            rm -rf -- "$stage_dir"
            return 1
        fi
    fi

    # Converge the complete managed plugin set, not just packages that are
    # still desired. Search each managed location so an incomplete old
    # generation fails closed instead of leaving a stale command discoverable.
    shopt -s nullglob
    candidate_paths=(
        "${PACKAGE_STATE_DIR}"/sitectl-*.version
        "${PACKAGE_STATE_DIR}"/sitectl-*.sha256
        "${BIN_DIR}"/sitectl-*
        "${PUBLISHED_BIN_DIR}"/sitectl-*
    )
    shopt -u nullglob
    for path in "${candidate_paths[@]}"; do
        name="$(basename -- "$path")"
        package="${name%.version}"
        package="${package%.sha256}"
        if [[ -n "${desired_packages[$package]:-}" || -n "${stale_seen[$package]:-}" ]]; then
            continue
        fi
        stale_seen["$package"]=true
        if ! validate_stale_managed_sitectl_package "$package"; then
            rm -rf -- "$stage_dir"
            if declare -F release_cloud_compose_lifecycle_lock >/dev/null 2>&1; then
                release_cloud_compose_lifecycle_lock
            fi
            return 1
        fi
        stale_packages+=("$package")
    done
    transaction_packages=("${packages[@]}" "${stale_packages[@]}")

    # Preserve the exact previous package/state set for rollback before the
    # short promotion phase. Missing markers distinguish absent old files from
    # zero-length/corrupt state that must also be restored exactly.
    mkdir -p "$backup_dir/published"
    for package in "${transaction_packages[@]}"; do
        if [[ -e "${BIN_DIR}/${package}" || -L "${BIN_DIR}/${package}" ]]; then
            cp -a -- "${BIN_DIR}/${package}" "${backup_dir}/bin/${package}" || promotion_failed=true
        else
            : >"${backup_dir}/bin/${package}.missing"
        fi
        for suffix in version sha256; do
            if [[ -e "${PACKAGE_STATE_DIR}/${package}.${suffix}" || -L "${PACKAGE_STATE_DIR}/${package}.${suffix}" ]]; then
                cp -a -- "${PACKAGE_STATE_DIR}/${package}.${suffix}" \
                    "${backup_dir}/state/${package}.${suffix}" || promotion_failed=true
            else
                : >"${backup_dir}/state/${package}.${suffix}.missing"
            fi
        done
        if [[ -e "${PUBLISHED_BIN_DIR}/${package}" || -L "${PUBLISHED_BIN_DIR}/${package}" ]]; then
            cp -a -- "${PUBLISHED_BIN_DIR}/${package}" \
                "${backup_dir}/published/${package}" || promotion_failed=true
        else
            : >"${backup_dir}/published/${package}.missing"
        fi
    done

    if [[ "$promotion_failed" == "true" ]]; then
        log "could not preserve the current sitectl generation; package set was not changed"
        rm -rf -- "$stage_dir"
        if declare -F release_cloud_compose_lifecycle_lock >/dev/null 2>&1; then
            release_cloud_compose_lifecycle_lock
        fi
        return 1
    fi

    # Removing dropped plugins and promoting desired binaries are one locked
    # transaction. Rollback below restores both updated and removed packages.
    for package in "${stale_packages[@]}"; do
        if ! rm -f -- \
            "${BIN_DIR}/${package}" \
            "${PUBLISHED_BIN_DIR}/${package}" \
            "${PACKAGE_STATE_DIR}/${package}.version" \
            "${PACKAGE_STATE_DIR}/${package}.sha256"; then
            promotion_failed=true
            break
        fi
        log "removed stale managed package ${package}"
    done
    if [[ "$promotion_failed" != "true" ]]; then
        for package in "${packages[@]}"; do
            mv -f -- "${payload_dir}/${package}" "${BIN_DIR}/${package}" || {
                promotion_failed=true
                break
            }
            if ! write_installed_release_state "$package" "$(<"${tags_dir}/${package}.version")" "${BIN_DIR}/${package}" ||
                ! ln -sfn "${BIN_DIR}/${package}" "${PUBLISHED_BIN_DIR}/${package}"; then
                promotion_failed=true
                break
            fi
        done
    fi

    if [[ "$promotion_failed" == "true" ]]; then
        log "package-set promotion failed; restoring the previous sitectl generation"
        for package in "${transaction_packages[@]}"; do
            if [[ -e "${backup_dir}/bin/${package}.missing" ]]; then
                rm -f -- "${BIN_DIR}/${package}"
            elif [[ -e "${backup_dir}/bin/${package}" || -L "${backup_dir}/bin/${package}" ]]; then
                rm -f -- "${BIN_DIR}/${package}"
                cp -a -- "${backup_dir}/bin/${package}" "${BIN_DIR}/${package}" || true
            fi
            for suffix in version sha256; do
                if [[ -e "${backup_dir}/state/${package}.${suffix}.missing" ]]; then
                    rm -f -- "${PACKAGE_STATE_DIR}/${package}.${suffix}"
                elif [[ -e "${backup_dir}/state/${package}.${suffix}" || -L "${backup_dir}/state/${package}.${suffix}" ]]; then
                    rm -f -- "${PACKAGE_STATE_DIR}/${package}.${suffix}"
                    cp -a -- "${backup_dir}/state/${package}.${suffix}" \
                        "${PACKAGE_STATE_DIR}/${package}.${suffix}" || true
                fi
            done
            rm -f -- "${PUBLISHED_BIN_DIR}/${package}"
            if [[ -e "${backup_dir}/published/${package}" || -L "${backup_dir}/published/${package}" ]]; then
                cp -a -- "${backup_dir}/published/${package}" \
                    "${PUBLISHED_BIN_DIR}/${package}" || true
            fi
        done
        rm -rf -- "$stage_dir"
        if declare -F release_cloud_compose_lifecycle_lock >/dev/null 2>&1; then
            release_cloud_compose_lifecycle_lock
        fi
        return 1
    fi

    rm -rf -- "$stage_dir"
    if declare -F release_cloud_compose_lifecycle_lock >/dev/null 2>&1; then
        release_cloud_compose_lifecycle_lock
    fi
}

validate_managed_artifact() {
    local name="$1" url="$2" sha="$3" path="$4"
    local mode="$5" owner="$6" group="$7" restart="$8"

    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        log "invalid managed artifact name: ${name}"
        return 1
    fi
    if [[ ! "$url" =~ ^https://[^[:space:]]+$ ]]; then
        log "managed artifact ${name} must use an HTTPS URL without whitespace"
        return 1
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        log "managed artifact ${name} has an invalid SHA-256 digest"
        return 1
    fi
    if [[ "$path" != /* || "$path" == "/" || "$path" == */ || "$path" == *//* ||
        "$path" =~ [[:cntrl:]] || "$path" =~ (^|/)\.\.?(/|$) ]]; then
        log "managed artifact ${name} has an unsafe target path"
        return 1
    fi
    if [[ ! "$mode" =~ ^0?[0-7]{3}$ ]]; then
        log "managed artifact ${name} has an invalid file mode"
        return 1
    fi
    if [[ ! "$owner" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]] ||
        [[ ! "$group" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]]; then
        log "managed artifact ${name} has an invalid owner or group"
        return 1
    fi
    if [[ -n "$restart" && ! "$restart" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.service$ ]]; then
        log "managed artifact ${name} has an invalid restart unit"
        return 1
    fi
}

managed_artifact_matches() {
    local path="$1" expected_sha="$2" actual_sha

    [[ ! -L "$path" && -f "$path" ]] || return 1
    actual_sha="$(sha256sum -- "$path")" || return 1
    [[ "${actual_sha%% *}" == "$expected_sha" ]]
}

managed_artifact_metadata_matches() {
    local path="$1" mode="$2" owner="$3" group="$4"
    local actual_mode actual_owner actual_group desired_mode

    [[ ! -L "$path" && -f "$path" ]] || return 1
    desired_mode="$(printf '%o' "$((8#$mode))")"
    actual_mode="$(stat -c %a -- "$path")" || return 1
    actual_owner="$(stat -c %U -- "$path")" || return 1
    actual_group="$(stat -c %G -- "$path")" || return 1
    [[ "$actual_mode" == "$desired_mode" && "$actual_owner" == "$owner" && "$actual_group" == "$group" ]]
}

preflight_managed_artifact_target() {
    local name="$1" path="$2" owner="$3" group="$4" target_dir

    target_dir="$(dirname -- "$path")"
    if ! managed_artifact_target_directory_safe "$target_dir"; then
        log "managed artifact ${name} target directory chain is missing, redirected, or writable by another account: ${target_dir}"
        return 1
    fi
    if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
        log "managed artifact ${name} target is not a regular file: ${path}"
        return 1
    fi
    if ! getent passwd "$owner" >/dev/null; then
        log "managed artifact ${name} owner does not exist: ${owner}"
        return 1
    fi
    if ! getent group "$group" >/dev/null; then
        log "managed artifact ${name} group does not exist: ${group}"
        return 1
    fi
}

managed_artifact_target_directory_safe() {
    local target_dir="$1" resolved current owner_uid mode mode_value
    local installer_uid="$EUID"

    [[ "$target_dir" == /* && "$target_dir" != "/" && -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    resolved="$(readlink -f -- "$target_dir")" || return 1
    [[ "$resolved" == "$target_dir" ]] || return 1

    current="$target_dir"
    while [[ "$current" != "/" ]]; do
        [[ -d "$current" && ! -L "$current" ]] || return 1
        owner_uid="$(stat -c %u -- "$current")" || return 1
        mode="$(stat -c %a -- "$current")" || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))

        # The production updater runs as root, so every directory component
        # must be root-controlled. A non-root contract runner may also trust
        # its own directories. Writable shared ancestors are safe only when
        # root-owned and sticky (for example /tmp).
        if [[ "$owner_uid" != "0" && "$owner_uid" != "$installer_uid" ]]; then
            return 1
        fi
        if (((mode_value & 8#022) != 0)); then
            if [[ "$owner_uid" != "0" ]] || (((mode_value & 8#1000) == 0)); then
                return 1
            fi
        fi
        current="$(dirname -- "$current")"
    done
}

write_artifact_state() {
    local state_file="$1" value="$2" state_tmp

    state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")" || return 1
    printf '%s\n' "$value" >"$state_tmp"
    chmod 0640 "$state_tmp"
    mv -f -- "$state_tmp" "$state_file"
}

install_managed_artifacts() {
    local line name url sha path mode owner group restart index
    local state_file failed_state download_tmp install_tmp target_dir target_name backup
    local field_count
    local -a names=() urls=() shas=() paths=() modes=() owners=() groups=() restarts=()
    local -A seen_names=() seen_paths=()

    if [ ! -f "$ARTIFACT_MANIFEST" ]; then
        return 0
    fi

    # Validate and de-duplicate the complete manifest before touching the
    # network, an install target, or service state. A bad later row must not
    # leave earlier artifacts partially applied.
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -z "$line" ] || [[ "$line" == \#* ]]; then
            continue
        fi
        field_count="$(awk -F '\t' '{ print NF }' <<<"$line")"
        if [[ "$field_count" != "8" ]]; then
            log "managed artifact manifest row must contain exactly eight tab-separated fields"
            return 1
        fi
        IFS=$'\t' read -r name url sha path mode owner group restart <<<"$line"
        validate_managed_artifact "$name" "$url" "$sha" "$path" "$mode" "$owner" "$group" "$restart" || return 1
        preflight_managed_artifact_target "$name" "$path" "$owner" "$group" || return 1

        if [[ -n "${seen_names[$name]:-}" ]]; then
            log "managed artifact manifest repeats name: $name"
            return 1
        fi
        if [[ -n "${seen_paths[$path]:-}" ]]; then
            log "managed artifact manifest repeats target path: $path"
            return 1
        fi
        seen_names["$name"]=1
        seen_paths["$path"]=1
        names+=("$name")
        urls+=("$url")
        shas+=("$sha")
        paths+=("$path")
        modes+=("$mode")
        owners+=("$owner")
        groups+=("$group")
        restarts+=("$restart")
    done < "$ARTIFACT_MANIFEST"

    for ((index = 0; index < ${#names[@]}; index++)); do
        name="${names[$index]}"
        url="${urls[$index]}"
        sha="${shas[$index]}"
        path="${paths[$index]}"
        mode="${modes[$index]}"
        owner="${owners[$index]}"
        group="${groups[$index]}"
        restart="${restarts[$index]}"

        state_file="${ARTIFACT_STATE_DIR}/${name}.sha256"
        failed_state="${ARTIFACT_STATE_DIR}/${name}.failed"

        if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$sha" ] &&
            managed_artifact_matches "$path" "$sha" &&
            managed_artifact_metadata_matches "$path" "$mode" "$owner" "$group"; then
            log "${name} artifact is already installed"
            continue
        fi

        target_dir="$(dirname -- "$path")"
        target_name="$(basename -- "$path")"
        download_tmp="$(mktemp "${TMP_DIR}/${name}.download.XXXXXX")"
        install_tmp="$(mktemp "${target_dir}/.${target_name}.cloud-compose.XXXXXX")" || {
            rm -f -- "$download_tmp"
            return 1
        }
        backup=""
        log "installing managed artifact ${name}"
        if ! retry_until_success curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 5 --retry-all-errors --retry-delay 2 \
            --connect-timeout 10 --max-time 300 -o "$download_tmp" -- "$url" ||
            ! printf '%s  %s\n' "$sha" "$download_tmp" | sha256sum -c - >/dev/null ||
            ! install -o "$owner" -g "$group" -m "$mode" "$download_tmp" "$install_tmp" ||
            ! managed_artifact_matches "$install_tmp" "$sha"; then
            rm -f -- "$download_tmp" "$install_tmp"
            log "managed artifact ${name} failed download or target verification"
            return 1
        fi
        rm -f -- "$download_tmp"

        if [[ -f "$path" ]]; then
            backup="$(mktemp "${target_dir}/.${target_name}.rollback.XXXXXX")" || {
                rm -f -- "$install_tmp"
                return 1
            }
            if ! cp -p -- "$path" "$backup"; then
                rm -f -- "$install_tmp" "$backup"
                log "managed artifact ${name} could not preserve the previous target"
                return 1
            fi
        fi
        if ! mv -f -- "$install_tmp" "$path" || ! managed_artifact_matches "$path" "$sha"; then
            rm -f -- "$install_tmp"
            if [[ -n "$backup" ]]; then
                mv -f -- "$backup" "$path" || \
                    log "managed artifact ${name} also failed to restore its previous target"
            fi
            log "managed artifact ${name} failed atomic target verification"
            return 1
        fi

        if [ -n "$restart" ]; then
            if ! systemctl try-restart -- "$restart"; then
                if [[ -n "$backup" ]]; then
                    if ! mv -f -- "$backup" "$path"; then
                        log "managed artifact ${name} restart failed and its previous target could not be restored"
                        write_artifact_state "$failed_state" "restart-and-rollback-failed ${sha} $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
                        return 1
                    fi
                else
                    rm -f -- "$path"
                fi
                write_artifact_state "$failed_state" "restart-failed ${sha} $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
                systemctl try-restart -- "$restart" >/dev/null 2>&1 || true
                log "managed artifact ${name} restart failed; restored the previous target"
                return 1
            fi
        fi
        rm -f -- "$backup" "$failed_state"
        write_artifact_state "$state_file" "$sha"
    done
}

update_internal_services() {
    local services_dir="${LIBOPS_INTERNAL_SERVICES_DIR:-/mnt/disks/data/libops-internal}"

    case "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" in
        true | TRUE | 1 | yes | YES) ;;
        *) return 0 ;;
    esac
    case "${LIBOPS_INTERNAL_SERVICES_AUTO_UPDATE:-false}" in
        true | TRUE | 1 | yes | YES) ;;
        *) return 0 ;;
    esac

    if [ ! -f "${services_dir}/docker-compose.yaml" ]; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log "docker is not available; skipping internal service update"
        return 0
    fi

    pushd "$services_dir" >/dev/null
    log "updating internal LibOps services"
    retry_until_success docker compose pull
    if systemctl is-active --quiet cloud-compose-internal-services.service; then
        systemctl restart cloud-compose-internal-services.service
    else
        log "internal LibOps services are inactive; leaving them stopped after pull"
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

    if ((EUID != 0)); then
        log "managed runtime updates must run as root"
        return 1
    fi

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
