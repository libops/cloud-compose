#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091
source /home/cloud-compose/profile.sh

project="${DOCKER_COMPOSE_DIR:?DOCKER_COMPOSE_DIR is required}"
repository="${DOCKER_COMPOSE_REPO:?DOCKER_COMPOSE_REPO is required}"
revision="${DOCKER_COMPOSE_BRANCH:?DOCKER_COMPOSE_BRANCH is required}"

[[ "$repository" == "https://github.com/libops/wp.git" ]] || {
    echo "Unexpected GCP upgrade fixture repository: $repository" >&2
    exit 1
}
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "GCP upgrade fixture revision must be an exact commit" >&2
    exit 1
}
[[ "$project" == "/mnt/disks/data/libops/wp.git/${revision}" ]] || {
    echo "Unexpected GCP upgrade fixture project path: $project" >&2
    exit 1
}

systemctl disable --now internal-services.timer internal-services.service 2>/dev/null || true
systemctl disable --now cloud-compose-internal-services.timer cloud-compose-internal-services.service 2>/dev/null || true

git_project() {
    git -c safe.directory="$project" -C "$project" "$@"
}

install -d -m 0755 "$project"
if [[ ! -d "$project/.git" ]]; then
    git_project init
    git_project remote add origin "$repository"
fi
git_project remote set-url origin "$repository"
git_project fetch --force --no-tags --depth=1 origin "$revision"
git_project checkout --detach "$revision"
[[ "$(git_project rev-parse HEAD)" == "$revision" ]] || {
    echo "GCP upgrade fixture checkout did not reach $revision" >&2
    exit 1
}
chown -R cloud-compose:cloud-compose "$project"
