#!/bin/bash
# Applies Rise's engine patches on top of the pinned checkout, in order:
# Engine/patches/cef/*.patch to CEF, then Engine/patches/chromium/*.patch to Chromium.
# Safe to run again: patches already applied are skipped.
source "$(dirname "$0")/common.sh"

apply() {
  local tree="$1" dir="$2"
  shopt -s nullglob
  for patch in "$dir"/*.patch; do
    if git -C "$tree" apply --reverse --check "$patch" 2>/dev/null; then
      echo "already applied: $(basename "$patch")"
    else
      git -C "$tree" apply --3way "$patch"
      echo "applied: $(basename "$patch")"
    fi
  done
}

apply "$CEF_SRC" "$ENGINE_DIR/patches/cef"
apply "$CHROMIUM_SRC" "$ENGINE_DIR/patches/chromium"
