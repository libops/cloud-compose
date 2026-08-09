#!/usr/bin/env bash

set -euo pipefail

output="$(/usr/bin/stat "$@")"
if [[ "$*" == *"%u:"* ]]; then
  printf '0:%s\n' "${output#*:}"
else
  printf '%s\n' "$output"
fi
