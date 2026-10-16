#!/bin/bash
# Applies Rise's patches (Engine/fork/patches/*.patch, in name order) on top of the pinned
# checkout, then Rise's branding. Safe to run again: patches already applied are skipped.
source "$(dirname "$0")/common.sh"

shopt -s nullglob
patches=("$ENGINE_DIR"/fork/patches/*.patch) reversed=()
for ((i = ${#patches[@]} - 1; i >= 0; i--)); do reversed+=("${patches[i]}"); done
# Patches next to each other only undo one after another, newest first, so that's tried on
# copies of the files they touch.
all=0
if ((${#patches[@]})); then
  scratch="$(mktemp -d)" all=1
  for file in $(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u); do
    [[ -f "$CHROMIUM_SRC/$file" ]] && mkdir -p "$scratch/$(dirname "$file")" && cp "$CHROMIUM_SRC/$file" "$scratch/$file"
  done
  for patch in "${reversed[@]}"; do
    (cd "$scratch" && git apply --reverse "$patch" 2>/dev/null) || { all=0; break; }
  done
  rm -rf "$scratch"
fi
if ((all)); then
  echo "already applied: $(basename -a "${patches[@]}" | tr '\n' ' ')"
else
  for patch in "${patches[@]}"; do
    if git -C "$CHROMIUM_SRC" apply --reverse --check "$patch" 2>/dev/null; then
      echo "already applied: $(basename "$patch")"
    else
      git -C "$CHROMIUM_SRC" apply --3way "$patch"
      echo "applied: $(basename "$patch")"
    fi
  done
fi

# Rise's name where Chromium names itself to people, in every language.
python3 "$(dirname "$0")/brand.py" "$CHROMIUM_SRC"
