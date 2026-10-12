#!/bin/bash
# Applies Rise's engine patches on top of the pinned checkout, in order:
# Engine/patches/cef/*.patch to CEF, then Engine/patches/chromium/*.patch to Chromium.
# Safe to run again: patches already applied are skipped.
source "$(dirname "$0")/common.sh"

apply() {
  local tree="$1" dir="$2"
  shopt -s nullglob
  local patches=("$dir"/*.patch) reversed=()
  for ((i = ${#patches[@]} - 1; i >= 0; i--)); do reversed+=("${patches[i]}"); done
  # Patches next to each other only undo one after another, newest first, so that's tried on
  # copies of the files they touch.
  if ((${#patches[@]})); then
    local scratch all=1
    scratch="$(mktemp -d)"
    for file in $(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u); do
      [[ -f "$tree/$file" ]] && mkdir -p "$scratch/$(dirname "$file")" && cp "$tree/$file" "$scratch/$file"
    done
    for patch in "${reversed[@]}"; do
      (cd "$scratch" && git apply --reverse "$patch" 2>/dev/null) || { all=0; break; }
    done
    rm -rf "$scratch"
    if ((all)); then
      echo "already applied: $(basename -a "${patches[@]}" | tr '\n' ' ')"
      return
    fi
  fi
  for patch in "${patches[@]}"; do
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
