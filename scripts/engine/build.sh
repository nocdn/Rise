#!/bin/bash
# Builds the patched engine for Apple silicon (release, no symbols) and makes the
# framework distribution Rise links against. Run checkout.sh and patch.sh first.
source "$(dirname "$0")/common.sh"

# Chromium's graphics layer compiles Metal shaders; Xcode 26 ships without the compiler.
if ! xcrun -f metal >/dev/null 2>&1; then
  echo "Missing the Metal toolchain. Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

"$(dirname "$0")/patch.sh"

# Regenerates the build files with Rise's GN settings, as CEF's own build does.
(cd "$CEF_SRC" && ./cef_create_projects.sh)
autoninja -C "$OUT_DIR" cef

(cd "$CEF_SRC/tools" && ./make_distrib.sh --ninja-build --arm64-build --minimal --no-docs --no-symbols --no-archive \
  --output-dir="$ENGINE_ROOT/distrib")

# Rise's bridge links CEF's C++ wrapper, which has to match the headers just made.
WRAPPER="$ENGINE_ROOT/bridge-build/wrapper"
mkdir -p "$WRAPPER"
cmake -S "$(cd "$ENGINE_ROOT/distrib/current" && pwd -P)" -B "$WRAPPER" -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$WRAPPER" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)"
echo "Engine built into $ENGINE_ROOT/distrib"
