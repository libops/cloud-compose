#!/usr/bin/env bash

set -euo pipefail

action="${1:-}"
runner="${2:-}"
[[ -f "$runner" && ! -L "$runner" ]] || {
    echo "GCP upgrade contract harness requires the checked smoke runner" >&2
    exit 2
}

# shellcheck disable=SC1090
source "$runner"

case "$action" in
    supported-cidrs)
        [[ "$#" -eq 2 ]]
        valid_direct_vpc_cidr "10.60.0.0/26"
        valid_direct_vpc_cidr "172.20.0.0/24"
        valid_direct_vpc_cidr "100.64.0.0/26"
        valid_direct_vpc_cidr "240.0.0.0/26"
        ;;
    cidr)
        [[ "$#" -eq 3 ]]
        valid_direct_vpc_cidr "$3"
        ;;
    network-ownership)
        [[ "$#" -eq 6 ]]
        validate_upgrade_network_ownership "$3" "$4" "$5" "$6"
        ;;
    write-tfvars)
        [[ "$#" -eq 3 ]]
        write_tfvars "$3" name project us-east5 us-east5-b key 192.0.2.1/32 \
            project network subnet projects/project/roles/startVM \
            projects/project/roles/suspendVM true
        ;;
    cleanup-failure)
        [[ "$#" -eq 3 ]]
        [[ -d "$3/.git" ]]
        : "${CLEANUP_LOG:?CLEANUP_LOG is required}"
        require_cmd() { :; }
        require_env() { :; }
        validate_upgrade_network() { :; }
        cleanup_calls=0
        cleanup_resources() {
            cleanup_calls=$((cleanup_calls + 1))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$CLEANUP_LOG"
            [[ "$cleanup_calls" -gt 1 ]]
        }
        run_upgrade
        ;;
    *)
        echo "usage: gcp-upgrade-smoke-contract-harness.sh supported-cidrs|cidr|network-ownership|write-tfvars|cleanup-failure RUNNER ..." >&2
        exit 2
        ;;
esac
