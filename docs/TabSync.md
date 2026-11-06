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
stores tab IDs, HTTP(S) addresses, titles, order, when each tab was last used and on which
days, whether it's archived or kept (see [Archiving unused tabs](TabArchive.md)), and each tab's
Back/Forward URL/title entries with its current position. It also stores learned site-search
names and URL templates in a `RiseSearches` record (`payload: Bytes`), controlled by
the same sync switch. Address learning also syncs normalized HTTP(S) URLs, titles,
visit counts and last-visit times, so both devices use the same learned destinations.
Private browsing never contributes. Cookies, login state and page contents do not sync.
Templates merge per domain by their learning time with deterministic conflict ties;
a saved clear timestamp prevents an offline device from restoring cleared searches.
Existing `searches.json` dictionaries migrate automatically to the version with that
timestamp. Only same-site HTTP(S) templates with one `{q}` substitution are accepted. Selection, engine session archives,
cookies, logins, snapshots, pinned/custom Mac metadata and local files stay on the
device. Ordinary tab opens, navigation, moves and closes sync automatically.

Back/Forward history travels with the tab's address as one versioned update. Repeated
visits to the same URL remain distinct entries. Both directions survive relaunch and
cross-engine restoration; only the selected destination loads during restoration.
Each history is bounded to 100 entries around the current position and 750 KB encoded.
Local/internal URLs and addresses containing credentials are excluded. Historical form
values, POST bodies, cookies and login state do not transfer between devices.

Installing an update retains the local session. Deleting and reinstalling the app can
recover history already uploaded to iCloud, using the same account, container and
environment with sync enabled. Unsynced offline changes cannot survive deletion of the
app's data. Older clients without this field can update a title at the same URL without
erasing history received from a newer client. See [Navigation history](NavigationHistory.md).

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

On iOS, a remote closure applies to the active page too: it closes and the first tab
in the list takes its place, or a blank page if every tab closed. Private tabs stay.
On Mac, remote closures never take away the active page, including when the other
device closes every tab: the same live page and its local session stay in place,
while background closures and inserts still apply (`SharedTabsReconciliation`). The
retained page keeps its original identity and its closure tombstone, so it cannot
reopen itself on the other device. A later sync can remove it once it is in the
background; closing it locally still works.
`-RiseTabSyncAudit` checks the iOS adapter with an isolated WebKit page, a remote
close of the active page, repeated close-all updates and session restoration.

On Mac, dormant synced and restored tabs fill missing titles and favicons through
three bounded HTTP metadata workers. They reuse the existing light/dark favicon
cache, including declared CDN icons, and persist the results with the local session.
Custom names and actual titles received from the phone take precedence over the
public HTML title; redirecting to a different site's login cannot replace them.
These requests do not start Chromium pages, execute scripts, select tabs or add
history visits. Navigating, opening or closing a tab cancels its stale work. Failed
page requests retry with backoff from 30 seconds to five minutes. Local addresses,
files, internal pages and addresses with embedded credentials are excluded.

On iOS, restored and imported background tabs get page previews and favicons without
being selected. At most two temporary WebKit pages render them behind the browser,
using the same cookies and ad-blocking preferences. Independent, bounded first-party
favicon requests fill icons before slow pages finish. The focused card and its neighbours
get preview priority over offscreen tabs. The temporary pages cannot play media, open
popups, prompt for permissions or start downloads. Capturing does not navigate
the real tab or change its synced URL/title. New pictures update an already open grid.
Pictures and icons are cached locally in `Library/Caches/TabPreviews`, checked against
the tab's URL on restore and removed when the tab closes. Rendering pauses while the
app is inactive and waits for panels, horizontal scrolling, close gestures and tab flights
to finish. Captures begin after document commit, without waiting for slow adverts or
subresources, and retry empty frames while client-rendered content paints. Uniform blank
cached images are rejected. Failed page/icon loads retry automatically after 30 seconds,
backing off to at most once every five minutes, without needing another sync event;
favicon-only cache entries survive a relaunch too.

`-RiseTabPreviewAudit` runs isolated real-HTTP checks for batch imports, early favicons,
slow resources, delayed client rendering, blank-cache recovery and automatic retry. It
also verifies that previews update the open deck, keep real tabs lazy, preserve shared
titles/URLs and selection, and restore from the local cache without reloading pages.

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
and receives CloudKit silent pushes. Foreground activation also fetches changes; on
iOS, after at least a minute in the background it recreates the engine from its saved
state, as a launch does, since silent pushes aren't guaranteed and a phone suspended
overnight was seen not to fetch on resuming.
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

The two schemas were deployed to Production on 22 October 2026. CloudKit Console
confirmed the deployment and the Production `RiseTab.payload` Bytes field. A
Release test build signed for the Production container passed the live two-client
iPhone test for inserts, navigation, closure and offline reconnection. This does
not move Development data or switch local Mac builds to Production.

If a new app ID reports “Invalid bundle ID for container”, verify the container
assignment and refresh automatic signing in Xcode. Apple's registration can take
time to propagate; local tabs and pending changes remain saved meanwhile.

## Verification

```sh
./scripts/test.sh --filter 'SharedTabs|SyncedTabMetadata'
python3 scripts/test-chromium-live.py Tests/Live/ChromiumSyncedTabsChecks.swift
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

## Windows / Chromium extension

[**Rise Tab Sync**](../Extensions/RiseSync/README.md) lives in
`Extensions/RiseSync`. Its toolbar popup connects one regular Chromium window to
this same private CloudKit ledger, using Apple's web sign-in and the native merge
rules. Web client tokens are preconfigured for both environments; setup requires
only choosing a window, matching the apps' environment and signing in to iCloud.
There is no companion process or full-page setup UI. See the extension README for
installation, browser-specific limitations, tests and ZIP packaging.
