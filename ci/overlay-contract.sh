#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
overlay_script="$repo_root/rootfs/home/cloud-compose/overlay-init.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "overlay contract: $*" >&2
  exit 1
}

volumes_root="$tmp/volumes"
lower_root="$tmp/lower"
mkdir -p "$volumes_root" "$lower_root/test-volume"
mount_marker="$tmp/mounted"
mount_log="$tmp/mount.log"
: >"$mount_log"

# Source the functions so the contract can model mount state without requiring
# CAP_SYS_ADMIN in local CI.
# shellcheck disable=SC1090
source "$overlay_script"

verify_overlay_mount() {
  if [[ "${FAKE_MOUNT_MISMATCH:-false}" == "true" ]]; then
    return 2
  fi
  [[ -e "$mount_marker" ]]
}
mount() {
  printf 'mount %s\n' "$*" >>"$mount_log"
  : >"$mount_marker"
}
umount() {
  printf 'umount %s\n' "$*" >>"$mount_log"
  rm -f -- "$mount_marker"
}

export CLOUD_COMPOSE_VOLUMES_ROOT="$volumes_root"
export CLOUD_COMPOSE_OVERLAY_LOWER_ROOT="$lower_root"

if main '../escape' false >/dev/null 2>&1; then
  fail "path-traversing volume name was accepted"
fi
if main test-volume maybe >/dev/null 2>&1; then
  fail "ambiguous reset flag was accepted"
fi

main test-volume false
[[ -e "$mount_marker" ]] || fail "overlay was not mounted"
upper="$volumes_root/.overlay/test-volume/upper"
work="$volumes_root/.overlay/test-volume/work"
printf 'keep\n' >"$upper/kept"
printf 'keep\n' >"$work/kept"
: >"$mount_log"

# Literal false must be idempotent and must not clear writable state.
main test-volume false
[[ -e "$upper/kept" && -e "$work/kept" ]] || fail "false reset flag cleared overlay state"
[[ ! -s "$mount_log" ]] || fail "matching mounted overlay was remounted"

# Explicit reset unmounts, clears both upper and work (including dotfiles), and
# mounts the expected overlay again.
printf 'hidden\n' >"$upper/.hidden"
main test-volume true
[[ ! -e "$upper/kept" && ! -e "$upper/.hidden" && ! -e "$work/kept" ]] || \
  fail "explicit reset retained writable overlay state"
grep -Fq 'umount ' "$mount_log" || fail "explicit reset did not unmount"
grep -Fq 'mount -t overlay overlay' "$mount_log" || fail "explicit reset did not remount"

FAKE_MOUNT_MISMATCH=true
if main test-volume false >/dev/null 2>&1; then
  fail "unexpected existing mount was accepted"
fi
FAKE_MOUNT_MISMATCH=false

rm -f -- "$mount_marker"
outside="$tmp/outside"
mkdir -p "$outside"
rm -rf -- "$volumes_root/.overlay"
ln -s "$outside" "$volumes_root/.overlay"
if main test-volume false >/dev/null 2>&1; then
  fail "symbolic-link overlay state boundary was accepted"
fi
[[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]] || \
  fail "symbolic-link overlay state boundary was mutated before rejection"

echo "Overlay contract passed"
