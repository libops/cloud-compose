#!/usr/bin/env bash

set -euo pipefail

printf '<%s>\n' "$@" >>"${SITECTL_ARGV_LOG:?SITECTL_ARGV_LOG is required}"
