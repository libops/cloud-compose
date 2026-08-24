#!/usr/bin/env bash

set -euo pipefail

version=""
while (($#)); do
    case "$1" in
        --version) version="${2:-}"; shift 2 ;;
        *) echo "Unknown bootstrap-sitectl argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$version" == latest || "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || {
    echo "sitectl version must be latest or an exact release version" >&2
    exit 2
}
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) echo "Unsupported sitectl architecture: $(uname -m)" >&2; exit 1 ;;
esac

archive="sitectl_Linux_${arch}.tar.gz"
if [[ "$version" == latest ]]; then
    base="https://github.com/libops/sitectl/releases/latest/download"
else
    base="https://github.com/libops/sitectl/releases/download/${version}"
fi
tmp="$(mktemp -d /run/cloud-compose-sitectl.XXXXXXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 5 --retry-all-errors --connect-timeout 10 --max-time 300 \
    -o "$tmp/checksums.txt" -- "$base/checksums.txt"
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 5 --retry-all-errors --connect-timeout 10 --max-time 300 \
    -o "$tmp/$archive" -- "$base/$archive"

expected=""
while read -r digest filename extra; do
    filename="${filename#\*}"
    if [[ "$filename" == "$archive" && -z "$extra" && "$digest" =~ ^[0-9a-f]{64}$ ]]; then
        [[ -z "$expected" ]] || {
            echo "Duplicate sitectl checksum entry for $archive" >&2
            exit 1
        }
        expected="$digest"
    fi
done <"$tmp/checksums.txt"
[[ -n "$expected" ]] || {
    echo "Missing sitectl checksum entry for $archive" >&2
    exit 1
}
printf '%s  %s\n' "$expected" "$tmp/$archive" | sha256sum -c -

sitectl_entries=0
while IFS= read -r entry; do
    if [[ "$entry" == sitectl ]]; then
        sitectl_entries=$((sitectl_entries + 1))
    fi
done < <(tar -tzf "$tmp/$archive")
[[ "$sitectl_entries" -eq 1 ]] || {
    echo "sitectl archive must contain exactly one entry named sitectl" >&2
    exit 1
}
tar -xzf "$tmp/$archive" -C "$tmp" -- sitectl
[[ "$(stat -c '%F:%h' -- "$tmp/sitectl")" == "regular file:1" ]] || {
    echo "Extracted sitectl must be a regular file with one hard link" >&2
    exit 1
}
bootstrap_sitectl=/etc/cloud-compose/bin/bootstrap-sitectl
install -d -m 0755 -o root -g root -- /etc/cloud-compose/bin
install -m 0755 -o root -g root -- "$tmp/sitectl" "$bootstrap_sitectl"
"$bootstrap_sitectl" host filesystems --help >/dev/null
"$bootstrap_sitectl" host security secure-runtime --help >/dev/null
for command in docker-plugins marker metadata-firewall overlays rollout-serve systemd vault-agent vault-readiness; do
    "$bootstrap_sitectl" host "$command" --help >/dev/null
done
