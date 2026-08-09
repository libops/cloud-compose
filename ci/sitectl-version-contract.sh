#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_script="$repo_root/rootfs/home/cloud-compose/libops-managed-runtime.sh"
export CLOUD_COMPOSE_JQ_PROGRAM_DIR="$repo_root/rootfs/etc/cloud-compose/jq"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-sitectl-versions.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

touch "$tmp/profile.sh"

# A restrictive first-boot umask once left the root-owned managed binary path
# untraversable after application initialization dropped privileges. Exercise
# the production mkdirs implementation against that preexisting state and
# require every invocation to converge both public and private modes.
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    bash --noprofile --norc -c '
        set -euo pipefail
        source "$1"
        STATE_DIR="$2/mode-state"
        BIN_DIR="$STATE_DIR/bin"
        TMP_DIR="$STATE_DIR/tmp"
        PACKAGE_STATE_DIR="$STATE_DIR/packages"
        ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
        PUBLISHED_BIN_DIR="$2/published"

        umask 0077
        mkdir -p \
            "$BIN_DIR" \
            "$TMP_DIR" \
            "$PACKAGE_STATE_DIR" \
            "$ARTIFACT_STATE_DIR" \
            "$PUBLISHED_BIN_DIR"
        chmod 0700 "$STATE_DIR" "$BIN_DIR"
        chmod 0755 "$TMP_DIR" "$PACKAGE_STATE_DIR" "$ARTIFACT_STATE_DIR"

        mkdirs
        mkdirs

        test "$(stat -c "%a" "$STATE_DIR")" = 755
        test "$(stat -c "%a" "$BIN_DIR")" = 755
        test "$(stat -c "%a" "$TMP_DIR")" = 700
        test "$(stat -c "%a" "$PACKAGE_STATE_DIR")" = 700
        test "$(stat -c "%a" "$ARTIFACT_STATE_DIR")" = 700
        test "$(stat -c "%a" "$PUBLISHED_BIN_DIR")" = 755
        test "$(stat -c "%u:%g" "$STATE_DIR")" = "$(id -u):$(id -g)"
        test "$(stat -c "%u:%g" "$PUBLISHED_BIN_DIR")" = "$(id -u):$(id -g)"

        touch "$PUBLISHED_BIN_DIR/docker"
        if mkdirs; then
            echo "managed runtime accepted an unmanaged published command" >&2
            exit 1
        fi
        rm -f "$PUBLISHED_BIN_DIR/docker"

        touch "$BIN_DIR/make"
        ln -s "$BIN_DIR/make" "$PUBLISHED_BIN_DIR/make"
        mkdirs
        rm -f "$PUBLISHED_BIN_DIR/make"
        ln -s "$2/unsafe-make" "$PUBLISHED_BIN_DIR/make"
        if mkdirs; then
            echo "managed runtime accepted an unsafe published Make target" >&2
            exit 1
        fi
        rm -f "$PUBLISHED_BIN_DIR/make"

        unsafe_target="$2/unsafe-target"
        unsafe_state="$2/unsafe-state"
        mkdir -p "$unsafe_target"
        ln -s "$unsafe_target" "$unsafe_state"
        STATE_DIR="$unsafe_state"
        BIN_DIR="$STATE_DIR/bin"
        TMP_DIR="$STATE_DIR/tmp"
        PACKAGE_STATE_DIR="$STATE_DIR/packages"
        ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
        if mkdirs; then
            echo "managed runtime accepted a redirected state directory" >&2
            exit 1
        fi

        unsafe_state="$2/unsafe-writable-state"
        mkdir -m 0775 "$unsafe_state"
        STATE_DIR="$unsafe_state"
        BIN_DIR="$STATE_DIR/bin"
        TMP_DIR="$STATE_DIR/tmp"
        PACKAGE_STATE_DIR="$STATE_DIR/packages"
        ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
        if mkdirs; then
            echo "managed runtime accepted group-writable state" >&2
            exit 1
        fi
    ' cloud-compose-sitectl-modes "$runtime_script" "$tmp"

run_contract() {
    CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
        SITECTL_PACKAGES="$1" \
        SITECTL_VERSION="$2" \
        SITECTL_PACKAGE_VERSIONS="$3" \
        bash --noprofile --norc -c '
            set -euo pipefail
            source "$1"
            shift
            validate_sitectl_configuration
            while (( $# > 0 )); do
                package="$1"
                expected="$2"
                shift 2
                actual="$(sitectl_package_version "$package")"
                test "$actual" = "$expected"
            done
        ' cloud-compose-sitectl-versions "$runtime_script" "${@:4}"
}

reject_contract() {
    local packages="$1" version="$2" package_versions="$3"

    if CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
        SITECTL_PACKAGES="$packages" \
        SITECTL_VERSION="$version" \
        SITECTL_PACKAGE_VERSIONS="$package_versions" \
        bash --noprofile --norc -c '
            set -euo pipefail
            source "$1"
            validate_sitectl_configuration
            touch "$2"
        ' cloud-compose-sitectl-versions "$runtime_script" "$tmp/download-started" >/dev/null 2>&1; then
        echo "Invalid sitectl version contract was accepted: $package_versions" >&2
        return 1
    fi
    test ! -e "$tmp/download-started"
}

run_contract \
    "sitectl sitectl-isle sitectl-drupal" \
    "v0.38.0" \
    '{"sitectl":"v0.39.0-rc.1","sitectl-isle":"v0.12.0"}' \
    sitectl v0.39.0-rc.1 \
    sitectl-isle v0.12.0 \
    sitectl-drupal v0.38.0

run_contract \
    "sitectl sitectl-isle" \
    "v0.38.0" \
    '{}' \
    sitectl v0.38.0 \
    sitectl-isle v0.38.0

run_contract \
    "sitectl sitectl-isle" \
    "latest" \
    '{"sitectl":"v0.38.0","sitectl-isle":"latest"}' \
    sitectl v0.38.0 \
    sitectl-isle latest

reject_contract "sitectl sitectl-isle" "v0.38.0" '{'
reject_contract "sitectl sitectl-isle" "v0.38.0" '[]'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl-isle":12}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"../../sitectl":"v0.1.0"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl-isle":"v0.12.0/../../latest"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl-wp":"v0.9.0"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl\n":"v0.38.0"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl\u0000":"v0.38.0"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl":"latest\n"}'
reject_contract "sitectl sitectl-isle" "v0.38.0" '{"sitectl":"v0.38.0\u0000"}'
reject_contract "sitectl sitectl-isle" "v0.38.0/../../latest" '{}'
reject_contract "sitectl --installroot" "latest" '{}'

CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    bash --noprofile --norc -c '
        set -euo pipefail
        source "$1"
        TMP_DIR="$2"
        mkdir -p "$TMP_DIR"
        retry_until_success() {
            "$@"
        }
        curl() {
            local output="" url=""
            while (( $# > 0 )); do
                case "$1" in
                    -o)
                        output="$2"
                        shift 2
                        ;;
                    http*)
                        url="$1"
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            test "$url" = "https://api.github.com/repos/libops/sitectl-isle/releases/latest"
            printf "%s\n" "{\"tag_name\":\"v0.12.0\"}" >"$output"
        }
        tag="$(latest_release_tag sitectl-isle)"
        test "$tag" = "v0.12.0"
        base_url="$(release_base_url sitectl-isle "$tag")"
        test "$base_url" = "https://github.com/libops/sitectl-isle/releases/download/v0.12.0"
        [[ "$base_url" != */releases/latest/download ]]
    ' cloud-compose-sitectl-latest "$runtime_script" "$tmp/latest"

reject_latest_metadata() {
    local metadata="$1"

    if CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
        LATEST_METADATA="$metadata" \
        bash --noprofile --norc -c '
            set -euo pipefail
            source "$1"
            TMP_DIR="$2"
            mkdir -p "$TMP_DIR"
            retry_until_success() {
                "$@"
            }
            curl() {
                local output=""
                while (( $# > 0 )); do
                    if [[ "$1" == "-o" ]]; then
                        output="$2"
                        shift 2
                    else
                        shift
                    fi
                done
                printf "%s\n" "$LATEST_METADATA" >"$output"
            }
            latest_release_tag sitectl-isle
        ' cloud-compose-sitectl-latest "$runtime_script" "$tmp/latest-invalid" >/dev/null 2>&1; then
        echo "Latest release resolution accepted invalid metadata: $metadata" >&2
        return 1
    fi
}

reject_latest_metadata '{}'
reject_latest_metadata '{"tag_name":"latest"}'
reject_latest_metadata '{"tag_name":"v0.12.0\n"}'
reject_latest_metadata '{"tag_name":"v0.12.0\u0000"}'

CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    SITECTL_PACKAGES="sitectl sitectl-isle" \
    SITECTL_VERSION="latest" \
    SITECTL_PACKAGE_VERSIONS='{"sitectl":"latest","sitectl-isle":"latest"}' \
    bash --noprofile --norc -c '
        set -euo pipefail
        source "$1"
        STATE_DIR="$2/install-state"
        BIN_DIR="$STATE_DIR/bin"
        TMP_DIR="$STATE_DIR/tmp"
        PACKAGE_STATE_DIR="$STATE_DIR/packages"
        ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
        fixture_root="$2"
        url_log="$fixture_root/install-urls"

        mkdirs() {
            mkdir -p "$BIN_DIR" "$TMP_DIR" "$PACKAGE_STATE_DIR" "$ARTIFACT_STATE_DIR"
        }
        machine_arch() {
            printf "%s\n" x86_64
        }
        latest_release_tag() {
            test "$1" = "sitectl-isle"
            printf "%s\n" v0.12.0
        }
        retry_until_success() {
            "$@"
        }
        ln() {
            :
        }
        curl() {
            local output="" url="" archive_dir archive_path payload_dir checksum
            while (( $# > 0 )); do
                case "$1" in
                    -o)
                        output="$2"
                        shift 2
                        ;;
                    http*)
                        url="$1"
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            printf "%s\n" "$url" >>"$url_log"
            case "$url" in
                */sitectl-isle_Linux_x86_64.tar.gz)
                    payload_dir="$(mktemp -d "$fixture_root/payload.XXXXXX")"
                    printf "#!/usr/bin/env bash\n" >"$payload_dir/sitectl-isle"
                    printf "release documentation\n" >"$payload_dir/README.md"
                    chmod 0755 "$payload_dir/sitectl-isle"
                    tar -czf "$output" -C "$payload_dir" sitectl-isle README.md
                    rm -rf "$payload_dir"
                    ;;
                */checksums.txt)
                    archive_dir="$(dirname "$output")"
                    archive_path="$archive_dir/sitectl-isle_Linux_x86_64.tar.gz"
                    checksum="$(sha256sum "$archive_path")"
                    checksum="${checksum%% *}"
                    printf "%s  %s\n" "$checksum" "$(basename "$archive_path")" >"$output"
                    ;;
                *)
                    return 1
                    ;;
            esac
        }

        mkdirs
        install_release_package sitectl-isle
        test "$(cat "$PACKAGE_STATE_DIR/sitectl-isle.version")" = "v0.12.0"
        test "$(wc -l <"$url_log")" -eq 2
        grep -Fxq "https://github.com/libops/sitectl-isle/releases/download/v0.12.0/sitectl-isle_Linux_x86_64.tar.gz" "$url_log"
        grep -Fxq "https://github.com/libops/sitectl-isle/releases/download/v0.12.0/checksums.txt" "$url_log"
        if grep -Fq "/releases/latest/download" "$url_log"; then
            echo "Installer mixed a resolved latest tag with a mutable latest URL" >&2
            exit 1
        fi
    ' cloud-compose-sitectl-install "$runtime_script" "$tmp"

# Package sets are staged as one generation. A later plugin failure cannot
# replace an already-installed core, and a promotion failure restores every
# binary and version/checksum state file.
CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh" \
    SITECTL_PACKAGES="sitectl sitectl-isle" \
    SITECTL_VERSION="v1.0.0" \
    SITECTL_PACKAGE_VERSIONS='{"sitectl":"v1.0.0","sitectl-isle":"v1.0.0"}' \
    bash --noprofile --norc -c '
        set -euo pipefail
        source "$1"
        STATE_DIR="$2/generation-state"
        BIN_DIR="$STATE_DIR/bin"
        TMP_DIR="$STATE_DIR/tmp"
        PACKAGE_STATE_DIR="$STATE_DIR/packages"
        ARTIFACT_STATE_DIR="$STATE_DIR/artifacts"
        PUBLISHED_BIN_DIR="$STATE_DIR/published"
        mkdirs() {
            mkdir -p "$BIN_DIR" "$TMP_DIR" "$PACKAGE_STATE_DIR" "$ARTIFACT_STATE_DIR" "$PUBLISHED_BIN_DIR"
        }
        mkdirs

        for package in sitectl sitectl-isle; do
            printf "old-%s\n" "$package" >"$BIN_DIR/$package"
            chmod 0755 "$BIN_DIR/$package"
            printf "v0.9.0\n" >"$PACKAGE_STATE_DIR/$package.version"
            sha="$(sha256sum "$BIN_DIR/$package")"
            printf "%s\n" "${sha%% *}" >"$PACKAGE_STATE_DIR/$package.sha256"
            command ln -s "$BIN_DIR/$package" "$PUBLISHED_BIN_DIR/$package"
        done

        install_release_package() {
            local package="$1" target="$2"
            if [[ "${FAKE_STAGE_FAIL_PACKAGE:-}" == "$package" ]]; then
                return 1
            fi
            printf "new-%s\n" "$package" >"$target/$package"
            chmod 0755 "$target/$package"
            RELEASE_PACKAGE_TAG=v1.0.0
            sha="$(sha256sum "$target/$package")"
            RELEASE_PACKAGE_SHA256="${sha%% *}"
        }
        ln() {
            if [[ "${FAKE_LINK_FAIL_PACKAGE:-}" != "" && "${!#}" == */"$FAKE_LINK_FAIL_PACKAGE" ]]; then
                return 1
            fi
            command ln "$@"
        }

        if FAKE_STAGE_FAIL_PACKAGE=sitectl-isle install_sitectl_packages; then
            echo "staging failure was accepted" >&2
            exit 1
        fi
        grep -Fxq old-sitectl "$BIN_DIR/sitectl"
        grep -Fxq old-sitectl-isle "$BIN_DIR/sitectl-isle"
        grep -Fxq v0.9.0 "$PACKAGE_STATE_DIR/sitectl.version"

        if FAKE_LINK_FAIL_PACKAGE=sitectl-isle install_sitectl_packages; then
            echo "promotion failure was accepted" >&2
            exit 1
        fi
        grep -Fxq old-sitectl "$BIN_DIR/sitectl"
        grep -Fxq old-sitectl-isle "$BIN_DIR/sitectl-isle"
        grep -Fxq v0.9.0 "$PACKAGE_STATE_DIR/sitectl.version"
        grep -Fxq v0.9.0 "$PACKAGE_STATE_DIR/sitectl-isle.version"

        install_sitectl_packages
        grep -Fxq new-sitectl "$BIN_DIR/sitectl"
        grep -Fxq new-sitectl-isle "$BIN_DIR/sitectl-isle"
        grep -Fxq v1.0.0 "$PACKAGE_STATE_DIR/sitectl.version"
        grep -Fxq v1.0.0 "$PACKAGE_STATE_DIR/sitectl-isle.version"

        # Dropping a plugin is part of the same generation transaction. A
        # later core-promotion failure restores the removed plugin exactly.
        if SITECTL_PACKAGES=sitectl \
            SITECTL_PACKAGE_VERSIONS='"'"'{"sitectl":"v1.0.0"}'"'"' \
            FAKE_LINK_FAIL_PACKAGE=sitectl \
            install_sitectl_packages; then
            echo "promotion failure after stale-package removal was accepted" >&2
            exit 1
        fi
        grep -Fxq new-sitectl-isle "$BIN_DIR/sitectl-isle"
        grep -Fxq v1.0.0 "$PACKAGE_STATE_DIR/sitectl-isle.version"
        test "$(readlink "$PUBLISHED_BIN_DIR/sitectl-isle")" = "$BIN_DIR/sitectl-isle"

        SITECTL_PACKAGES=sitectl \
            SITECTL_PACKAGE_VERSIONS='"'"'{"sitectl":"v1.0.0"}'"'"' \
            install_sitectl_packages
        test ! -e "$BIN_DIR/sitectl-isle"
        test ! -e "$PACKAGE_STATE_DIR/sitectl-isle.version"
        test ! -e "$PACKAGE_STATE_DIR/sitectl-isle.sha256"
        test ! -e "$PUBLISHED_BIN_DIR/sitectl-isle"
        grep -Fxq new-sitectl "$BIN_DIR/sitectl"

        # The managed namespace is fail-closed: an untracked command without
        # matching version/checksum state is reported, never deleted.
        printf "operator-owned\n" >"$BIN_DIR/sitectl-local"
        chmod 0755 "$BIN_DIR/sitectl-local"
        command ln -s "$BIN_DIR/sitectl-local" "$PUBLISHED_BIN_DIR/sitectl-local"
        if SITECTL_PACKAGES=sitectl \
            SITECTL_PACKAGE_VERSIONS='"'"'{"sitectl":"v1.0.0"}'"'"' \
            install_sitectl_packages; then
            echo "unproven stale package was removed" >&2
            exit 1
        fi
        grep -Fxq operator-owned "$BIN_DIR/sitectl-local"
        test "$(readlink "$PUBLISHED_BIN_DIR/sitectl-local")" = "$BIN_DIR/sitectl-local"
    ' cloud-compose-sitectl-generation "$runtime_script" "$tmp"

echo "sitectl package-version contract passed"
