#!/bin/zsh
# Rebuilds Rise and relaunches it. Builds are signed with a stable identity (see
# sign-app.py), so macOS keeps folder permissions instead of asking after every restart.
set -euo pipefail
builtin cd "${0:A:h:h}"
if [[ "${1:-}" == "--ios" ]]; then
    shift
    exec python3 scripts/ios.py run "$@"
fi
./scripts/build.sh
APP="$PWD/build/Rise.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
if pgrep -xq Rise; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    # Let Rise save its session and exit before the new build opens.
    for _ in {1..50}; do pgrep -xq Rise || break; sleep 0.1; done
fi
open "$APP"
echo "Restarted $APP"
