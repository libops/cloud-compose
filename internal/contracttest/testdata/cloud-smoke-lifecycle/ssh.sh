#!/usr/bin/env bash

set -euo pipefail

case "$*" in
  *cloud-compose-diagnostics.sh\ state*) printf 'complete\n' ;;
  *cloud-compose-bootstrap-complete*) printf 'complete\n' ;;
  *cloud-init\ status*) printf 'cloud-init not installed\n' ;;
esac
