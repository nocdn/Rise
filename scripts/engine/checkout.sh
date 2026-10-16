#!/bin/bash
# Fetches the pinned Chromium (without history) beside the repo, for Rise's fork of it.
# Takes hours the first time and about 30 GB.
source "$(dirname "$0")/common.sh"

mkdir -p "$FORK_ROOT"
# Keep Spotlight out of hundreds of thousands of source files.
touch "$ENGINE_ROOT/.metadata_never_index"
[[ -d "$DEPOT_TOOLS" ]] || git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"

cd "$FORK_ROOT"
cat > .gclient <<GCLIENT
solutions = [{'managed': False, 'name': 'src', 'url': 'https://chromium.googlesource.com/chromium/src.git@$(pin chromium)',
              'custom_vars': {'checkout_pgo_profiles': False}, 'custom_deps': {}, 'deps_file': 'DEPS'}]
GCLIENT
gclient sync --no-history --shallow --revision "src@refs/tags/$(pin chromium)"

echo "Checked out Chromium $(pin chromium) at $CHROMIUM_SRC"
