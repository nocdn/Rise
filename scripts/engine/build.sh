#!/bin/bash
# Builds Rise's Chromium fork for Apple silicon (release, no symbols): Chromium.app, whose
# framework Rise links against and carries. Run checkout.sh first.
source "$(dirname "$0")/common.sh"

# Leave memory for the desktop. Autoninja otherwise schedules a job per CPU,
# which can push a local Chromium build deep into swap on a shared Mac.
jobs="${RISE_CHROMIUM_JOBS:-4}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { echo "RISE_CHROMIUM_JOBS must be a positive integer" >&2; exit 1; }

# Chromium's graphics layer compiles Metal shaders; Xcode 26 ships without the compiler.
if ! xcrun -f metal >/dev/null 2>&1; then
  echo "Missing the Metal toolchain. Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

"$(dirname "$0")/patch.sh"
[[ -f "$OUT_DIR/args.gn" ]] || (cd "$CHROMIUM_SRC" && gn gen "$OUT_DIR" --args="$(gn_args)")
autoninja -C "$OUT_DIR" -j "$jobs" chrome "$@"
echo "Engine built: $OUT_DIR/Chromium.app"
