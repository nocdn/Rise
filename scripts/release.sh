#!/bin/zsh
# Publishes a Rise release (docs/Releasing.md): builds a Developer ID signed Rise with Sparkle's feed,
# notarizes and staples it, wraps it in a notarized DMG, adds it to Sparkle's appcast (with deltas from
# earlier releases), and attaches the DMG, the appcast and the deltas to a GitHub release.
#
#     scripts/release.sh 0.2.0 [notes.md]
#
# Needs: a clean `main` pushed to GitHub, the `rise-notary` notarytool profile in the Keychain, and
# Sparkle's private key in ~/Library/Application Support/Rise/Signing/sparkle-ed25519.key.
set -euo pipefail
builtin cd "${0:A:h:h}"
VERSION="${1:?usage: scripts/release.sh <version> [release-notes.md]}"
NOTES="${2:-}"
TAG="v$VERSION"
REPO="${RISE_RELEASE_REPO:-nocdn/Rise}"
NOTARY="${RISE_NOTARY_PROFILE:-rise-notary}"
KEY="${RISE_SPARKLE_KEY:-$HOME/Library/Application Support/Rise/Signing/sparkle-ed25519.key}"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"
SPARKLE=.build/artifacts/sparkle/Sparkle/bin
# Every published DMG stays here: Sparkle makes each new release's deltas from the ones before it.
ARCHIVES="$PWD/build/releases"
WORK="$PWD/build/release-$VERSION"

fail() { echo "release: $*" >&2; exit 1; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "the version is three numbers, such as 0.2.0"
[[ "$(git branch --show-current)" == main ]] || fail "releases are made from main"
[[ -z "$(git status --porcelain)" ]] || fail "commit everything first: a release is built from what's committed"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "push main first, so the release's source is on GitHub"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "$TAG already exists"
[[ -f "$KEY" ]] || fail "Sparkle's private key isn't at $KEY"
xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1 || fail "no working notarytool profile '$NOTARY' (docs/Releasing.md)"
[[ -z "$NOTES" || -f "$NOTES" ]] || fail "no release notes at $NOTES"
# Sparkle orders releases by CFBundleVersion, which must only grow: main's commit count does.
BUILD_NUMBER="$(git rev-list --count HEAD)"

rm -rf "$WORK"; mkdir -p "$WORK" "$ARCHIVES"
APP="$WORK/Rise.app"
RISE_APP="$APP" RISE_VERSION="$VERSION" RISE_BUILD_NUMBER="$BUILD_NUMBER" RISE_UPDATE_FEED="$FEED" ./scripts/build.sh
# Read whole, not piped into grep -q: under pipefail, grep quitting early fails the pipe.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
IDENTITY="$(print -r -- "$SIGNATURE" | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || fail "Rise wasn't signed with Developer ID (docs/Passkeys.md has the profile)"

notarize() {  # Sends a file to Apple's notary service and waits for its verdict.
  local id log
  log="$WORK/notary-$(basename "$1").json"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY" --wait --output-format json > "$log" || true
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$log" 2>/dev/null || true)"
  if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("status") != "Accepted")' "$log"; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY" "$WORK/notary-$(basename "$1")-log.json" || true
    fail "notarization of $(basename "$1") failed: see $WORK"
  fi
}

echo "Notarizing Rise.app…"
ditto -c -k --keepParent "$APP" "$WORK/Rise.zip"
notarize "$WORK/Rise.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper rejects the notarized app"

echo "Making the DMG…"
DMG="$WORK/Rise-$VERSION.dmg"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Rise.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "Rise" -srcfolder "$WORK/dmg" -fs APFS -format ULFO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejects the DMG"

echo "Updating the appcast…"
cp "$DMG" "$ARCHIVES/"
[[ -n "$NOTES" ]] && cp "$NOTES" "$ARCHIVES/Rise-$VERSION.md"
# The previous release's appcast, so its entries (and their download addresses) carry over.
[[ -f "$ARCHIVES/appcast.xml" ]] || gh release download --repo "$REPO" --pattern appcast.xml --dir "$ARCHIVES" 2>/dev/null || true
touch "$WORK/before-appcast"; sleep 1
"$SPARKLE/generate_appcast" --ed-key-file "$KEY" --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" --maximum-deltas 3 "$ARCHIVES"
DELTAS=("${(@f)$(find "$ARCHIVES" -maxdepth 1 -name '*.delta' -newer "$WORK/before-appcast")}")
DELTAS=(${DELTAS:#})

echo "Publishing $TAG…"
git tag "$TAG" && git push -q origin "$TAG"
NOTES_ARGS=(--generate-notes); [[ -n "$NOTES" ]] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" --repo "$REPO" --title "Rise $VERSION" "${NOTES_ARGS[@]}" "$DMG" "$ARCHIVES/appcast.xml" "${DELTAS[@]}"
echo "Released Rise $VERSION (build $BUILD_NUMBER): https://github.com/$REPO/releases/tag/$TAG"
