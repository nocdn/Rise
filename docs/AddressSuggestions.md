# Shared address suggestions

Mac and iPhone use `RiseCore/AddressSuggestionEngine.swift` for learned URL-prefix
completion, popular sites, open-tab matches, local history frecency, and mixing remote
search suggestions. Literal URLs in remote results also become links, deduplicated by
their normalized destination. Platform adapters only attach icons, commands, and UI behavior.
`BrowsingHistory`, `PopularSites`, `GoogleSearchSuggestions`, `FaviconDiscovery`, and
`SiteSearchLearner` are also shared sources, directly referenced by the iOS target.

Mobile saves bounded history and learned searches beside its browser session. Only
actual foreground-tab navigation/SPA URL changes count as visits; title changes do
not. Preview-only pages have their own delegates and never enter browsing history.

Autocomplete keeps the person's typed text in the native field and draws only its
suggested suffix with a Safari-style blue highlight. No native selection handles
are created and typing/backspace updates it immediately, without a spring. Tap the
field or press Right to accept the completion for editing; Go opens the completed
address. Paste, composition, and middle-of-string edits do not complete. Late
remote answers, row favicons and iCloud template updates preserve typed text and
the suggestion. Exact matching open tabs are reused, including query/fragment.
The input has a fixed left inset and no favicon; result rows retain their favicons.

A searchable site's extra row enters over 0.28 seconds with
0.16 bounce. It uses the same Open Runde Medium typography as other results, its favicon,
and the primary non-neutral colour from that favicon (with a catalog brand colour
as a fallback before the image loads). Tapping enters site-search mode;
Go sends the escaped terms through that site's template. Further keys that still
match the same site keep the row still; UIKit's intermediate cursor notification
during text replacement does not dismiss and re-enter it. X clears terms, then leaves
empty site-search mode. Reduce Motion makes the extra row appear immediately.

Favicon fetches go directly to site origins, without browser cookies or a third-party
favicon service. In-progress literal addresses wait 300 ms before fetching. Icons
are downsampled and cached locally; local/reserved test domains are never fetched.

Learned templates sync through the existing private CloudKit zone. See `TabSync.md`
for conflict merging, account switching, and production schema deployment.

Validation:

- `swift test`: shared ranking, completion, persistence, learning, remote cancellation,
  favicon discovery, and desktop address UI regressions.
- `AddressSuggestionsTests.testNativeInputFaviconsLearningAndSiteSearch` exercises
  the real UIKit field and WebKit bridge. The equivalent isolated debug audit can run
  with `-RiseAddressSuggestionsAudit` when the beta simulator cannot launch XCTest.
  Results and light/dark captures are in `Library/Caches/AddressSuggestionsAudit`.
- The signed `RiseSigning --test-tab-sync` helper exercises two real CloudKit clients
  in a disposable private zone: concurrent learning, clearing during offline edits,
  and new learning after a clear, alongside existing tab-sync checks.
