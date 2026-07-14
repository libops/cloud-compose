#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$repo_root/rootfs/home/cloud-compose"
regex_call_pattern='(^|[^[:alnum:]_])(test|match|capture|scan|splits|sub|gsub)[[:space:]]*\('
nul_contains_pattern='contains[[:space:]]*\([[:space:]]*"\\u0000"[[:space:]]*\)'
failed=false

# Container-Optimized OS ships jq without Oniguruma. Its runtime scripts may
# use jq for JSON structure and types, but text validation belongs in Bash.
# The remaining sub(/.../) and gsub(/.../) calls are awk regex literals, not
# jq filters; jq has no slash-delimited regex syntax.
while IFS= read -r call; do
    if [[ "$call" == *'sub(/'* || "$call" == *'gsub(/'* ]]; then
        continue
    fi
    printf 'COS runtime contains a regex-dependent jq-style call: %s\n' "$call" >&2
    failed=true
done < <(grep -ERn --include='*.sh' "$regex_call_pattern" "$runtime_root" || true)

# jq 1.6 treats every string as containing a NUL when contains("\u0000") is
# used. COS and supported configuration-management hosts can still run jq 1.6,
# so deployed validation must inspect Unicode code points instead.
while IFS= read -r call; do
    printf 'Runtime contains jq 1.6-incompatible NUL validation: %s\n' "$call" >&2
    failed=true
done < <(grep -ERn --include='*.sh' "$nul_contains_pattern" "$runtime_root" || true)

if [[ "$failed" == "true" ]]; then
    exit 1
fi

echo "COS jq portability contract passed"
