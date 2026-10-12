#!/bin/bash
# Fetches the pinned Chromium and CEF sources (without history) beside the repo.
# Takes hours the first time and about 30 GB.
source "$(dirname "$0")/common.sh"

mkdir -p "$ENGINE_ROOT"
# Keep Spotlight out of hundreds of thousands of source files.
touch "$ENGINE_ROOT/.metadata_never_index"

AUTOMATE="$ENGINE_ROOT/automate-git.py"
curl -fsSL "https://raw.githubusercontent.com/chromiumembedded/cef/$(pin cef_commit)/tools/automate/automate-git.py" -o "$AUTOMATE"

python3 "$AUTOMATE" \
  --download-dir="$ENGINE_ROOT" \
  --depot-tools-dir="$DEPOT_TOOLS" \
  --branch="$(pin cef_branch)" \
  --checkout="$(pin cef_commit)" \
  --no-chromium-history \
  --arm64-build \
  --no-debug-build \
  --no-build \
  --no-distrib

echo "Checked out Chromium $(pin chromium) with CEF $(pin cef_branch) at $CHROMIUM_SRC"
