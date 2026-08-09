#!/usr/bin/env bash

set -euo pipefail

case "$*" in
  *mktemp\ -d\ /tmp/cloud-compose-hosted-contract.XXXXXX*)
    printf '/tmp/cloud-compose-hosted-contract.fixture123\n'
    ;;
  *install\ -m\ 0700\ /dev/stdin*)
    cat >/dev/null
    ;;
  *cloud-compose-diagnostics.sh\ state*) printf 'complete\n' ;;
  *cloud-compose-bootstrap-complete*) printf 'complete\n' ;;
  *cloud-init\ status*) printf 'cloud-init not installed\n' ;;
esac
