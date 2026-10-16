#!/bin/zsh
# Runs Rise's unit tests (any `swift test` arguments, such as --filter). Chromium's framework names
# itself from the app it's in, so the tests find the engine's build through DYLD_FRAMEWORK_PATH;
# that takes Xcode's swift, as macOS clears it for /usr/bin's.
set -euo pipefail
builtin cd "${0:A:h:h}"
ENGINE_ROOT="${RISE_CHROMIUM_ROOT:-${PWD:h}/rise-chromium}"
export DYLD_FRAMEWORK_PATH="$ENGINE_ROOT/fork/src/out/Release/Chromium.app/Contents/Frameworks"
exec "$(xcrun -f swift)" test "$@"
