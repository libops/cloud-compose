#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"

# shellcheck disable=SC1090
source "$profile_path"

case "${CLOUD_COMPOSE_PROVIDER:-}" in
  gcp)
    ;;
  "")
    echo "CLOUD_COMPOSE_PROVIDER is required for service-account key rotation" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac

case "${LIBOPS_INTERNAL_SERVICES_ENABLED:-false}" in
  true) bash "$script_dir/rotate-keys-internal.sh" ;;
  false) ;;
  *)
    echo "LIBOPS_INTERNAL_SERVICES_ENABLED must be true or false" >&2
    exit 2
    ;;
esac

# The app wrapper is also the fail-closed stale-credential check when managed
# file credentials are disabled, so run it in both states.
bash "$script_dir/rotate-keys-app.sh"
