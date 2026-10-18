# Shared tabs with iCloud

Mobile preview renderers stay attached behind an opaque black cover. Opening a
panel can shrink the foreground page while a preview is still rendering; the cover
keeps that temporary page out of the exposed backdrop without interrupting capture.

Rise uses the user's existing system iCloud account. There is no Rise account, login
screen or password to enter. Sync is on by default. Both devices need the same iCloud
account and a build signed for the same CloudKit container and environment.

On iOS, open **More → Site settings → App settings → Sync tabs with iCloud**.
The Settings panel uses the existing header, native blue switch and blurred panel
transition. On Mac, use **Rise → Sync Tabs with iCloud**. Turning sync off retains
the local tabs; turning it back on merges local changes with the shared list.

The private CloudKit database in `iCloud.dev.bartosz.Rise`, zone `RiseSharedTabs`,
stores tab IDs, HTTP(S) addresses, titles and order. It also stores learned site-search
names and URL templates in a `RiseSearches` record (`payload: Bytes`), controlled by
the same sync switch. Address learning also syncs normalized HTTP(S) URLs, titles,
visit counts and last-visit times, so both devices use the same learned destinations.
Private browsing never contributes. Cookies, login state and page contents do not sync.
Templates merge per domain by their learning time with deterministic conflict ties;
a saved clear timestamp prevents an offline device from restoring cleared searches.
Existing `searches.json` dictionaries migrate automatically to the version with that
timestamp. Only same-site HTTP(S) templates with one `{q}` substitution are accepted. Selection, page history,
cookies, logins, snapshots, pinned/custom Mac metadata and local files stay on the
device. Ordinary tab opens, navigation, moves and closes sync automatically.

Visit learning uses one `RiseSearches` record per normalized URL (`history-` plus a
SHA-256 identifier) and a separate `history-cleared` marker, reusing the existing
`payload: Bytes` schema. Installation counters merge by maximum before being summed;
receiving a remote count never creates a new visit. Titles have independent versions.
Deleting an item starts a new counter generation; clearing history advances a global
generation. Stale offline counters cannot restore either. New visits after observing
the deletion start at one. Local history arrays migrate once with their original counts
and a persisted installation identity. Both clients retain the 2,000 most recent pages
for history and suggestions. Turning sync off preserves local learning and queues local
edits for reconnection; account changes follow the existing explicit re-enable rule.
Each device keeps its current selection where possible and lazily loads restored
background tabs. Remote updates wait while a mobile panel, Peek, summary or tab
gesture is active.

On iOS, restored and imported background tabs get page previews and favicons without
being selected. A single temporary WebKit page renders them in sequence behind the
browser, using the same cookies and ad-blocking preferences. It cannot play media,
open popups, prompt for permissions or start downloads. Capturing does not navigate
the real tab or change its synced URL/title. New pictures update an already open grid.
Pictures and icons are cached locally in `Library/Caches/TabPreviews`, checked against
the tab's URL on restore and removed when the tab closes. Rendering pauses while the
app is inactive and waits for panels, gestures and tab flights to finish. Failed loads
retain any existing preview and can retry on a later update/foreground activation.

Restored mobile tabs keep their pending destination until WebKit commits a real
document. A failed first load preserves that URL in the address menu and saved
session and shows a native Retry state. Reload explicitly loads the saved URL if
there is no live document; one cancelled startup request can retry automatically.
Web-content process termination marks the tab for restoration again. A transient
`about:blank` before commit cannot erase the saved destination or title.

The local session and sync cache are separate atomic files in Application Support.
`SharedTabsLedger` merges independent content and position versions. Closure
tombstones win over stale offline edits, so an old device cannot reopen a closed
tab. Reopening on Mac creates a new ID. Simultaneous inserts have a deterministic
order. The adapter acknowledges the list only after it has displayed it, so a
deferred remote insert cannot be mistaken for a local close.

`CKSyncEngine` persists its change tokens and pending uploads, retries failures,
and receives CloudKit silent pushes. Foreground activation also fetches changes.
Offline, quota and unavailable-account states retain local tabs and show a short
message under the mobile switch. An account switch disables syncing until the
user explicitly enables it again; this prevents automatically uploading the old
account's tab list into a new account.

## Development signing

Sign in to the Apple Developer account in Xcode. iOS uses automatic signing with
CloudKit, Push Notifications and the remote-notification background mode. Debug
uses the Development CloudKit environment; distribution Release uses Production.

The Mac browser remains the SwiftPM app. The small `scripts/cloudkit-signing`
Xcode target obtains its macOS provisioning profile; it does not build another
browser or change its engine:

```sh
xcodebuild -project scripts/cloudkit-signing/RiseSigning.xcodeproj \
  -scheme RiseSigning -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/cloudkit-signing -allowProvisioningUpdates build
./scripts/restart.sh
```

`sign-app.py` selects a valid macOS profile for Rise's explicit app ID, container,
certificate and Development environment. It retains the local Apple Development
identity and enables CloudKit in the app's Info.plist only when the profile grants
it. It does not claim the restricted browser-passkey entitlement without Apple's
approval. Unsigned/test builds do not create a CloudKit container.

Before shipping through TestFlight/App Store or Developer ID, deploy the `RiseTab`
and `RiseSearches` schemas (`payload: Bytes`) to Production in CloudKit Console and sign both clients
for Production. Local Release Mac builds deliberately use Development, and
`scripts/ios.py` installs both iOS configurations with Development, so a Release
build on the phone still syncs with the Mac. CloudKit environments have separate data.

If a new app ID reports “Invalid bundle ID for container”, verify the container
assignment and refresh automatic signing in Xcode. Apple's registration can take
time to propagate; local tabs and pending changes remain saved meanwhile.

## Verification

```sh
swift test --filter SharedTabs
python3 scripts/test-passkey-signing.py
```

The Mac signing helper also has a live integration check. It uses the same sync
implementation with two clients in a generated `RiseTabsAudit-UUID` private zone,
then deletes only that disposable zone. It checks simultaneous inserts, ordering,
navigation, closure during an offline edit, persistence across relaunch, concurrent
visit counts, repeated sync without count inflation, and visit clear/deletion while offline:
Automatic scheduling is disabled only for these test clients, following Apple's
sample tests; the apps use automatic scheduling during normal use.

```sh
build/cloudkit-signing/Build/Products/Debug/RiseSigning.app/Contents/MacOS/RiseSigning --test-tab-sync
```

`--check-cloudkit` reads account status and zone availability without modifying
browser data. The equivalent opt-in iOS integration test is
`TabSyncTests.testLiveCloudKitMergesTwoClientsAndKeepsClosuresAfterReconnection`,
enabled with `RISE_LIVE_ICLOUD_TESTS=1`. Regular iOS settings and adapter tests use
isolated local stores and preferences.
`TabPreviewTests` also renders distinct HTTP pages on-device, checks the actual pixels
and live grid updates, and verifies that cached cards restore without another page load.

Local diagnostics use the `dev.bartosz.Rise` / `TabSync` log category and the cache's
`lastStatus` / `lastError` fields. A successful manual fetch/send clears the last
error once all pending edits have uploaded.
