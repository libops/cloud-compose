#!/usr/bin/env bash

set -euo pipefail

target_ref="${SOURCE_TRUST_ROLLOUT_REF:?SOURCE_TRUST_ROLLOUT_REF is required}"
if [[ ! "$target_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ||
    "$target_ref" == -* || "$target_ref" =~ (^|/)\.\.?(/|$) ]]; then
    echo "Unsafe source-trust rollout ref: $target_ref" >&2
    exit 2
fi

git fetch -- origin "$target_ref"
git checkout --detach FETCH_HEAD
