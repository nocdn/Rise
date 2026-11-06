#!/bin/bash
# Copies the engine, Chromium.app, from another Mac that has built it, for a Mac that can't
# build it itself (docs/EngineRebuild.md). Run it again whenever the engine changes there.
#   scripts/engine/fetch.sh <ssh-host> [ssh-port]
source "$(dirname "$0")/common.sh"

host="${1:?Usage: scripts/engine/fetch.sh <ssh-host> [ssh-port]}"
port="${2:-22}"
# The other Mac's checkout, from its home folder.
remote="${RISE_REMOTE_CHROMIUM_ROOT:-github/rise-chromium}/fork/src/out/Official/Chromium.app/"
mkdir -p "$OUT_DIR/Chromium.app"
# Over SSH, so macOS doesn't quarantine it as a download.
rsync -a --delete -e "ssh -p $port" "$host:$remote" "$OUT_DIR/Chromium.app/"
[[ -d "$OUT_DIR/Chromium.app/Contents/Frameworks/Chromium Framework.framework" ]] || {
  echo "$host's Chromium.app has no Chromium Framework.framework: has the engine finished building there?" >&2
  exit 1
}
echo "Engine fetched: $OUT_DIR/Chromium.app. Then ./scripts/restart.sh"
