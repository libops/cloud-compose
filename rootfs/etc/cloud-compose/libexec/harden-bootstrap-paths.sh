#!/usr/bin/env bash

set -euo pipefail

cloud_compose_home="/home/cloud-compose"

if [[ -L "$cloud_compose_home" || ! -d "$cloud_compose_home" ]]; then
    echo "Cloud Compose home is unavailable or unsafe" >&2
    exit 1
fi

# cloud-init creates the operator account before all providers finish placing
# the checked-in runtime files. Close that initial writable-home window before
# any root process sources or executes those files. Files must already be
# root-owned, regular, and unlinked before this script normalizes archive modes;
# an operator replacement therefore fails closed instead of being blessed.
chown root:root "$cloud_compose_home"
chmod 0755 "$cloud_compose_home"

require_root_owned_regular_file() {
    local path="$1"
    local metadata

    if [[ -L "$path" || ! -f "$path" ]]; then
        echo "Unsafe Cloud Compose bootstrap file: $path" >&2
        exit 1
    fi
    metadata="$(stat -c '%u:%h:%F' -- "$path")"
    if [[ "$metadata" != "0:1:regular file" ]]; then
        echo "Cloud Compose bootstrap file is not an unlinked root-owned regular file: $path" >&2
        exit 1
    fi
}

shopt -s nullglob
programs=(
    "$cloud_compose_home"/*.sh
    "$cloud_compose_home"/*.jq
    "$cloud_compose_home"/*.awk
)
shopt -u nullglob
for path in "${programs[@]}"; do
    require_root_owned_regular_file "$path"
done

for dispatcher in init up down rollout; do
    path="${cloud_compose_home}/${dispatcher}"
    if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
        echo "Unsafe Cloud Compose dispatcher: $path" >&2
        exit 1
    fi
    if [[ -f "$path" ]]; then
        require_root_owned_regular_file "$path"
    fi
done

for input in .env compose-projects.json application-env.json managed-runtime-artifacts.tsv; do
    path="${cloud_compose_home}/${input}"
    if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
        echo "Unsafe Cloud Compose input: $path" >&2
        exit 1
    fi
    if [[ -f "$path" ]]; then
        require_root_owned_regular_file "$path"
    fi
done

find "$cloud_compose_home" -mindepth 1 -maxdepth 1 -type f -name '*.sh' \
    -exec chown root:root {} + \
    -exec chmod 0755 {} +
find "$cloud_compose_home" -mindepth 1 -maxdepth 1 -type f -name '*.jq' \
    -exec chown root:root {} + \
    -exec chmod 0644 {} +
find "$cloud_compose_home" -mindepth 1 -maxdepth 1 -type f -name '*.awk' \
    -exec chown root:root {} + \
    -exec chmod 0644 {} +

for dispatcher in init up down rollout; do
    path="${cloud_compose_home}/${dispatcher}"
    if [[ -f "$path" ]]; then
        chown root:root "$path"
        chmod 0755 "$path"
    fi
done

for input in .env compose-projects.json application-env.json managed-runtime-artifacts.tsv; do
    path="${cloud_compose_home}/${input}"
    if [[ -f "$path" ]]; then
        chown root:cloud-compose "$path"
        chmod 0640 "$path"
    fi
done

if [[ -L "${cloud_compose_home}/bin" ||
    ( -e "${cloud_compose_home}/bin" && ! -d "${cloud_compose_home}/bin" ) ]]; then
    echo "Unsafe Cloud Compose command directory" >&2
    exit 1
fi
install -d -m 0755 -o root -g root "${cloud_compose_home}/bin"

home_identity="$(stat -Lc '%U:%G:%a' -- "$cloud_compose_home")"
bin_identity="$(stat -Lc '%U:%G:%a' -- "${cloud_compose_home}/bin")"
if [[ "$home_identity" != "root:root:755" || "$bin_identity" != "root:root:755" ]]; then
    echo "Cloud Compose privileged paths have unsafe ownership or modes" >&2
    exit 1
fi
