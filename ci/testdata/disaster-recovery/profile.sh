#!/usr/bin/env bash

set -euo pipefail

export PATH="${TEST_BIN:?}:/usr/bin:/bin"

acquire_cloud_compose_lifecycle_lock() {
  printf '%s\n' "$1" >>"${LOCK_LOG:?}"
}
