#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
readonly archive_name=cloud-compose-rootfs.tar.gz
readonly archive_checksum_name=cloud-compose-rootfs.tar.gz.sha256
readonly contract_name=cloud-compose-rootfs.contract.sha256

fail() {
    echo "rootfs release verification: $*" >&2
    exit 1
}

resolve_tag_for_commit() {
    local commit="$1" attempt tag

    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || fail "commit must be a full lowercase Git SHA"
    for ((attempt = 1; attempt <= 60; attempt++)); do
        git fetch --force --tags origin >/dev/null 2>&1 || true
        tag="$(git tag --points-at "$commit" --sort=-version:refname | head -n 1)"
        if [[ -n "$tag" ]]; then
            printf '%s\n' "$tag"
            return 0
        fi
        sleep 10
    done
    fail "no release tag appeared for commit $commit"
}

download_assets() {
    local tag="$1" destination="$2" attempt

    for ((attempt = 1; attempt <= 60; attempt++)); do
        if gh release download "$tag" \
            --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" \
            --dir "$destination" \
            --clobber \
            --pattern "$archive_name" \
            --pattern "$archive_checksum_name" \
            --pattern "$contract_name" >/dev/null 2>&1 &&
            [[ -f "$destination/$archive_name" &&
                -f "$destination/$archive_checksum_name" &&
                -f "$destination/$contract_name" ]]; then
            return 0
        fi
        sleep 10
    done
    fail "release $tag did not publish all three immutable rootfs assets"
}

verify_assets() {
    local tag="$1" asset_dir="$2" extract_dir="$3"
    local checksum_line expected_archive_sha256 checksum_filename actual_archive_sha256
    local contract_sha256 actual_contract_sha256

    checksum_line="$(<"$asset_dir/$archive_checksum_name")"
    [[ "$checksum_line" =~ ^([0-9a-f]{64})\ \ cloud-compose-rootfs\.tar\.gz$ ]] ||
        fail "release $tag has a malformed archive checksum asset"
    expected_archive_sha256="${BASH_REMATCH[1]}"
    checksum_filename="${checksum_line#*  }"
    [[ "$checksum_filename" == "$archive_name" ]] ||
        fail "release $tag checksum names an unexpected archive"
    actual_archive_sha256="$(sha256sum -- "$asset_dir/$archive_name" | cut -d' ' -f1)"
    [[ "$actual_archive_sha256" == "$expected_archive_sha256" ]] ||
        fail "release $tag archive bytes do not match its checksum"

    [[ "$(wc -c <"$asset_dir/$contract_name")" -eq 65 ]] ||
        fail "release $tag rootfs contract must be one digest plus a newline"
    contract_sha256="$(<"$asset_dir/$contract_name")"
    [[ "$contract_sha256" =~ ^[0-9a-f]{64}$ ]] ||
        fail "release $tag rootfs contract is not a lowercase SHA-256 digest"

    bash "$repo_root/rootfs/etc/cloud-compose/libexec/rootfs-archive.sh" \
        validate-archive "$asset_dir/$archive_name" ||
        fail "release $tag archive member topology is unsafe"

    install -d -m 0755 "$extract_dir"
    tar --no-same-owner --same-permissions \
        -xzf "$asset_dir/$archive_name" -C "$extract_dir"
    actual_contract_sha256="$(
        bash "$repo_root/rootfs/etc/cloud-compose/libexec/rootfs-archive.sh" \
            contract "$extract_dir/rootfs"
    )"
    [[ "$actual_contract_sha256" == "$contract_sha256" ]] ||
        fail "release $tag archive does not match its canonical rootfs contract"
}

verify_source_assets() {
    local tag="$1" asset_dir="$2" expected_dir="$3"

    bash "$repo_root/ci/package-rootfs.sh" "$expected_dir"
    for asset in "$archive_name" "$archive_checksum_name" "$contract_name"; do
        cmp -- "$expected_dir/$asset" "$asset_dir/$asset" ||
            fail "release $tag asset $asset does not match the tagged source"
    done
}

main() {
    local selector="${1:-}" value="${2:-}" tag tmp

    [[ "$#" -eq 2 ]] || fail "usage: verify-rootfs-release.sh tag TAG|commit SHA"
    case "$selector" in
        tag)
            [[ "$value" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] ||
                fail "tag is not a semantic-version release tag"
            tag="$value"
            ;;
        commit)
            tag="$(resolve_tag_for_commit "$value")"
            ;;
        *) fail "usage: verify-rootfs-release.sh tag TAG|commit SHA" ;;
    esac

    tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cloud-compose-rootfs-release.XXXXXX")"
    trap 'rm -rf -- "$tmp"' EXIT
    install -d -m 0755 "$tmp/assets"
    download_assets "$tag" "$tmp/assets"
    verify_source_assets "$tag" "$tmp/assets" "$tmp/expected"
    verify_assets "$tag" "$tmp/assets" "$tmp/extracted"
    echo "Verified rootfs release assets for $tag"
}

main "$@"
