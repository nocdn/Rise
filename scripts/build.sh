#!/bin/zsh
set -euo pipefail
builtin cd "${0:A:h:h}"
# Validate restricted passkey signing before changing the existing app bundle.
python3 scripts/sign-app.py --check
# Swift Build can otherwise stamp the deployment target as the SDK version,
# which opts AppKit into legacy rendering despite compiling with a newer SDK.
RISE_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Chromium pages' ad blocking is built from the same filter lists as WebKit's rules.
ENGINE_ROOT="${RISE_CHROMIUM_ROOT:-${PWD:h}/rise-chromium}"
if [[ -f "$ENGINE_ROOT/distrib/current/include/cef_app.h" ]] && command -v cargo > /dev/null; then
  cargo build --quiet --release --manifest-path Engine/adblock/Cargo.toml --target-dir "$ENGINE_ROOT/adblock-build"
fi
# RISE_ENGINE_FORK=1 builds Rise on its own Chromium fork (Engine/fork-plan.md), beside the
# everyday app, as build/RiseFork.app.
FORK_FRAMEWORK="$ENGINE_ROOT/fork/src/out/Release/Chromium.app/Contents/Frameworks/Chromium Framework.framework"
BUILD_PATH=.build APP="$PWD/build/Rise.app"
if [[ "${RISE_ENGINE_FORK:-}" == 1 ]]; then
  [[ -d "$FORK_FRAMEWORK" ]] || { echo "The fork's framework isn't built: $FORK_FRAMEWORK" >&2; exit 1; }
  BUILD_PATH=.build-fork APP="$PWD/build/RiseFork.app"
fi
swift build -c release --build-path "$BUILD_PATH" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$RISE_SDK_VERSION"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_PATH/release/Rise" "$APP/Contents/MacOS/Rise"
cp -R "$BUILD_PATH/release/Rise_Rise.bundle" "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# The icon is an Icon Composer document of the square artwork: macOS 26 and later round and light
# it themselves, and actool prerenders the rounded icon earlier versions show (Assets.car, Rise.icns).
xcrun actool "$PWD/Assets/AppIcon/Rise.icon" --compile "$APP/Contents/Resources" --app-icon Rise --include-all-app-icons \
  --output-partial-info-plist "$PWD/.build/icon-info.plist" --target-device mac --platform macosx \
  --minimum-deployment-target 14.0 --output-format human-readable-text --errors > /dev/null
# The Chromium engine goes in where this Mac has built it (see Engine/README.md).
if [[ "${RISE_ENGINE_FORK:-}" == 1 ]]; then
  # Chrome's framework carries its own helper apps.
  mkdir -p "$APP/Contents/Frameworks"
  rsync -a --delete "$FORK_FRAMEWORK/" "$APP/Contents/Frameworks/Chromium Framework.framework/"
  # Chrome's build only link-signs it; sealed, with its helpers, the app's signature can hold it.
  codesign --force --deep --sign - "$APP/Contents/Frameworks/Chromium Framework.framework" 2> /dev/null
elif [[ -x .build/release/RiseHelper ]]; then
  python3 scripts/engine/package.py "$APP" .build/release/RiseHelper
fi
python3 scripts/sign-app.py "$APP"
echo "Built $APP"
