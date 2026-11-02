# Rise Tab Sync

A Manifest V3 Chromium extension that shares one browser window's web tabs with
Rise on Mac and iPhone, directly through your private iCloud database. No relay,
Mac companion, server subscription or additional account. All setup and controls
live in the toolbar popup; the extension never opens a setup/settings tab.

## Install on Windows

1. Download and extract `Rise-Tab-Sync-1.0.0.zip` into a permanent folder.
2. Open your Chromium browser's extensions page (`chrome://extensions`, or
   `edge://extensions` in Edge) and enable **Developer mode**.
3. Choose **Load unpacked** and select the extracted `Rise-Tab-Sync` folder
   containing `manifest.json`. When using this repository directly, select
   `Extensions/RiseSync` instead.
4. Pin **Rise Tab Sync** in the browser's Extensions menu, then click its icon.
5. Choose the window to sync, leave **Production** selected for the current Mac
   build, and choose **Sign in with iCloud**. Use the same Apple Account as Rise.
   Apple opens its own sign-in window. Choose **Keep me signed in** if offered.

The public web client tokens and fixed extension identity are already configured.
There is no key to copy for normal setup. Development is available for Xcode
builds signed against Development; devices must use the same environment.
Production and Development are separate databases, not separate accounts.

The manifest's public `key` fixes the extension ID at
`aiannenmbomomcoabicalnfaeblaklof`, even when its folder moves between operating
systems. Keep that key when updating. Keep the unpacked folder in place and use
**Reload** on the extensions page after replacing its files; uninstalling clears
the local bindings, sign-in and unsent changes.

## Behaviour

- Existing HTTP(S) tabs in the chosen window merge with Rise on first connection.
  Matching URLs are adopted by occurrence, preserving duplicate tabs. Other
  windows stay local. New browser tabs join when you navigate them to HTTP(S).
- Opens, navigation, titles, ordering and ordinary tab closes sync both ways.
  Chromium's pinned/unpinned boundary and pin state stay local. Imported tabs open
  in the background, preserving the current selection. Chromium starts loading
  imported pages; imports do not transfer a native browser's login/session state.
- PC edits are debounced for 300 ms. Remote edits are checked about every 30 seconds
  using `chrome.alarms`, including after the Manifest V3 worker sleeps. Sleep,
  browser shutdown and Chromium's scheduler can delay this; there is no polling
  process when the browser is closed. The popup has **Sync now** and **Pause**.
- A remote closure keeps the active tab open until you switch away, without
  resurrecting it in iCloud. Closing an entire browser window pauses its binding
  instead of closing every shared tab. This also protects browser quit/restart.
- On browser restart, saved URLs identify the restored window if the match is
  unique. Missing restored tabs are reimported rather than treated as closes. If
  no unique window matches, choose one in the popup. Chromium does not provide
  durable window IDs across browser restarts.
- Offline changes, record tags, cursors and tombstones persist atomically in local
  storage. The browser bindings and pending-operation journal persist in session
  storage across worker restarts. Errors use bounded retry backoff (up to five
  minutes, or Apple's requested delay). **Sync now** retries immediately.
- An iCloud account change stops sync before fetching/uploading the new account's
  records. **Disconnect** clears local sync data and sign-in without closing tabs
  or deleting anything in iCloud. Then connect the other account explicitly.

Private browsing is disabled for the extension. Files, internal browser pages,
addresses with embedded credentials, passwords and cookies never sync. The tabs
permission reads addresses and titles; the only host permission is Apple's
CloudKit API. `unlimitedStorage` accommodates native navigation-history payloads
and durable closure markers. There are no content scripts, analytics, external
fonts, icon requests or remotely executed scripts.

Chromium cannot import another browser's Back/Forward stack. Native history
already attached to a record survives title-only edits from the extension;
navigating to a new address starts a new route. Learned searches, visit learning,
Rise-specific tab metadata, windows, groups and pin state are outside this
extension's sync scope.

## Maintainer setup

Public API tokens in `src/config.js` identify the web client and are intended to
ship with it. They are not server keys or user credentials; private-database
access additionally requires an Apple-issued user session. User sessions stay in
trusted extension-local storage, never `chrome.storage.sync` or source files.

Tokens were created in CloudKit Console under `iCloud.dev.bartosz.Rise` →
Development/Production → **Tokens & Keys** → **API Tokens**, with **URL Redirect**:

```
https://aiannenmbomomcoabicalnfaeblaklof.chromiumapp.org/
```

Allowed origins use **Any Domain** for Chromium extension compatibility, and
user discoverability is off. Replacing a token requires updating the matching
entry in `src/config.js`, or entering an override under the popup's **Advanced
connection settings**. Never put a server-to-server private key or Apple user
session in the package. Apple's hosted sign-in still requires `chrome.identity`
and `launchWebAuthFlow` support from the Windows browser.

The transport follows Apple's current CloudKit JS protocol: identity is fetched
at `public/users/caller`; tab data uses private `changes/zone`, `records/modify`
and `records/lookup`. Authentication rotates through
`X-Apple-CloudKit-Web-Auth-Token` / `X-Apple-CloudKit-Session` response headers.
All requests are serial, and each replacement token is saved before the next
request. Redirect callbacks accept current `ckSession` and legacy
`ckWebAuthToken` parameters only at the exact extension callback URL.

The wire format is the existing `RiseTab.payload` Bytes field, containing the
Swift `SharedTabRecord` JSON, in `RiseSharedTabs`. Content and position merge
independently; closure tombstones always win. Uploads use optimistic tags and
bounded batches; conflicts fetch the server record, merge, and retry. No forced
record overwrites or schema changes are required.

## Checks and packaging

From the repo root:

```sh
npm --prefix Extensions/RiseSync run check
npm --prefix Extensions/RiseSync test
npm --prefix Extensions/RiseSync run package
```

No npm dependencies or bundler are needed. Node 22+ runs the tests; the parity
check also needs `swiftc` on a Mac. Packaging writes a ZIP under `build/` and
includes only runtime assets and this README.

Tests cover offline reconnection, conflict merges, pagination, account isolation,
active closures, duplicate URLs, interrupted tab creation and browser/worker
restarts. A 300-operation deterministic test compiles the actual Rise Swift ledger
and compares every resulting tab list with the JavaScript implementation.

Live native ↔ Web Services audits passed in both Development and Production on
1 November 2026: native Unicode/Bytes decoding, web updates, optimistic conflicts,
incremental changes, web-created records and closure tombstones, followed by
native verification and deletion of the disposable zones. The ordinary
`RiseSharedTabs` zone is not modified by these audits.

`tests/live/CloudKitAudit.swift` is the signed native fixture generator/verifier;
`tests/live/web-audit.js <private-auth-file> [development|production]` runs the
web half against its generated `RiseWebAudit-UUID` zone. Authentication files must
stay outside source control with mode 0600. Use a browser-authenticated session
for private-database checks: native-minted web tokens can be restricted to public
identity access. Native `verify` always cleans its audit zone after reading the
result; `cleanup` removes the exact generated zone if a test fails.

`tests/live/browser-audit.html` exercises the real Chromium tabs/windows adapter
in an isolated extension/profile, with generated tabs and cleanup. These audit
pages and scripts are excluded from the distributable ZIP.

Sources: [CloudKit Web Services](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html),
[Apple's current JS client](https://cdn.apple-cloudkit.com/ck/2/cloudkit.js),
[Chromium alarms](https://developer.chrome.com/docs/extensions/reference/api/alarms),
[Chromium identity](https://developer.chrome.com/docs/extensions/reference/api/identity).
