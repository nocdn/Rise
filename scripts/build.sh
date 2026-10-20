#!/bin/zsh
set -euo pipefail
builtin cd "${0:A:h:h}"
# Validate restricted passkey signing before changing the existing app bundle.
python3 scripts/sign-app.py --check
# Swift Build can otherwise stamp the deployment target as the SDK version,
# which opts AppKit into legacy rendering despite compiling with a newer SDK.
RISE_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
# Pages' ad blocking, from Engine/adblock's filter lists.
ENGINE_ROOT="${RISE_CHROMIUM_ROOT:-${PWD:h}/rise-chromium}"
if command -v cargo > /dev/null; then
  cargo build --quiet --release --manifest-path Engine/adblock/Cargo.toml --target-dir "$ENGINE_ROOT/adblock-build"
fi
# Rise's Chromium fork, built by scripts/engine/build.sh (Engine/README.md).
FRAMEWORK="$ENGINE_ROOT/fork/src/out/Release/Chromium.app/Contents/Frameworks/Chromium Framework.framework"
[[ -d "$FRAMEWORK" ]] || { echo "The engine isn't built: $FRAMEWORK (see Engine/README.md)" >&2; exit 1; }
APP="$PWD/build/Rise.app"
swift build -c release --jobs "${RISE_BUILD_JOBS:-4}" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$RISE_SDK_VERSION"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Rise "$APP/Contents/MacOS/Rise"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Both platforms ship the same verified bundle, rebuilt from scripts/ios-cookie-consent.
rsync -a --delete Apps/iOS/Rise/CookieConsent/ "$APP/Contents/Resources/CookieConsent/"
xcrun actool "$PWD/Assets/AppIcon/Rise.icon" --compile "$APP/Contents/Resources" --app-icon Rise --include-all-app-icons \
  --output-partial-info-plist "$PWD/.build/icon-info.plist" --target-device mac --platform macosx \
  --minimum-deployment-target 14.0 --output-format human-readable-text --errors > /dev/null
# The engine's framework, with its helper apps, as Chromium.app has it.
rsync -a --delete "$FRAMEWORK/" "$APP/Contents/Frameworks/Chromium Framework.framework/"
python3 scripts/sign-app.py "$APP"
echo "Built $APP"
