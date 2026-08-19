#!/usr/bin/env bash

set -euo pipefail

fixture_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$*" == "compose config --format json" ]]
jq -cn --arg root "${TEST_DATA_ROOT:?}" \
  -f "$fixture_dir/fake-compose-config.jq"
