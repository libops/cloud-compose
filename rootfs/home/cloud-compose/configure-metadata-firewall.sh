#!/usr/bin/env bash

set -euo pipefail

mode="${1:-full}"
case "$mode" in
  full | pre-docker)
    ;;
  *)
    echo "Unknown metadata firewall mode: $mode" >&2
    exit 2
    ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
profile_path="${CLOUD_COMPOSE_PROFILE_PATH:-$script_dir/profile.sh}"

# shellcheck disable=SC1090
source "$profile_path"

case "${CLOUD_COMPOSE_PROVIDER:-}" in
  gcp)
    ;;
  "")
    echo "CLOUD_COMPOSE_PROVIDER is required before configuring metadata isolation" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac

iptables_bin="$(command -v iptables || true)"
if [ -z "$iptables_bin" ]; then
  echo "iptables is required to isolate the GCP metadata service" >&2
  exit 1
fi

ensure_table_insert_rule() {
  local table="$1" chain="$2"
  shift 2

  if ! "$iptables_bin" -t "$table" -C "$chain" "$@" >/dev/null 2>&1; then
    "$iptables_bin" -t "$table" -I "$chain" 1 "$@"
  fi
}

ensure_insert_rule() {
  ensure_table_insert_rule filter "$@"
}

metadata_address="169.254.169.254/32"

# This Docker-independent hook is installed before docker.service on subsequent
# boots. Traffic arriving from a bridge crosses mangle/PREROUTING before Docker
# can accept it in FORWARD, closing the restart-policy window after a crash.
# Host-originated root metadata traffic does not traverse PREROUTING.
ensure_table_insert_rule mangle PREROUTING -d "$metadata_address" -j DROP
ensure_table_insert_rule mangle PREROUTING -d "$metadata_address" -p tcp --dport 53 -j ACCEPT
ensure_table_insert_rule mangle PREROUTING -d "$metadata_address" -p udp --dport 53 -j ACCEPT

# Install the Docker-independent host guard in the same early phase. Keep root
# access for key rotation while blocking unprivileged processes from the
# documented HTTP and Shielded VM HTTPS metadata endpoints. Other platform
# traffic to this address (including NTP) remains available to the OS.
ensure_insert_rule OUTPUT -m owner ! --uid-owner 0 -d "$metadata_address" -p tcp --dport 80 -j DROP
ensure_insert_rule OUTPUT -m owner ! --uid-owner 0 -d "$metadata_address" -p tcp --dport 443 -j DROP

if [ "$mode" = "pre-docker" ]; then
  exit 0
fi

if ! "$iptables_bin" -nL DOCKER-USER >/dev/null 2>&1; then
  echo "Docker did not create the DOCKER-USER chain; refusing to start without metadata isolation" >&2
  exit 1
fi

# DOCKER-USER is Docker's stable user-policy hook. The FORWARD rule is a
# fail-closed fallback if another daemon bypasses or rewrites that hook. Neither
# rule affects traffic originating from the host itself. Compute Engine also
# serves VPC and private-zone DNS from this address, so permit only DNS ahead of
# the catch-all metadata deny. Insert the deny first because -I prepends rules.
ensure_insert_rule DOCKER-USER -d "$metadata_address" -j DROP
ensure_insert_rule DOCKER-USER -d "$metadata_address" -p tcp --dport 53 -j ACCEPT
ensure_insert_rule DOCKER-USER -d "$metadata_address" -p udp --dport 53 -j ACCEPT
ensure_insert_rule FORWARD -d "$metadata_address" -j DROP
ensure_insert_rule FORWARD -d "$metadata_address" -p tcp --dport 53 -j ACCEPT
ensure_insert_rule FORWARD -d "$metadata_address" -p udp --dport 53 -j ACCEPT
