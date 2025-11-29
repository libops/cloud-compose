#!/usr/bin/env bash

set -eou pipefail
set -x

# Argument 1 (MANDATORY): The docker volume name (e.g.,compose_ojs-public)
VOLUME="$1"
# Argument 2 (OPTIONAL): Flag to perform a destructive reset.
# Defaults to 'false'. Check for non-empty argument.
# We check if $2 is passed at all to handle '1' or 'true'.
RESET_FLAG="${2:-}"
PERFORM_RESET=false
if [[ -n "$RESET_FLAG" ]]; then
    PERFORM_RESET=true
fi

DIR="/mnt/disks/volumes/$VOLUME"
LOWER_DIR="/mnt/disks/prod-readonly/$VOLUME"
UPPER_DIR="/mnt/disks/volumes/.overlay/$VOLUME/upper"
WORK_DIR="/mnt/disks/volumes/.overlay/$VOLUME/work"

if ! $PERFORM_RESET; then
  mkdir -p "/mnt/disks/volumes/${VOLUME}"
  mkdir -p "/mnt/disks/volumes/.overlay/${VOLUME}/upper"
  mkdir -p "/mnt/disks/volumes/.overlay/${VOLUME}/work"
fi

if [ ! -d "$DIR" ] || [ ! -d "$LOWER_DIR" ] || [ ! -d "$UPPER_DIR" ] || [ ! -d "$WORK_DIR" ]; then
  echo "$DIR doesn't exist as an overlay"
  exit 1
fi

if $PERFORM_RESET; then
  if mountpoint -q "$DIR"; then
      echo "Unmounting current volume at $DIR..."
      umount "$DIR"
  else
      echo "Volume $DIR is not mounted. Skipping unmount."
  fi
  rm -rf "/mnt/disks/volumes/.overlay/$VOLUME/upper/*"
fi

# make this script idempotent
if mountpoint -q "$DIR"; then
    if ! $PERFORM_RESET; then
        echo "Volume $DIR is already mounted. Skipping mount (Run with '1' to reset)."
        exit 0
    fi
fi

mount \
  -t overlay overlay \
  -o "lowerdir=$LOWER_DIR,upperdir=$UPPER_DIR,workdir=$WORK_DIR" \
  "/mnt/disks/volumes/$VOLUME"
echo "Volume $VOLUME is now active and mounted."
