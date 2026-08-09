#!/usr/bin/env bash

set -euo pipefail

if [[ "${0##*/}" == "sitectl" ]]; then
    : "${SITECTL_ARGV_LOG:?SITECTL_ARGV_LOG is required}"
    {
        printf '%s' "${1:-}"
        shift || true
        for argument in "$@"; do
            printf '\t%s' "$argument"
        done
        printf '\n'
    } >>"$SITECTL_ARGV_LOG"
    exit 0
fi

lifecycle_program="${1:-/home/cloud-compose/default-lifecycle.sh}"
verify_args_program="${2:-/etc/cloud-compose/jq/sitectl-verify-args.jq}"
if [[ ! -f "$lifecycle_program" ]]; then
    echo "lifecycle program contract: missing $lifecycle_program" >&2
    exit 1
fi

contract_dir="$(mktemp -d "${TMPDIR:-/tmp}/cloud-compose-lifecycle-program.XXXXXX")"
trap 'rm -rf -- "$contract_dir"' EXIT

contract_program="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
ln -s -- "$contract_program" "$contract_dir/sitectl"
argv_log="$contract_dir/sitectl.argv"
target_ref="refs/pull/123/head"
commit_sha="0123456789abcdef0123456789abcdef01234567"
context="lifecycle-contract"

env -u SITECTL_EXECUTABLE \
    PATH="$contract_dir:/usr/bin:/bin" \
    SITECTL_ARGV_LOG="$argv_log" \
    SITECTL_CONTEXT_NAME="$context" \
    SITECTL_ENVIRONMENT=production \
    GIT_COMMIT_SHA="$commit_sha" \
    GIT_REF="$target_ref" \
    GIT_BRANCH=ignored-branch \
    bash "$lifecycle_program" rollout

expected_ref_call="deploy"$'\t'"--context"$'\t'"$context"$'\t'"--ref"$'\t'"$commit_sha"
grep -Fxq -- "$expected_ref_call" "$argv_log" || {
    echo "lifecycle program contract: GIT_COMMIT_SHA did not take precedence for sitectl deploy --ref" >&2
    exit 1
}
if grep -Fq -- $'deploy\t--context\tlifecycle-contract\t--skip-git' "$argv_log"; then
    echo "lifecycle program contract: supplied GIT_REF incorrectly selected --skip-git" >&2
    exit 1
fi

: >"$argv_log"
env -u GIT_COMMIT_SHA -u SITECTL_EXECUTABLE \
    PATH="$contract_dir:/usr/bin:/bin" \
    SITECTL_ARGV_LOG="$argv_log" \
    SITECTL_CONTEXT_NAME="$context" \
    SITECTL_ENVIRONMENT=production \
    GIT_REF="$target_ref" \
    GIT_BRANCH=ignored-branch \
    bash "$lifecycle_program" rollout

expected_ref_call="deploy"$'\t'"--context"$'\t'"$context"$'\t'"--ref"$'\t'"$target_ref"
grep -Fxq -- "$expected_ref_call" "$argv_log" || {
    echo "lifecycle program contract: GIT_REF did not reach sitectl deploy --ref" >&2
    exit 1
}

: >"$argv_log"
if env -u SITECTL_EXECUTABLE \
    PATH="$contract_dir:/usr/bin:/bin" \
    SITECTL_ARGV_LOG="$argv_log" \
    SITECTL_CONTEXT_NAME="$context" \
    SITECTL_ENVIRONMENT=production \
    GIT_COMMIT_SHA=not-a-commit \
    GIT_REF="$target_ref" \
    bash "$lifecycle_program" rollout; then
    echo "lifecycle program contract: malformed GIT_COMMIT_SHA was accepted" >&2
    exit 1
fi
if [[ -s "$argv_log" ]]; then
    echo "lifecycle program contract: malformed GIT_COMMIT_SHA reached sitectl" >&2
    exit 1
fi

: >"$argv_log"
env -u GIT_COMMIT_SHA -u GIT_REF -u GIT_BRANCH -u SITECTL_EXECUTABLE \
    PATH="$contract_dir:/usr/bin:/bin" \
    SITECTL_ARGV_LOG="$argv_log" \
    SITECTL_CONTEXT_NAME="$context" \
    SITECTL_ENVIRONMENT=production \
    bash "$lifecycle_program" rollout

expected_skip_call="deploy"$'\t'"--context"$'\t'"$context"$'\t'"--skip-git"
grep -Fxq -- "$expected_skip_call" "$argv_log" || {
    echo "lifecycle program contract: rollout without a ref did not select --skip-git" >&2
    exit 1
}

: >"$argv_log"
env -u SITECTL_EXECUTABLE \
    PATH="$contract_dir:/usr/bin:/bin" \
    SITECTL_ARGV_LOG="$argv_log" \
    SITECTL_CONTEXT_NAME="$context" \
    SITECTL_ENVIRONMENT=preview \
    SITECTL_VERIFY_ARGS_JSON='["--label","value with spaces",""]' \
    CLOUD_COMPOSE_SITECTL_VERIFY_ARGS_PROGRAM="$verify_args_program" \
    bash "$lifecycle_program" up

expected_verify_call="verify"$'\t'"--context"$'\t'"$context"$'\t'"--label"$'\t'"value with spaces"$'\t'
grep -Fxq -- "$expected_verify_call" "$argv_log" || {
    echo "lifecycle program contract: verify argument boundaries were not preserved" >&2
    exit 1
}

echo "Lifecycle program contract passed"
