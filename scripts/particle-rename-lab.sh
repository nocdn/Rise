#!/bin/zsh
# Builds and opens Particle Rename Lab (Playgrounds/ParticleRename): the reference recording of the
# particle rename above Rise's version, with buttons for each state and sliders for its timing.
# A standalone app; it needs neither the engine nor Rise's build.
#   scripts/particle-rename-lab.sh                 build and open
#   scripts/particle-rename-lab.sh --strip out.png  write the reveal's frames as one image
set -euo pipefail
builtin cd "${0:A:h:h}"
APP="$PWD/build/Particle Rename Lab.app"
osascript -e 'tell application id "dev.bartosz.Rise.ParticleRenameLab" to quit' >/dev/null 2>&1 || true
for _ in {1..50}; do pgrep -xq ParticleRenameLab || break; sleep 0.1; done
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos14 -swift-version 5 \
  Playgrounds/ParticleRename/*.swift -o "$APP/Contents/MacOS/ParticleRenameLab"
cp Playgrounds/particle-rename-reference.mp4 "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.bartosz.Rise.ParticleRenameLab</string>
  <key>CFBundleName</key><string>Particle Rename Lab</string>
  <key>CFBundleExecutable</key><string>ParticleRenameLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null
if [[ "${1:-}" == --strip ]]; then
  "$APP/Contents/MacOS/ParticleRenameLab" --strip "${2:?--strip needs an output path}"
else
  open "$APP"; echo "Opened $APP"
fi
