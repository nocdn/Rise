# Shared settings for the Chromium engine scripts. Source, don't run.
set -euo pipefail

RISE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_DIR="$RISE_ROOT/Engine"
PIN="$ENGINE_DIR/chromium.json"
# The Chromium checkout is far too big for the repo; it lives beside it.
ENGINE_ROOT="${RISE_CHROMIUM_ROOT:-$(dirname "$RISE_ROOT")/rise-chromium}"
DEPOT_TOOLS="$ENGINE_ROOT/depot_tools"
CHROMIUM_SRC="$ENGINE_ROOT/chromium/src"
CEF_SRC="$CHROMIUM_SRC/cef"
OUT_DIR="$CHROMIUM_SRC/out/Release_GN_arm64"

pin() { python3 -c "import json,sys; print(json.load(open('$PIN'))[sys.argv[1]])" "$1"; }
gn_defines() { python3 -c "import json; print(' '.join(json.load(open('$PIN'))['gn_defines']))"; }

export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
export GN_DEFINES="$(gn_defines)"
export CEF_ARCHIVE_FORMAT=tar.bz2
# Only the release build for Apple silicon; a debug build doubles the time and disk.
export GN_OUT_CONFIGS=Release_GN_arm64
