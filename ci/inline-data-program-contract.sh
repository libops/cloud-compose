#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root

fail() {
    echo "inline data program contract: $*" >&2
    exit 1
}

unchecked_data_program_invocation() {
    local logical_command="$1"
    local invocation_pattern

    # Match commands at a statement boundary, in a command/process
    # substitution, or after a pipeline/control operator. This intentionally
    # ignores package names, filenames, and prose that merely mention jq/awk.
    invocation_pattern='(^|[|;&]|[$][(]|<[(])[[:space:]]*(if|elif|while|until|then)?[[:space:]]*!?[[:space:]]*(command[[:space:]]+)?(jq|awk)([[:space:]]|$)'
    [[ "$logical_command" =~ $invocation_pattern ]] || return 1
    [[ ! "$logical_command" =~ (^|[[:space:]])-f([[:space:]]|$) ]]
}

# Keep the scanner itself fail-closed as its shell matching evolves.
unchecked_data_program_invocation 'value="$(jq -r '\''keys[]'\'' input.json)"' || \
    fail "scanner did not recognize inline jq"
unchecked_data_program_invocation 'awk -v key=value '\''$1 == key { print }'\'' input' || \
    fail "scanner did not recognize inline awk"
if unchecked_data_program_invocation 'jq -r -f "$program" input.json'; then
    fail "scanner rejected checked jq"
fi
if unchecked_data_program_invocation 'awk -v key=value -f "$program" input'; then
    fail "scanner rejected checked awk"
fi

while IFS= read -r -d '' script; do
    IFS= read -r shebang <"$script" || continue
    case "$shebang" in
        '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/bin/sh') ;;
        *) continue ;;
    esac
    logical_command=""
    logical_start=0
    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        if [[ -z "$logical_command" ]]; then
            logical_start="$line_number"
        fi
        if [[ "${line: -1}" == "\\" ]]; then
            logical_command+="${line::-1} "
            continue
        fi
        logical_command+="$line"
        if unchecked_data_program_invocation "$logical_command"; then
            fail "${script#$repo_root/}:$logical_start invokes jq/awk without a checked -f program"
        fi
        logical_command=""
    done <"$script"
    if [[ -n "$logical_command" ]]; then
        fail "${script#$repo_root/}:$logical_start ends with an incomplete continued command"
    fi
done < <(find "$repo_root/rootfs" -type f -print0)

echo "Inline data program contract passed"
