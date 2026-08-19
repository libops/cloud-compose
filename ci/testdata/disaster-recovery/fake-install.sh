#!/usr/bin/env bash

set -euo pipefail

args=()
while (($# > 0)); do
  case "$1" in
    -o | -g)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
exec /usr/bin/install "${args[@]}"
