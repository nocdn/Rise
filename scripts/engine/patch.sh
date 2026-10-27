#!/bin/bash
# Applies Rise's patches (Engine/fork/patches/*.patch, in name order) on top of the pinned
# checkout, then Rise's branding. Safe to run again: patches already applied are skipped.
source "$(dirname "$0")/common.sh"

shopt -s nullglob
patches=("$ENGINE_DIR"/fork/patches/*.patch) reversed=()
for ((i = ${#patches[@]} - 1; i >= 0; i--)); do reversed+=("${patches[i]}"); done
# Overlapping patches only undo newest first. Find the already-applied prefix on copies;
# a newly added suffix must not make us reapply the older patches beneath it.
applied=0
if ((${#patches[@]})); then
  scratch="$(mktemp -d)"
  for file in $(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u); do
    [[ -f "$CHROMIUM_SRC/$file" ]] && mkdir -p "$scratch/$(dirname "$file")" && cp "$CHROMIUM_SRC/$file" "$scratch/$file"
  done
  for patch in "${reversed[@]}"; do
    if (cd "$scratch" && git apply --reverse "$patch" 2>/dev/null); then
      applied=$((applied+1))
    elif ((applied)); then
      # An older patch didn't undo: this isn't an intact prefix. Keep the ordinary
      # checks/three-way fallback, which reports the inconsistency without discarding edits.
      applied=0; break
    fi
  done
  rm -rf "$scratch"
fi
for ((i=0; i<${#patches[@]}; i++)); do
  patch="${patches[i]}"
  if ((i<applied)) || git -C "$CHROMIUM_SRC" apply --reverse --check "$patch" 2>/dev/null; then
    echo "already applied: $(basename "$patch")"
  else
    # A working checkout commonly has later edits outside the index. A clean forward
    # application needs no index merge; reserve --3way for genuinely changed context.
    if git -C "$CHROMIUM_SRC" apply --check "$patch" 2>/dev/null; then
      git -C "$CHROMIUM_SRC" apply "$patch"
    else
      git -C "$CHROMIUM_SRC" apply --3way "$patch"
    fi
    echo "applied: $(basename "$patch")"
  fi
done

# Rise's name where Chromium names itself to people, in every language.
python3 "$(dirname "$0")/brand.py" "$CHROMIUM_SRC"
