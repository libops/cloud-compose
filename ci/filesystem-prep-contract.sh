#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prep_script="$repo_root/rootfs/home/cloud-compose/prepare-filesystem.sh"
persist_script="$repo_root/rootfs/home/cloud-compose/persist-filesystems.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    echo "filesystem preparation contract: $*" >&2
    exit 1
}

mkdir -p "$tmp/bin" "$tmp/dev" "$tmp/mount" "$tmp/systemd"
device="$tmp/dev/data"
: >"$device"
calls="$tmp/calls"
fresh_marker="$tmp/mount/.cloud-compose/fresh-filesystem"
label_state="$tmp/label-state"
: >"$label_state"

cat >"$tmp/bin/readlink" <<'EOF'
#!/usr/bin/env bash
case "${!#}" in
  /dev/disk/by-id/*) printf '%s\n' "${FAKE_DEVICE:-}" ;;
  *) printf '%s\n' "${FAKE_RESOLVED_MOUNT_SOURCE:-${!#}}" ;;
esac
EOF
cat >"$tmp/bin/blkid" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_BLKID_STATUS:-0}" == "0" ]]; then
    printf '%s\n' "${FAKE_FILESYSTEM_TYPE:-ext4}"
fi
exit "${FAKE_BLKID_STATUS:-0}"
EOF
cat >"$tmp/bin/fsck.ext4" <<'EOF'
#!/usr/bin/env bash
printf 'fsck\n' >>"${CALLS:?}"
printf 'fsck-args %s\n' "$*" >>"${CALLS:?}"
exit "${FAKE_FSCK_STATUS:-0}"
EOF
cat >"$tmp/bin/mkfs.ext4" <<'EOF'
#!/usr/bin/env bash
printf 'mkfs\n' >>"${CALLS:?}"
label=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-L" ]]; then
    label="$argument"
  fi
  previous="$argument"
done
printf '%s' "$label" >"${FAKE_LABEL_STATE:?}"
EOF
cat >"$tmp/bin/e2label" <<'EOF'
#!/usr/bin/env bash
case "$#" in
  1)
    cat "${FAKE_LABEL_STATE:?}"
    ;;
  2)
    printf '%s' "$2" >"${FAKE_LABEL_STATE:?}"
    printf 'label-set %s\n' "$2" >>"${CALLS:?}"
    ;;
  *)
    exit 2
    ;;
esac
EOF
cat >"$tmp/bin/resize2fs" <<'EOF'
#!/usr/bin/env bash
printf 'resize\n' >>"${CALLS:?}"
exit "${FAKE_RESIZE_STATUS:-0}"
EOF
cat >"$tmp/bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
target="${!#}"
active_targets="${FAKE_DEVICE_MOUNT_TARGETS:-${FAKE_DEVICE_MOUNT_TARGET:-}}"
if [[ -s "${FAKE_MOUNT_STATE:?}" ]]; then
  active_targets="$(<"$FAKE_MOUNT_STATE")"
fi
if [[ "$target" == "${MOUNT_PATH:?}" && "${FAKE_MOUNTED:-1}" == "0" ]]; then
  exit 0
fi
while IFS= read -r active_target; do
  [[ -n "$active_target" && "$target" == "$active_target" ]] && exit 0
done <<<"$active_targets"
exit 1
EOF
cat >"$tmp/bin/mount" <<'EOF'
#!/usr/bin/env bash
printf 'mount\n' >>"${CALLS:?}"
status="${FAKE_MOUNT_STATUS:-0}"
if [[ "${1:-}" == "--move" && "$status" == "0" ]]; then
  printf '%s\n' "${3:?}" >"${FAKE_MOUNT_STATE:?}"
fi
exit "$status"
EOF
cat >"$tmp/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${!#}"
format=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-c" ]]; then
    format="$argument"
  fi
  previous="$argument"
done
case "$target:$format" in
  "${MOUNT_PATH:?}:%u:%g:%a")
    printf '%s\n' "${FAKE_FRESH_ROOT_IDENTITY:-0:0:755}"
    ;;
  "$MOUNT_PATH/.cloud-compose:%u:%g:%a")
    printf '%s\n' "${FAKE_MARKER_DIR_IDENTITY:-0:0:700}"
    ;;
  "$MOUNT_PATH/.cloud-compose/fresh-filesystem:%u:%g:%a:%h")
    printf 'marker\n' >>"${CALLS:?}"
    printf '%s\n' "${FAKE_MARKER_IDENTITY:-0:0:600:1}"
    ;;
  "$MOUNT_PATH/lost+found:%u:%g:%a")
    printf '%s\n' "${FAKE_LOST_FOUND_IDENTITY:-0:0:700}"
    ;;
  *)
    exec /usr/bin/stat "$@"
    ;;
esac
EOF
cat >"$tmp/bin/sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -s "${FAKE_SYNC_COUNT:?}" ]]; then
  count="$(<"$FAKE_SYNC_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_SYNC_COUNT"
printf 'sync\n' >>"${CALLS:?}"
if [[ -n "${FAKE_SYNC_FAIL_AT:-}" && "$count" == "$FAKE_SYNC_FAIL_AT" ]]; then
  exit 1
fi
EOF
cat >"$tmp/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'findmnt\n' >>"${CALLS:?}"
active_targets="${FAKE_DEVICE_MOUNT_TARGETS:-${FAKE_DEVICE_MOUNT_TARGET:-}}"
if [[ -s "${FAKE_MOUNT_STATE:?}" ]]; then
  active_targets="$(<"$FAKE_MOUNT_STATE")"
fi
if [[ "${FAKE_MOUNTED:-1}" == "0" ]]; then
  active_targets="${MOUNT_PATH:?}${active_targets:+$'\n'}${active_targets}"
fi
case " $* " in
  *" -o SOURCE --target "*)
    target="${!#}"
    while IFS= read -r active_target; do
      if [[ -n "$active_target" && "$target" == "$active_target" ]]; then
        printf '%s\n' "${FAKE_MOUNT_SOURCE:-${FAKE_DEVICE:?}}"
        exit 0
      fi
    done <<<"$active_targets"
    exit 1
    ;;
  *" -o TARGET --source "*)
    count=0
    if [[ -s "${FAKE_FINDMNT_COUNT:?}" ]]; then
      count="$(<"$FAKE_FINDMNT_COUNT")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_FINDMNT_COUNT"
    if [[ -n "${FAKE_LATE_MOUNT_TARGET:-}" && "$count" -gt "${FAKE_LATE_MOUNT_AFTER:-1}" ]]; then
      active_targets="${active_targets}${active_targets:+$'\n'}${FAKE_LATE_MOUNT_TARGET}"
    fi
    if [[ -n "$active_targets" ]]; then
      printf '%s\n' "$active_targets"
      exit 0
    fi
    exit 1
    ;;
esac
exit 2
EOF
cat >"$tmp/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
printf 'udevadm\n' >>"${CALLS:?}"
if [[ -n "${FAKE_UDEV_MOUNT_TARGET:-}" ]]; then
  printf '%s\n' "$FAKE_UDEV_MOUNT_TARGET" >"${FAKE_MOUNT_STATE:?}"
fi
exit "${FAKE_UDEV_STATUS:-0}"
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${CALLS:?}"
if [[ "${1:-}" == "start" && -n "${FAKE_SYSTEMD_MOUNT_TARGET:-}" ]]; then
  printf '%s\n' "$FAKE_SYSTEMD_MOUNT_TARGET" >"${FAKE_MOUNT_STATE:?}"
fi
exit "${FAKE_SYSTEMCTL_STATUS:-0}"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep\n' >>"${CALLS:?}"
EOF
chmod +x "$tmp/bin/"*

run_prep() {
    local configured_device="${TEST_FAKE_DEVICE-$device}"
    : >"$calls"
    rm -f -- "$tmp/mount-state"
    rm -f -- "$tmp/findmnt-count"
    printf '0\n' >"$tmp/sync-count"
    FAKE_DEVICE="$configured_device" FAKE_MOUNT_STATE="$tmp/mount-state" \
        FAKE_FINDMNT_COUNT="$tmp/findmnt-count" FAKE_LABEL_STATE="$label_state" \
        FAKE_SYNC_COUNT="$tmp/sync-count" CALLS="$calls" \
        PATH="$tmp/bin:/usr/bin:/bin" PREP_SCRIPT="$prep_script" MOUNT_PATH="$tmp/mount" \
        CLOUD_COMPOSE_SYSTEMD_DIR="$tmp/systemd" \
        DEVICE_PATH="${TEST_DEVICE_PATH:-/dev/disk/by-id/test-data}" \
        PREP_EXTRA_ARG="${TEST_PREP_EXTRA_ARG:-}" \
        PREP_MARKER_IDENTITY="${TEST_PREP_MARKER_IDENTITY:-}" \
        bash --noprofile --norc -c '
            source "$PREP_SCRIPT"
            if [[ -n "${TEST_PROVIDER_MOUNT:-}" ]]; then
                digitalocean_automatic_mount() { printf "%s\n" "$TEST_PROVIDER_MOUNT"; }
            fi
            is_block_device() { return 0; }
            prep_args=("$DEVICE_PATH" "$MOUNT_PATH")
            if [[ -n "$PREP_EXTRA_ARG" ]]; then
                prep_args+=("$PREP_EXTRA_ARG")
            fi
            if [[ -n "$PREP_MARKER_IDENTITY" ]]; then
                prep_args+=("$PREP_MARKER_IDENTITY")
            fi
            main "${prep_args[@]}"
        '
}

for status in 0 1; do
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS="$status" run_prep
    grep -Fxq fsck "$calls" || fail "fsck status $status did not check the existing filesystem"
    grep -Fxq "fsck-args -f -p -- $device" "$calls" ||
        fail "fsck status $status did not force a complete offline ext4 check"
    grep -Fxq resize "$calls" || fail "fsck status $status did not grow the existing filesystem"
    grep -Fxq mount "$calls" || fail "fsck status $status did not mount the usable filesystem"
    if grep -Fxq mkfs "$calls"; then
        fail "fsck status $status reformatted an existing filesystem"
    fi
done

for status in 2 3 4 8 16 32 128; do
    if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS="$status" run_prep >/dev/null 2>&1; then
        fail "fsck failure status $status was accepted"
    fi
    grep -Fxq fsck "$calls" || fail "fsck failure status $status was not observed"
    if grep -Eq '^(mkfs|mount|resize)$' "$calls"; then
        fail "fsck failure status $status reformatted or mounted the existing filesystem"
    fi
done

FAKE_BLKID_STATUS=2 FAKE_FSCK_STATUS=0 run_prep
grep -Fxq mkfs "$calls" || fail "an unsigned device was not formatted"
grep -Fxq mount "$calls" || fail "a newly formatted device was not mounted"
if grep -Fxq fsck "$calls"; then
    fail "an unsigned device was checked before its first format"
fi
if grep -Fxq resize "$calls"; then
    fail "a newly formatted whole-disk filesystem was resized redundantly"
fi

rm -rf -- "$tmp/mount/.cloud-compose" "$tmp/mount/lost+found"
if TEST_PREP_EXTRA_ARG=--unsupported FAKE_BLKID_STATUS=2 run_prep >/dev/null 2>&1; then
    fail "an unsupported filesystem preparation option was accepted"
fi
[[ ! -e "$fresh_marker" ]] ||
    fail "an unsupported filesystem preparation option published a fresh-filesystem marker"
if [[ -s "$calls" ]]; then
    fail "an unsupported filesystem preparation option mutated the filesystem"
fi

TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 run_prep
[[ ! -e "$fresh_marker" ]] ||
    fail "an existing filesystem was marked as freshly formatted"
if grep -Fxq marker "$calls"; then
    fail "an existing filesystem invoked fresh-filesystem marker publication"
fi

if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=2 FAKE_MOUNT_STATUS=1 run_prep >/dev/null 2>&1; then
    fail "a failed first mount was accepted"
fi
grep -Fxq mkfs "$calls" || fail "mount failure coverage did not format the unsigned device"
grep -Fxq mount "$calls" || fail "mount failure coverage did not attempt the first mount"
[[ ! -e "$fresh_marker" ]] ||
    fail "a fresh-filesystem marker was published before the first mount succeeded"
if grep -Fxq marker "$calls"; then
    fail "a failed first mount invoked fresh-filesystem marker publication"
fi
[[ "$(<"$label_state")" == "cc-fresh-pending" ]] ||
    fail "a failed first mount did not retain durable fresh-filesystem intent"

printf 'not-pristine\n' >"$tmp/mount/application-data"
if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    run_prep >/dev/null 2>&1; then
    fail "a pending ext4 label authorized a populated filesystem"
fi
[[ ! -e "$fresh_marker" && "$(<"$label_state")" == "cc-fresh-pending" ]] ||
    fail "populated-filesystem rejection changed fresh-marker authority"
rm -f -- "$tmp/mount/application-data"

mkdir -p "$tmp/mount/lost+found"
chmod 0700 "$tmp/mount/lost+found"
printf 'recovered-data\n' >"$tmp/mount/lost+found/orphan"
if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    run_prep >/dev/null 2>&1; then
    fail "a pending ext4 label accepted data inside lost+found"
fi
rm -f -- "$tmp/mount/lost+found/orphan"
if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_LOST_FOUND_IDENTITY=1000:1000:700 run_prep >/dev/null 2>&1; then
    fail "a pending ext4 label accepted an untrusted lost+found directory"
fi

if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_SYNC_FAIL_AT=1 run_prep >/dev/null 2>&1; then
    fail "fresh marker publication accepted a failed durability barrier"
fi
[[ -f "$fresh_marker" && "$(<"$label_state")" == "cc-fresh-pending" ]] ||
    fail "the pending label was cleared before marker publication became durable"
if grep -Eq '^label-set ' "$calls"; then
    fail "a failed marker durability barrier cleared the pending label"
fi

fresh_marker_inode="$(stat -c '%d:%i' "$fresh_marker")"
printf 'v1:gcp-disk-id:111111111111111111\n' >"$fresh_marker"
if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    TEST_PREP_MARKER_IDENTITY=v1:gcp-disk-id:222222222222222222 \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    run_prep >/dev/null 2>&1; then
    fail "a pending label accepted a marker from another disk incarnation"
fi
[[ "$(<"$label_state")" == "cc-fresh-pending" ]] ||
    fail "a mismatched disk-incarnation marker cleared the pending label"
if grep -Eq '^label-set ' "$calls"; then
    fail "a mismatched disk-incarnation marker cleared its pending label"
fi
printf 'fresh\n' >"$fresh_marker"
if TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_MARKER_IDENTITY=1000:1000:600:1 run_prep >/dev/null 2>&1; then
    fail "a pending label accepted an untrusted existing marker"
fi
[[ "$(<"$label_state")" == "cc-fresh-pending" ]] ||
    fail "an untrusted existing marker cleared the pending label"

TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 run_prep
[[ -f "$fresh_marker" ]] ||
    fail "a retry did not recover fresh-filesystem marker publication"
if grep -Fxq mkfs "$calls"; then
    fail "fresh-filesystem marker recovery reformatted the existing filesystem"
fi
[[ ! -s "$label_state" ]] ||
    fail "successful fresh-filesystem marker publication retained the pending label"
[[ "$(stat -c '%a' "$tmp/mount/.cloud-compose")" == "700" ]] ||
    fail "the fresh-filesystem marker directory was not mode 0700"
[[ "$(stat -c '%a' "$fresh_marker")" == "600" ]] ||
    fail "the fresh-filesystem marker was not mode 0600"
[[ "$(<"$fresh_marker")" == "fresh" ]] ||
    fail "generic fresh-filesystem marker did not preserve its exact payload"
mount_line="$(grep -nFx mount "$calls" | cut -d: -f1)"
marker_line="$(grep -nFx marker "$calls" | cut -d: -f1)"
label_clear_line="$(grep -nE '^label-set $' "$calls" | cut -d: -f1)"
mapfile -t sync_lines < <(grep -nFx sync "$calls" | cut -d: -f1)
[[ -n "$mount_line" && -n "$marker_line" && -n "$label_clear_line" &&
    "${#sync_lines[@]}" == "2" &&
    "$mount_line" -lt "$marker_line" &&
    "$marker_line" -lt "${sync_lines[0]}" &&
    "${sync_lines[0]}" -lt "$label_clear_line" &&
    "$label_clear_line" -lt "${sync_lines[1]}" ]] ||
    fail "fresh authority ordering is not mount, marker, sync, label clear, sync"
[[ "$(stat -c '%d:%i' "$fresh_marker")" == "$fresh_marker_inode" ]] ||
    fail "fresh marker recovery replaced an already trusted marker"

TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 run_prep
[[ -f "$fresh_marker" && "$(stat -c '%d:%i' "$fresh_marker")" == "$fresh_marker_inode" ]] ||
    fail "an existing fresh-filesystem marker was not preserved on a same-boot rerun"
if grep -Fxq marker "$calls"; then
    fail "a same-boot rerun republished the fresh-filesystem marker"
fi

rm -rf -- "$tmp/mount/.cloud-compose" "$tmp/mount/lost+found"
printf 'cc-fresh-pending' >"$label_state"
TEST_PREP_EXTRA_ARG=--publish-fresh-marker \
    TEST_PREP_MARKER_IDENTITY=v1:gcp-disk-id:987654321012345678 \
    FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 run_prep
[[ "$(<"$fresh_marker")" == "v1:gcp-disk-id:987654321012345678" ]] ||
    fail "GCP marker publication did not bind the exact data-disk identity"
[[ ! -s "$label_state" ]] ||
    fail "exact GCP disk identity did not complete pending marker publication"
rm -rf -- "$tmp/mount/.cloud-compose" "$tmp/mount/lost+found"

if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=xfs FAKE_FSCK_STATUS=0 run_prep >/dev/null 2>&1; then
    fail "a non-ext4 filesystem was accepted"
fi
if grep -Eq '^(mkfs|mount|resize)$' "$calls"; then
    fail "a non-ext4 filesystem was reformatted or mounted as ext4"
fi

for status in 1 3 4; do
    if FAKE_BLKID_STATUS="$status" FAKE_FSCK_STATUS=0 run_prep >/dev/null 2>&1; then
        fail "blkid failure status $status was accepted"
    fi
    if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
        fail "blkid failure status $status mutated the device"
    fi
done

FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
FAKE_MOUNTED=0 FAKE_MOUNT_SOURCE=/dev/correct FAKE_RESOLVED_MOUNT_SOURCE="$device" run_prep
if grep -Fxq mount "$calls"; then
    fail "an already-correct mount was mounted again"
fi
if grep -Fxq fsck "$calls"; then
    fail "an already-mounted filesystem was checked offline"
fi
grep -Fxq resize "$calls" || fail "an already-mounted filesystem was not grown online"

if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_MOUNTED=0 FAKE_MOUNT_SOURCE=/dev/wrong FAKE_RESOLVED_MOUNT_SOURCE=/dev/wrong \
    run_prep >/dev/null 2>&1; then
    fail "an existing mount from the wrong device was accepted"
fi
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "wrong-device mount detection mutated the filesystem"
fi

expected_do_mount="$(
    # shellcheck source=../rootfs/home/cloud-compose/prepare-filesystem.sh
    source "$prep_script"
    digitalocean_automatic_mount \
        /dev/disk/by-id/scsi-0DO_Volume_cc-do-isle-123-data
)"
[[ "$expected_do_mount" == "/mnt/cc_do_isle_123_data" ]] ||
    fail "DigitalOcean automatic mount naming was not derived correctly"
if (
    # shellcheck source=../rootfs/home/cloud-compose/prepare-filesystem.sh
    source "$prep_script"
    digitalocean_automatic_mount /dev/disk/by-id/scsi-0DO_Volume_bad/name
) >/dev/null 2>&1; then
    fail "an unsafe DigitalOcean volume name was accepted"
fi

provider_mount="$tmp/provider-owned-mount"
mkdir -p "$provider_mount"
FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_DEVICE_MOUNT_TARGET="$provider_mount" TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-isle-data run_prep
grep -Fxq mount "$calls" || fail "the provider-owned mount was not moved"
grep -Fxq resize "$calls" || fail "the moved filesystem was not grown online"
if grep -Eq '^(fsck|mkfs)$' "$calls"; then
    fail "the mounted provider filesystem was checked or formatted"
fi
[[ "$(<"$tmp/mount-state")" == "$tmp/mount" ]] ||
    fail "the provider-owned mount was not moved to the requested target"

# Device discovery must not race DigitalOcean's udev automount. Model the
# provider mount appearing only when udevadm settle runs; an offline fsck of
# this mounted filesystem would reproduce the hosted failure.
mkdir -p "$provider_mount"
FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=8 \
    FAKE_UDEV_MOUNT_TARGET="$provider_mount" TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-race-data run_prep
[[ "$(sed -n '1p' "$calls")" == "udevadm" ]] ||
    fail "DigitalOcean mount inspection did not wait for udev completion"
if grep -Eq '^(fsck|mkfs)$' "$calls"; then
    fail "a provider mount that completed during udev settle was checked or formatted offline"
fi

# When udev has generated a unit but not completed its systemd job, bootstrap
# must synchronously finish the validated provider unit before inspecting the
# mount set.
systemd_device=/dev/disk/by-id/scsi-0DO_Volume_cc-do-systemd-data
systemd_mount="$tmp/systemd-provider-mount"
systemd_unit="$tmp/systemd/mnt-$(basename -- "$systemd_mount").mount"
mkdir -p "$systemd_mount"
printf '[Mount]\nWhat=%s\nWhere=%s\n' "$systemd_device" "$systemd_mount" >"$systemd_unit"
FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=8 \
    FAKE_SYSTEMD_MOUNT_TARGET="$systemd_mount" TEST_PROVIDER_MOUNT="$systemd_mount" \
    TEST_DEVICE_PATH="$systemd_device" run_prep
grep -Fq "systemctl start -- $(basename -- "$systemd_unit")" "$calls" ||
    fail "DigitalOcean's pending systemd automount was not completed"
if grep -Eq '^(fsck|mkfs)$' "$calls"; then
    fail "a provider mount completed by systemd was checked or formatted offline"
fi
rm -f -- "$systemd_unit"

# A desired mount and a stale provider alias for the same device is corruption-
# prone. Detect the complete mount set and stop without moving, checking, or
# resizing either alias.
if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 \
    FAKE_DEVICE_MOUNT_TARGETS="$tmp/mount"$'\n'"$provider_mount" \
    TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-dual-data \
    run_prep >/dev/null 2>&1; then
    fail "duplicate desired and provider mount aliases were accepted"
fi
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "duplicate mount detection mutated the filesystem"
fi

# A mount may appear after the first inspection even when it is not managed by
# the DigitalOcean unit. Recheck at the mutation boundary and leave the device
# untouched if any actor mounted it late.
late_mount="$tmp/late-external-mount"
if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_LATE_MOUNT_TARGET="$late_mount" FAKE_LATE_MOUNT_AFTER=1 \
    run_prep >/dev/null 2>&1; then
    fail "a mount that appeared immediately before offline fsck was accepted"
fi
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "late mount detection mutated the filesystem"
fi

unexpected_mount="$tmp/operator-mount"
mkdir -p "$unexpected_mount"
if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 \
    FAKE_DEVICE_MOUNT_TARGET="$unexpected_mount" TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-isle-data \
    run_prep >/dev/null 2>&1; then
    fail "an unexpected mounted-device target was relocated"
fi
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "unexpected mounted-device detection mutated the filesystem"
fi

mkdir -p "$provider_mount"
if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 \
    FAKE_DEVICE_MOUNT_TARGET="$provider_mount" TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/provider-data FAKE_MOUNT_SOURCE=/dev/wrong \
    FAKE_RESOLVED_MOUNT_SOURCE=/dev/wrong run_prep >/dev/null 2>&1; then
    fail "a provider mount from the wrong block device was accepted"
fi
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "wrong provider mount source detection mutated the filesystem"
fi

mkdir -p "$provider_mount"
printf 'operator data\n' >"$tmp/mount/operator-file"
if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 \
    FAKE_DEVICE_MOUNT_TARGET="$provider_mount" TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-isle-data \
    run_prep >/dev/null 2>&1; then
    fail "a provider mount hid a non-empty target directory"
fi
rm -f -- "$tmp/mount/operator-file"
if grep -Eq '^(fsck|mkfs|mount|resize)$' "$calls"; then
    fail "non-empty target detection mutated the filesystem"
fi

mkdir -p "$provider_mount"
if FAKE_BLKID_STATUS=2 FAKE_DEVICE_MOUNT_TARGET="$provider_mount" \
    TEST_PROVIDER_MOUNT="$provider_mount" \
    TEST_DEVICE_PATH=/dev/disk/by-id/scsi-0DO_Volume_cc-do-isle-data \
    run_prep >/dev/null 2>&1; then
    fail "a mounted provider device without a filesystem signature was accepted"
fi
if grep -Eq '^(fsck|mkfs)$' "$calls"; then
    fail "a mounted unsigned provider device was checked or formatted"
fi

if FAKE_BLKID_STATUS=0 FAKE_FILESYSTEM_TYPE=ext4 FAKE_FSCK_STATUS=0 \
    FAKE_RESIZE_STATUS=1 run_prep >/dev/null 2>&1; then
    fail "a failed ext4 resize was accepted"
fi
grep -Fxq resize "$calls" || fail "resize failure path did not invoke resize2fs"
if grep -Fxq mount "$calls"; then
    fail "filesystem was mounted after resize2fs failed"
fi

if TEST_FAKE_DEVICE='' FILESYSTEM_DEVICE_WAIT_SECONDS=3 run_prep >/dev/null 2>&1; then
    fail "missing by-id device was accepted"
fi
[[ "$(grep -c '^sleep$' "$calls")" == 2 ]] || fail "device wait was not bounded to the configured deadline"

if grep -Eq 'fsck[^\n]*\|\|[^\n]*mkfs|fsck[^\n]*mkfs' "$repo_root/templates/cloud-init.yml"; then
    fail "GCP cloud-init still formats after an fsck failure"
fi
grep -Fq 'FILESYSTEM_PREP_SCRIPT_B64' "$repo_root/templates/cloud-init.yml" || \
    fail "GCP cloud-init does not bootstrap the tested filesystem helper"
grep -Fq 'bash "$filesystem_prep" /dev/disk/by-id/google-data /mnt/disks/data \' \
    "$repo_root/templates/cloud-init.yml" ||
    fail "GCP cloud-init does not request a fresh marker for the data filesystem"
grep -Fq -- '--publish-fresh-marker ${jsonencode(FRESH_FILESYSTEM_IDENTITY)}' \
    "$repo_root/templates/cloud-init.yml" ||
    fail "GCP cloud-init does not bind the marker to the rendered data-disk identity"
grep -Fq 'bash "$filesystem_prep" '\''${DATA_DEVICE}'\'' /mnt/disks/data --publish-fresh-marker' \
    "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml" ||
    fail "Linux VM cloud-init does not request a fresh marker for the data filesystem"
grep -Fq 'bash /run/cloud-compose-prepare-filesystem /dev/disk/by-id/google-docker-volumes /mnt/disks/volumes' \
    "$repo_root/templates/cloud-init.yml" ||
    fail "GCP cloud-init does not prepare the volumes filesystem without a fresh marker"
grep -Fq 'bash "$filesystem_prep" '\''${VOLUMES_DEVICE}'\'' /mnt/disks/volumes' \
    "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml" ||
    fail "Linux VM cloud-init does not prepare the volumes filesystem without a fresh marker"
grep -Fq '(umask 077 && mkdir -- "$marker_dir")' "$prep_script" ||
    fail "the fresh-filesystem marker directory is not created privately"
grep -Fq "(umask 077 && printf '%s\\n' \"\$expected_identity\" >\"\$marker\")" "$prep_script" ||
    fail "the fresh-filesystem marker is not created privately"
grep -Fq 'marker_root_identity="$(stat -c '\''%u:%g:%a'\'' -- "$mount_path")"' "$prep_script" ||
    fail "marker recovery does not verify a root-owned pristine filesystem root"
grep -Fq '! -name lost+found -print -quit' "$prep_script" ||
    fail "marker recovery does not reject data outside lost+found"
grep -Fq -- '-L "$fresh_filesystem_pending_label" -- "$device"' "$prep_script" ||
    fail "new data filesystems do not persist pending marker intent in their ext4 label"
grep -Fq 'e2label "$device" ""' "$prep_script" ||
    fail "fresh-filesystem pending intent is not cleared after marker publication"
if grep -Eq '^[[:space:]]*"?\$filesystem_(prep|persist)"?[[:space:]]' \
    "$repo_root/templates/cloud-init.yml" "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml"; then
    fail "cloud-init directly executes a temporary helper from potentially noexec /run"
fi
for cloud_init_template in \
    "$repo_root/templates/cloud-init.yml" \
    "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml"; do
    [[ "$(grep -Fc -- '--publish-fresh-marker' "$cloud_init_template")" == "1" ]] ||
        fail "cloud-init must publish a fresh marker for the data filesystem only"
    grep -Fq 'chown root:cloud-compose /mnt/disks/data' "$cloud_init_template" ||
        fail "cloud-init does not preserve root ownership of the data mount root"
    grep -Fq 'chmod 1775 /mnt/disks/data' "$cloud_init_template" ||
        fail "cloud-init does not make the data mount root sticky and group-writable"
    grep -Fq 'chown cloud-compose:cloud-compose /mnt/disks/volumes' "$cloud_init_template" ||
        fail "cloud-init does not assign the volumes mount root to cloud-compose"
    grep -Fq 'chmod 0775 /mnt/disks/volumes' "$cloud_init_template" ||
        fail "cloud-init does not make the volumes mount root group-writable"
    grep -Fq 'for required_mount in /mnt/disks/data /mnt/disks/volumes /mnt/disks/data/docker/volumes; do' \
        "$cloud_init_template" || fail "cloud-init does not verify every required mount before initialization"
    grep -Fq 'Required cloud-compose mount is unavailable:' "$cloud_init_template" ||
        fail "cloud-init mount gate does not report the unavailable path"
    grep -Fq '  bash /usr/local/libexec/cloud-compose/start-cloud-compose-bootstrap.sh' \
        "$cloud_init_template" || fail "cloud-init retryable bootstrap startup is outside the fail-closed mount block"
    marker_reset_line="$(grep -nF '  rm -f /var/lib/cloud-compose/bootstrap-complete' \
        "$cloud_init_template" | cut -d: -f1)"
    run_line="$(grep -nF '  bash /usr/local/libexec/cloud-compose/start-cloud-compose-bootstrap.sh' \
        "$cloud_init_template" | cut -d: -f1)"
    [[ -n "$marker_reset_line" && -n "$run_line" && "$marker_reset_line" -lt "$run_line" ]] ||
        fail "cloud-init does not clear stale bootstrap readiness before retryable startup"
done
grep -Fq 'install -m 0600 /dev/null /run/cloud-compose-filesystems-ready' \
    "$repo_root/templates/cloud-init.yml" || fail "GCP bootcmd does not publish filesystem readiness"
grep -Fq 'test -f /run/cloud-compose-filesystems-ready || {' \
    "$repo_root/templates/cloud-init.yml" || fail "GCP runcmd does not require filesystem readiness"
grep -Fq 'test -f /run/cloud-compose-filesystems-ready || {' \
    "$repo_root/modules/gcp/main.tf" || fail "GCP archive installation is not gated by filesystem readiness"

persist_tmp="$tmp/persist"
mkdir -p "$persist_tmp/bin"
cat >"$persist_tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PERSIST_SYSTEMCTL_LOG:?}"
EOF
chmod +x "$persist_tmp/bin/systemctl"
fstab="$persist_tmp/fstab"
systemctl_log="$persist_tmp/systemctl.log"
printf '# existing filesystem table\n' >"$fstab"
: >"$systemctl_log"

run_persist() {
    PATH="$persist_tmp/bin:/usr/bin:/bin" \
        CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
        CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
        PERSIST_SYSTEMCTL_LOG="$systemctl_log" \
        bash "$persist_script" \
        /dev/disk/by-id/provider-data \
        /dev/disk/by-id/provider-volumes
}

run_persist
grep -Fq $'/dev/disk/by-id/provider-data\t/mnt/disks/data\text4\tdefaults,nofail,x-systemd.device-timeout=120s\t0\t2' "$fstab" || \
    fail "persistent data mount was not recorded"
grep -Fq $'/dev/disk/by-id/provider-volumes\t/mnt/disks/volumes\text4\tdefaults,nofail,x-systemd.device-timeout=120s\t0\t2' "$fstab" || \
    fail "persistent Docker-volume mount was not recorded"
grep -Fq $'/mnt/disks/volumes\t/mnt/disks/data/docker/volumes\tnone\tbind,nofail,x-systemd.requires=/mnt/disks/volumes\t0\t0' "$fstab" || \
    fail "persistent Docker bind mount was not recorded"
[[ "$(grep -Fc '# BEGIN cloud-compose persistent mounts' "$fstab")" == "1" ]] || \
    fail "filesystem persistence did not write one managed block"
run_persist
[[ "$(grep -Fc '# BEGIN cloud-compose persistent mounts' "$fstab")" == "1" ]] || \
    fail "filesystem persistence is not idempotent"
grep -Fxq 'daemon-reload' "$systemctl_log" || fail "filesystem persistence did not reload systemd"

printf '# existing filesystem table\n' >"$fstab"
PATH="$persist_tmp/bin:/usr/bin:/bin" \
    CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
    CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
    PERSIST_SYSTEMCTL_LOG="$systemctl_log" \
    bash "$persist_script" \
    /dev/disk/by-id/provider-data \
    /dev/disk/by-id/provider-volumes \
    /dev/disk/by-id/provider-prod
grep -Fq $'/dev/disk/by-id/provider-prod\t/mnt/disks/prod-readonly\text4\tro,nofail,x-systemd.device-timeout=120s\t0\t2' "$fstab" || \
    fail "persistent read-only overlay source was not recorded"

do_data_device=/dev/disk/by-id/scsi-0DO_Volume_cc-do-data
do_volumes_device=/dev/disk/by-id/scsi-0DO_Volume_cc-do-docker-volumes
do_data_mount=/mnt/cc_do_data
do_volumes_mount=/mnt/cc_do_docker_volumes
do_systemd_dir="$persist_tmp/systemd"
mkdir -p "$do_systemd_dir/multi-user.target.wants"
printf '%s\n' \
    "$do_data_device $do_data_mount ext4 defaults,nofail,discard,noatime 0 2" \
    "$do_volumes_device $do_volumes_mount ext4 defaults,nofail,discard,noatime 0 2" \
    >"$fstab"
printf '[Mount]\nWhat=%s\nWhere=%s\n' "$do_data_device" "$do_data_mount" \
    >"$do_systemd_dir/mnt-cc_do_data.mount"
printf '[Mount]\nWhat=%s\nWhere=%s\n' "$do_volumes_device" "$do_volumes_mount" \
    >"$do_systemd_dir/mnt-cc_do_docker_volumes.mount"
ln -s ../mnt-cc_do_data.mount \
    "$do_systemd_dir/multi-user.target.wants/mnt-cc_do_data.mount"
ln -s ../mnt-cc_do_docker_volumes.mount \
    "$do_systemd_dir/multi-user.target.wants/mnt-cc_do_docker_volumes.mount"
PATH="$persist_tmp/bin:/usr/bin:/bin" \
    CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
    CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
    CLOUD_COMPOSE_SYSTEMD_DIR="$do_systemd_dir" \
    PERSIST_SYSTEMCTL_LOG="$systemctl_log" \
    bash "$persist_script" "$do_data_device" "$do_volumes_device"
if grep -Eq "^[^#]+[[:space:]]+($do_data_mount|$do_volumes_mount)[[:space:]]" "$fstab"; then
    fail "superseded DigitalOcean automatic fstab entries were retained"
fi
[[ ! -e "$do_systemd_dir/mnt-cc_do_data.mount" ]] ||
    fail "the provider-owned DigitalOcean data mount unit was retained"
[[ ! -e "$do_systemd_dir/mnt-cc_do_docker_volumes.mount" ]] ||
    fail "the provider-owned DigitalOcean Docker-volume mount unit was retained"
[[ ! -L "$do_systemd_dir/multi-user.target.wants/mnt-cc_do_data.mount" ]] ||
    fail "the provider-owned DigitalOcean data mount wants link was retained"

printf '/dev/operator %s ext4 defaults 0 2\n' "$do_data_mount" >"$fstab"
if PATH="$persist_tmp/bin:/usr/bin:/bin" \
    CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
    CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
    CLOUD_COMPOSE_SYSTEMD_DIR="$do_systemd_dir" \
    PERSIST_SYSTEMCTL_LOG="$systemctl_log" \
    bash "$persist_script" "$do_data_device" "$do_volumes_device" >/dev/null 2>&1; then
    fail "an unexpected source at a DigitalOcean automatic mount target was replaced"
fi
grep -Fq "/dev/operator $do_data_mount" "$fstab" ||
    fail "a conflicting DigitalOcean automatic mount entry was mutated"

printf '# existing filesystem table\n' >"$fstab"
printf '[Mount]\nWhat=/dev/operator\nWhere=%s\n' "$do_data_mount" \
    >"$do_systemd_dir/mnt-cc_do_data.mount"
if PATH="$persist_tmp/bin:/usr/bin:/bin" \
    CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
    CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
    CLOUD_COMPOSE_SYSTEMD_DIR="$do_systemd_dir" \
    PERSIST_SYSTEMCTL_LOG="$systemctl_log" \
    bash "$persist_script" "$do_data_device" "$do_volumes_device" >/dev/null 2>&1; then
    fail "an unexpected DigitalOcean mount unit was removed"
fi
[[ -f "$do_systemd_dir/mnt-cc_do_data.mount" ]] ||
    fail "an unexpected DigitalOcean mount unit was mutated"

printf '/dev/operator /mnt/disks/data ext4 defaults 0 2\n' >"$fstab"
if run_persist >/dev/null 2>&1; then
    fail "filesystem persistence replaced an unmanaged mount target"
fi
grep -Fq '/dev/operator /mnt/disks/data' "$fstab" || \
    fail "filesystem persistence mutated a conflicting operator entry"
if CLOUD_COMPOSE_FSTAB_PATH="$fstab" \
    CLOUD_COMPOSE_FSTAB_LOCK_PATH="$persist_tmp/fstab.lock" \
    bash "$persist_script" '/dev/disk/by-id/bad device' /dev/disk/by-id/provider-volumes >/dev/null 2>&1; then
    fail "filesystem persistence accepted an unsafe device path"
fi

grep -Fq 'FILESYSTEM_PERSIST_SCRIPT_B64' "$repo_root/templates/cloud-init.yml" || \
    fail "GCP cloud-init does not bootstrap persistent mount configuration"
grep -Fq 'FILESYSTEM_PERSIST_SCRIPT_B64' "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml" || \
    fail "Linux VM cloud-init does not bootstrap persistent mount configuration"
grep -Fq '/var/lib/cloud-compose/mounted-rootfs/mnt/disks' "$repo_root/modules/linux-vm-runtime/templates/cloud-init.yml" || \
    fail "Linux VM cloud-init does not copy mounted-root files after mounting durable storage"

do_module="$repo_root/modules/digitalocean/main.tf"
if grep -Eq 'initial_filesystem_type[[:space:]]*=' "$do_module"; then
    fail "new DigitalOcean volumes still request provider-side formatting and automount"
fi
[[ "$(grep -Fc 'ignore_changes = [initial_filesystem_type]' "$do_module")" -eq 2 ]] ||
    fail "DigitalOcean volume upgrades do not preserve existing volume identity across the formatting transition"

echo "Filesystem preparation contract passed"
