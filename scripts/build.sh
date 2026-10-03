#!/bin/zsh
set -euo pipefail
builtin cd "${0:A:h:h}"
# Swift Build can otherwise stamp the deployment target as the SDK version,
# which opts AppKit into legacy rendering despite compiling with a newer SDK.
RISE_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$RISE_SDK_VERSION"
APP="$PWD/build/Rise.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Rise "$APP/Contents/MacOS/Rise"
cp -R .build/release/Rise_Rise.bundle "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f scripts/Rise.icns ]]; then cp scripts/Rise.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"
