# Releasing the Mac app

People install Rise from a DMG on [GitHub Releases](https://github.com/nocdn/Rise/releases), and copies
installed that way update themselves through [Sparkle](https://sparkle-project.org) 2.10.1.

```sh
scripts/release.sh 0.2.0 [notes.md]
```

The script builds Rise into `build/release-<version>/` (never over `build/Rise.app`, which can be a
link to the copy in use), signs it with Developer ID, notarizes and staples it, wraps it in a signed,
notarized DMG, adds the DMG to Sparkle's appcast and publishes `v<version>` on GitHub with the DMG, the
appcast and any delta updates. Without notes, GitHub writes them from the commits since the last tag.

It refuses to run unless `main` is clean and pushed, so every release is built from source on GitHub.

## What a release carries

- **Version:** `CFBundleShortVersionString` is the version given; `CFBundleVersion` is `main`'s commit
  count, which only grows, as Sparkle needs to order releases.
- **Feed:** `SUFeedURL` is `https://github.com/nocdn/Rise/releases/latest/download/appcast.xml`, which
  GitHub serves from the newest release. Only release builds carry it (`RISE_UPDATE_FEED` in
  `scripts/build.sh`): a local build never offers to replace itself with a published one, and has no
  Check for Updates… item.
- **Checks:** daily (`SUEnableAutomaticChecks`), with Sparkle's window asking before installing; the
  first update offers to install later ones automatically. Each update's signature is checked before
  it's unpacked (`SUVerifyUpdateBeforeExtraction`).
- **Deltas:** every published DMG is kept in `build/releases/`, and `generate_appcast` makes deltas to
  the new release from the last three, so an update that leaves the engine alone downloads a few
  megabytes rather than the whole app. If that folder is lost, download the earlier DMGs from GitHub
  into it before the next release; without them, updates are full downloads, which still work.

## Signing

- **Rise and the engine:** `scripts/sign-app.py` signs the Chromium helpers as Chrome's release
  signing does (`chrome/installer/mac/signing/parts.py`): each under the hardened runtime, the renderer
  and GPU helpers with `com.apple.security.cs.allow-jit` and without library validation, the others
  with it. Sparkle's Installer, Downloader, Autoupdate and Updater are signed as its documentation
  says. Notarization needs all of this and Apple's secure timestamp on each piece. A JavaScript
  benchmark ran the same before and after (about 430 and 413 ms).
- **Developer ID:** the profile in `~/Library/Application Support/Rise/Signing/` chooses the Developer
  ID certificate (`docs/Passkeys.md`).
- **Notarization:** the `rise-notary` notarytool profile in the login Keychain, made with an
  app-specific password named "rise-notary" at account.apple.com:

  ```sh
  xcrun notarytool store-credentials rise-notary --apple-id <apple-id> --team-id 7CAU3XFRLQ --password <app-specific password>
  ```

- **Sparkle's key:** updates are signed with an EdDSA key whose public half is `SUPublicEDKey` in
  `scripts/Info.plist`. The private half is in
  `~/Library/Application Support/Rise/Signing/sparkle-ed25519.key` (and the login Keychain, account
  `rise`). **Keep a copy somewhere safe**: installed copies only accept updates signed with it, so
  without it they can't be updated.
