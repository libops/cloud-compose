#!/usr/bin/env bash

set -euo pipefail

readonly stage_root=/run/cloud-compose-rootfs-stage
readonly staged_rootfs="$stage_root/rootfs"
readonly bootstrap_dir=/var/lib/cloud-compose/bootstrap
readonly filesystem_prep=/run/cloud-compose-prepare-filesystem
readonly filesystem_persist=/run/cloud-compose-persist-filesystems
readonly filesystem_reconcile=/run/cloud-compose-reconcile-fstab.awk

fail() {
    echo "rootfs archive: $*" >&2
    exit 1
}

canonical_file_mode() {
    case "$1" in
        *.sh) printf '755\n' ;;
        *) printf '644\n' ;;
    esac
}

require_safe_contract_path() {
    local relative_path="$1"

    [[ -n "$relative_path" && "$relative_path" != /* &&
        "$relative_path" != *$'\t'* && "$relative_path" != *$'\r'* &&
        "$relative_path" != *$'\n'* && "$relative_path" != *'//'*
        && ! "$relative_path" =~ (^|/)\.\.?(/|$) ]] ||
        fail "rootfs contract contains an unsafe path"
}

validate_rootfs_archive() {
    local archive_path="$1"
    local member_path normalized_path member_listing member_type
    local rootfs_present=false

    [[ -f "$archive_path" && ! -L "$archive_path" ]] ||
        fail "rootfs archive must be a regular file"
    while IFS= read -r member_path; do
        normalized_path="${member_path%/}"
        require_safe_contract_path "$normalized_path"
        [[ "$normalized_path" == rootfs || "$normalized_path" == rootfs/* ]] ||
            fail "rootfs archive contains a path outside rootfs"
        if [[ "$normalized_path" == rootfs ]]; then
            rootfs_present=true
        fi
    done < <(LC_ALL=C tar --quoting-style=literal -tzf "$archive_path")
    [[ "$rootfs_present" == "true" ]] ||
        fail "rootfs archive does not contain its rootfs directory"

    while IFS= read -r member_listing; do
        member_type="${member_listing:0:1}"
        [[ "$member_type" == "-" || "$member_type" == "d" ]] ||
            fail "rootfs archive contains a link or unsupported filesystem object"
    done < <(LC_ALL=C tar --numeric-owner --quoting-style=escape -tvzf "$archive_path")
}

validate_rootfs_test_source_archive() {
    local archive_path="$1" test_source_prefix="$2"
    local member_path normalized_path member_listing member_type
    local rootfs_present=false

    [[ -f "$archive_path" && ! -L "$archive_path" ]] ||
        fail "test-only rootfs source archive must be a regular file"
    [[ "$test_source_prefix" =~ ^cloud-compose-([0-9a-f]{40})$ ]] ||
        fail "test-only rootfs source archive prefix must identify one exact cloud-compose commit"
    while IFS= read -r member_path; do
        normalized_path="${member_path%/}"
        require_safe_contract_path "$normalized_path"
        [[ "$normalized_path" == "$test_source_prefix" ||
            "$normalized_path" == "$test_source_prefix/"* ]] ||
            fail "test-only rootfs source archive contains a path outside its exact commit prefix"
        if [[ "$normalized_path" == "$test_source_prefix/rootfs" ]]; then
            rootfs_present=true
        fi
    done < <(LC_ALL=C tar --quoting-style=literal -tzf "$archive_path")
    [[ "$rootfs_present" == "true" ]] ||
        fail "test-only rootfs source archive does not contain ${test_source_prefix}/rootfs"

    while IFS= read -r member_listing; do
        member_type="${member_listing:0:1}"
        [[ "$member_type" == "-" || "$member_type" == "d" ]] ||
            fail "test-only rootfs source archive contains a link or unsupported filesystem object"
    done < <(LC_ALL=C tar --numeric-owner --quoting-style=escape -tvzf "$archive_path")
}

rootfs_contract_sha256() {
    local rootfs_dir="$1"
    local contract_manifest="$2"
    local require_root_owner="${3:-true}"
    local absolute_path relative_path expected_mode metadata owner file_sha256 unsupported_path

    [[ -d "$rootfs_dir" && ! -L "$rootfs_dir" ]] ||
        fail "rootfs contract source must be a real directory"
    unsupported_path="$(find "$rootfs_dir" -mindepth 1 ! -type d ! -type f -print -quit)"
    if [[ -n "$unsupported_path" ]]; then
        fail "rootfs contract contains a symlink or unsupported filesystem object"
    fi

    : >"$contract_manifest"
    while IFS= read -r -d '' absolute_path; do
        relative_path="${absolute_path#"$rootfs_dir"/}"
        require_safe_contract_path "$relative_path"
        metadata="$(stat -c '%a:%F' -- "$absolute_path")"
        [[ "$metadata" == "755:directory" ]] ||
            fail "rootfs contract directory is not mode 0755: $relative_path"
        owner="$(stat -c '%u:%g' -- "$absolute_path")"
        [[ "$require_root_owner" != "true" || "$owner" == "0:0" ]] ||
            fail "rootfs contract directory is not root-owned: $relative_path"
        printf 'd\t0:0:755\t%s\n' "$relative_path" >>"$contract_manifest"
    done < <(find "$rootfs_dir" -mindepth 1 -type d -print0 | LC_ALL=C sort -z)

    while IFS= read -r -d '' absolute_path; do
        relative_path="${absolute_path#"$rootfs_dir"/}"
        require_safe_contract_path "$relative_path"
        expected_mode="$(canonical_file_mode "$relative_path")"
        metadata="$(stat -c '%a:%h:%F' -- "$absolute_path")"
        [[ "$metadata" == "${expected_mode}:1:regular file" ]] ||
            fail "rootfs contract file metadata is not canonical: $relative_path"
        owner="$(stat -c '%u:%g' -- "$absolute_path")"
        [[ "$require_root_owner" != "true" || "$owner" == "0:0" ]] ||
            fail "rootfs contract file is not root-owned: $relative_path"
        read -r file_sha256 _ < <(sha256sum -- "$absolute_path")
        printf 'f\t%s\t0:0:%s\t%s\n' \
            "$file_sha256" "$expected_mode" "$relative_path" >>"$contract_manifest"
    done < <(find "$rootfs_dir" -type f -print0 | LC_ALL=C sort -z)

    read -r contract_sha256 _ < <(sha256sum -- "$contract_manifest")
    printf '%s\n' "$contract_sha256"
}

require_safe_overlay_dir() {
    local overlay_dir="$1"

    if [[ -n "$overlay_dir" && "$overlay_dir" != "/var/lib/cloud-compose/rootfs-overlay" ]]; then
        fail "overlay directory must be /var/lib/cloud-compose/rootfs-overlay"
    fi
    if [[ -L "$overlay_dir" ]]; then
        fail "overlay directory must not be a symlink"
    fi
}

install_archive_tools() {
    if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ca-certificates curl tar
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl tar
    elif command -v rpm-ostree >/dev/null 2>&1; then
        rpm-ostree install --apply-live ca-certificates curl tar
    else
        fail "no supported package manager found to install curl and tar"
    fi
}

prepare_archive() {
    local archive_url_b64="$1" archive_sha256="$2" expected_contract_sha256="$3"
    local test_source_prefix="${4:-}"
    local archive_url extract_dir rootfs_dir required_command
    local contract_manifest contract_sha256 source_commit unsupported_path

    archive_url="$(printf '%s' "$archive_url_b64" | base64 -d)" || \
        fail "rootfs archive URL is not valid base64 data"
    [[ "$archive_url" == https://* ]] || fail "rootfs archive URL must use HTTPS"
    [[ "$archive_url" != *[[:space:]]* ]] || fail "rootfs archive URL must not contain whitespace"
    [[ "$archive_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail "rootfs archive checksum must be a lowercase SHA-256 digest"
    [[ "$expected_contract_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail "rootfs content contract must be a lowercase SHA-256 digest"
    if [[ -n "$test_source_prefix" ]]; then
        [[ "$test_source_prefix" =~ ^cloud-compose-([0-9a-f]{40})$ ]] ||
            fail "test-only rootfs source archive prefix must identify one exact cloud-compose commit"
        source_commit="${BASH_REMATCH[1]}"
        [[ "$archive_url" == "https://github.com/libops/cloud-compose/archive/${source_commit}.tar.gz" ]] ||
            fail "test-only rootfs source archive URL must select the exact commit named by its prefix"
    fi

    install_archive_tools
    for required_command in awk chmod curl find sha256sum sort stat tar; do
        command -v "$required_command" >/dev/null 2>&1 || \
            fail "$required_command is required to install the verified rootfs archive"
    done

    if [[ -L "$stage_root" ]]; then
        fail "rootfs archive stage must not be a symlink"
    fi
    rm -rf -- "$stage_root"
    install -d -m 0700 -o root -g root "$stage_root"
    extract_dir="$stage_root/extract"
    install -d -m 0700 -o root -g root "$extract_dir"

    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 5 --retry-all-errors --retry-delay 2 --retry-max-time 900 \
        --connect-timeout 10 --max-time 300 \
        -o "$stage_root/rootfs.tar.gz" -- "$archive_url"
    printf '%s  %s\n' "$archive_sha256" "$stage_root/rootfs.tar.gz" | sha256sum -c -
    if [[ -n "$test_source_prefix" ]]; then
        validate_rootfs_test_source_archive "$stage_root/rootfs.tar.gz" "$test_source_prefix"
        tar --no-same-owner --same-permissions -xzf "$stage_root/rootfs.tar.gz" \
            -C "$extract_dir" "$test_source_prefix/rootfs"
        rootfs_dir="$extract_dir/$test_source_prefix/rootfs"
        # This test-only GitHub source path preserves Git modes rather than
        # canonical rootfs package modes. Normalize only the isolated rootfs
        # subtree; the exact byte/content contract remains authoritative.
        find "$rootfs_dir" -depth -type d -empty -delete
        find "$rootfs_dir" -type d -exec chmod 0755 -- {} +
        find "$rootfs_dir" -type f -exec chmod 0644 -- {} +
        find "$rootfs_dir" -type f -name '*.sh' -exec chmod 0755 -- {} +
    else
        validate_rootfs_archive "$stage_root/rootfs.tar.gz"
        tar --no-same-owner --same-permissions -xzf "$stage_root/rootfs.tar.gz" -C "$extract_dir"
        rootfs_dir="$extract_dir/rootfs"
    fi
    [[ -n "$rootfs_dir" && -d "$rootfs_dir" ]] || \
        fail "rootfs directory not found in $archive_url"
    unsupported_path="$(find "$rootfs_dir" -mindepth 1 ! -type d ! -type f -print -quit)"
    if [[ -n "$unsupported_path" ]]; then
        fail "verified rootfs archive contains a symlink or unsupported filesystem object"
    fi
    contract_manifest="$stage_root/rootfs-contract.tsv"
    contract_sha256="$(rootfs_contract_sha256 "$rootfs_dir" "$contract_manifest" true)"
    [[ "$contract_sha256" == "$expected_contract_sha256" ]] || \
        fail "rootfs archive paths, bytes, or canonical metadata do not match this cloud-compose module source"
    mv -- "$rootfs_dir" "$staged_rootfs"
    rm -f -- "$stage_root/rootfs.tar.gz"
    rm -rf -- "$extract_dir"

    [[ -f "$staged_rootfs/home/cloud-compose/prepare-filesystem.sh" &&
        -f "$staged_rootfs/home/cloud-compose/persist-filesystems.sh" &&
        -f "$staged_rootfs/etc/cloud-compose/awk/reconcile-fstab.awk" ]] || \
        fail "verified rootfs archive is missing filesystem preparation programs"
    install -m 0600 -- \
        "$staged_rootfs/home/cloud-compose/prepare-filesystem.sh" \
        "$filesystem_prep"
    install -m 0600 -- \
        "$staged_rootfs/home/cloud-compose/persist-filesystems.sh" \
        "$filesystem_persist"
    install -m 0600 -- \
        "$staged_rootfs/etc/cloud-compose/awk/reconcile-fstab.awk" \
        "$filesystem_reconcile"
}

install_staged_archive() {
    local overlay_dir="${1:-}"

    [[ -d "$staged_rootfs" && ! -L "$staged_rootfs" ]] || \
        fail "verified rootfs directory is unavailable during installation"
    require_safe_overlay_dir "$overlay_dir"
    cp -a "$staged_rootfs"/. /
    if [[ -n "$overlay_dir" && -d "$overlay_dir" ]]; then
        cp -a "$overlay_dir"/. /
        rm -rf -- "$overlay_dir"
    fi
    rm -rf -- "$stage_root"
}

verify_linux_bootstrap() {
    local expected_sha256="$1"
    local source="$bootstrap_dir/linux-vm-cloud-init.sh"
    local metadata

    [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail "Linux VM cloud-init checksum must be a lowercase SHA-256 digest"
    [[ -f "$source" && ! -L "$source" ]] || \
        fail "Linux VM cloud-init program is missing or redirected"
    metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$source")"
    [[ "$metadata" == "0:0:700:1:regular file" ]] || \
        fail "Linux VM cloud-init program is not an unlinked root-owned mode-0700 file"
    printf '%s  %s\n' "$expected_sha256" "$source" | sha256sum -c -
}

install_bootstrap_diagnostics() {
    local expected_sha256="$1"
    local source="$bootstrap_dir/cloud-compose-diagnostics.sh"
    local destination=/etc/cloud-compose/bin/cloud-compose-diagnostics.sh
    local source_metadata destination_metadata

    [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || \
        fail "diagnostics checksum must be a lowercase SHA-256 digest"
    [[ -f "$source" && ! -L "$source" ]] || \
        fail "staged diagnostics program is missing or redirected"
    source_metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$source")"
    [[ "$source_metadata" == "0:0:600:1:regular file" ]] || \
        fail "staged diagnostics program is not an unlinked root-owned mode-0600 file"
    printf '%s  %s\n' "$expected_sha256" "$source" | sha256sum -c -

    for directory in /etc/cloud-compose /etc/cloud-compose/bin; do
        [[ ! -L "$directory" ]] || fail "diagnostics destination is redirected: $directory"
        install -d -m 0755 -o root -g root -- "$directory"
    done
    install -m 0755 -o root -g root -- "$source" "$destination"
    destination_metadata="$(stat -c '%u:%g:%a:%h:%F' -- "$destination")"
    [[ "$destination_metadata" == "0:0:755:1:regular file" ]] || \
        fail "installed diagnostics program is not an unlinked root-owned mode-0755 file"
    printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum -c -
}

action="${1:-}"
case "$action" in
    contract)
        [[ "$#" -eq 2 ]] || fail "usage: rootfs-archive.sh contract ROOTFS_DIR"
        contract_tmp="$(mktemp)"
        trap 'rm -f -- "$contract_tmp"' EXIT
        rootfs_contract_sha256 "$2" "$contract_tmp" false
        ;;
    validate-archive)
        [[ "$#" -eq 2 ]] || fail "usage: rootfs-archive.sh validate-archive ARCHIVE"
        validate_rootfs_archive "$2"
        ;;
    prepare)
        [[ "$#" -eq 4 ]] || \
            fail "usage: rootfs-archive.sh prepare URL_B64 SHA256 ROOTFS_CONTRACT_SHA256"
        prepare_archive "$2" "$3" "$4"
        ;;
    prepare-linux)
        [[ "$#" -eq 5 ]] || \
            fail "usage: rootfs-archive.sh prepare-linux URL_B64 SHA256 ROOTFS_CONTRACT_SHA256 LINUX_BOOTSTRAP_SHA256"
        prepare_archive "$2" "$3" "$4"
        verify_linux_bootstrap "$5"
        ;;
    prepare-linux-test-source)
        [[ "$#" -eq 6 ]] || \
            fail "usage: rootfs-archive.sh prepare-linux-test-source URL_B64 SHA256 ROOTFS_CONTRACT_SHA256 LINUX_BOOTSTRAP_SHA256 TEST_SOURCE_PREFIX"
        prepare_archive "$2" "$3" "$4" "$6"
        verify_linux_bootstrap "$5"
        ;;
    install-staged)
        [[ "$#" -le 2 ]] || fail "usage: rootfs-archive.sh install-staged [OVERLAY_DIR]"
        install_staged_archive "${2:-}"
        ;;
    install)
        [[ "$#" -le 5 && "$#" -ge 4 ]] || \
            fail "usage: rootfs-archive.sh install URL_B64 SHA256 ROOTFS_CONTRACT_SHA256 [OVERLAY_DIR]"
        [[ -f /run/cloud-compose-filesystems-ready ]] || \
            fail "Cloud Compose filesystems were not prepared; refusing rootfs installation"
        prepare_archive "$2" "$3" "$4"
        install_staged_archive "${5:-}"
        ;;
    install-diagnostics)
        [[ "$#" -eq 2 ]] || \
            fail "usage: rootfs-archive.sh install-diagnostics DIAGNOSTICS_SHA256"
        install_bootstrap_diagnostics "$2"
        ;;
    *)
        fail "usage: rootfs-archive.sh contract|validate-archive|prepare|prepare-linux|prepare-linux-test-source|install-staged|install|install-diagnostics ..."
        ;;
esac
