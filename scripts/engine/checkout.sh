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
              'custom_vars': {'checkout_pgo_profiles': True}, 'custom_deps': {}, 'deps_file': 'DEPS'}]
GCLIENT
revision="refs/tags/$(pin chromium)"
# Moving an existing checkout to a new pin: fetch just that tag, and name its commit, as gclient
# otherwise fetches every branch Chromium has into the shallow checkout (hours, and it stalls).
if [[ -d src/.git ]]; then
  git -C src rev-parse -q --verify "refs/tags/$(pin chromium)^{commit}" >/dev/null ||
    git -C src fetch -q --depth 1 origin tag "$(pin chromium)"
  revision="$(git -C src rev-parse "refs/tags/$(pin chromium)^{commit}")"
fi
# A few fetches at a time: googlesource rate-limits anonymous clients that fetch many at once (HTTP 429).
gclient sync --no-history --shallow -j "${RISE_GCLIENT_JOBS:-4}" --revision "src@$revision"

echo "Checked out Chromium $(pin chromium) at $CHROMIUM_SRC"
