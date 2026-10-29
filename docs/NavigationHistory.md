# Per-tab navigation history

A tab saves and syncs its ordered HTTP(S) URL/title entries and current index. This is
separate from address learning and visit counts. Duplicate URLs are distinct visits;
Back and Forward change the cursor even if the visible address stays the same.

`TabNavigationHistory` validates the current entry, filters unsafe destinations, and
keeps up to 100 entries around the cursor. A second 750,000-byte JSON limit leaves
space for CloudKit record metadata even for unusually long escaped URLs and titles.
The current URL and history are captured from the same committed native list, so a
provisional URL notification cannot overwrite the session with a mismatched pair.

On Mac, Chromium's local navigation archive retains the engine's page state. The
portable representation uses `NavigationController` entries and `SerializedNavigationEntry`
when importing another engine's history. It loads only the selected destination.
Pending background tabs retain the supplied history until selected. Held Peek pages
are flattened into one route for persistence; releasing an old live page retains its
URLs, so Back can reload it after the three-page live retention limit. A tab that sleeps
(`TabSleep.swift`) becomes such a pending tab again: it keeps the engine's page state it
had, and only tabs holding no Peek pages sleep, so nothing is flattened.

On iOS, `WKWebView.interactionState` is saved locally as bounded opaque Data and restored
using the public setter, which starts loading the selected item. Archives containing
private restoration placeholders are not saved. For imported or flattened histories,
a per-web-view `WKURLSchemeHandler` serves a private UUID origin. Native-injected
`replaceState`/`pushState` creates the list without loading historical sites, then
moves to the saved cursor. Each placeholder uses `location.replace` to load its URL
when visited, preserving native toolbar/swipe and script-based history traversal.
The handler permits only its own origin/path, and decoded destinations must be HTTP(S)
without credentials. The helper sends no referrer. Internal documents never enter
address learning or shared tabs. The startup cancellation recovery timer ignores the
bootstrap-to-website handoff, which can wait for content blocking rules.

A new navigation, including a same-URL `pushState`, abandons held Forward pages.
Reload and traversal keep them. Adopted pages retain native history-change observers;
search-learning bridges transfer ownership without registering duplicate handlers.

The shared ledger versions URL, title and portable history together. History-only
changes sync; title-only changes retain an already loaded page. Closure tombstones
continue to win over offline edits. Native archives, cookies, POST bodies and form
values remain local. A fresh install fetches already-synced history from iCloud;
local data that never uploaded is lost if the app is deleted.

Verification includes `TabNavigationHistoryTests`, Mac `NavigationHistoryTests`,
iOS `NavigationHistoryTests`, and the signed CloudKit helper's `--test-tab-sync` audit.
`python3 scripts/test-chromium-live.py Tests/Live/ChromiumNavigationHistoryChecks.swift`
exercises actual Chromium restoration, cross-origin traversal, same-URL entries and
the history retained after evicting live Peek pages.
The CloudKit audit uses a disposable private zone and checks actual transport,
history-only edits, duplicate URLs, both directions, cursor recovery with an empty
cache, offline conflict behavior and cleanup.

References: [Apple interactionState](https://developer.apple.com/documentation/webkit/wkwebview/interactionstate),
[WebKit's public API implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm),
and [Firefox's history restoration notes](https://github.com/mozilla-mobile/firefox-ios/wiki/History-Restoration-in-WKWebView-(and-Error-Pages)).
