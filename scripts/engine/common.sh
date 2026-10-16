# Shared settings for the engine scripts. Source, don't run.
set -euo pipefail

RISE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE_DIR="$RISE_ROOT/Engine"
PIN="$ENGINE_DIR/chromium.json"
# The Chromium checkout is far too big for the repo; it lives beside it.
ENGINE_ROOT="${RISE_CHROMIUM_ROOT:-$(dirname "$RISE_ROOT")/rise-chromium}"
DEPOT_TOOLS="$ENGINE_ROOT/depot_tools"
FORK_ROOT="$ENGINE_ROOT/fork"
CHROMIUM_SRC="$FORK_ROOT/src"
OUT_DIR="$CHROMIUM_SRC/out/Release"

pin() { python3 -c "import json,sys; print(json.load(open('$PIN'))[sys.argv[1]])" "$1"; }
gn_args() { python3 -c "import json; print(' '.join(json.load(open('$PIN'))['gn_args']))"; }

export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
