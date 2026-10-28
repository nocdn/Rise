# Shared address suggestions

Mac and iPhone use `RiseCore/AddressSuggestionEngine.swift` for learned URL-prefix
completion, popular sites, open-tab matches, local history frecency, and mixing remote
search suggestions. Literal URLs in remote results also become links, deduplicated by
their normalized destination. Platform adapters only attach icons, commands, and UI behavior. The engine takes any `SearchProvider`
(a name and a search-address builder); the iPhone passes Google or Kagi, the Mac the default
search engine chosen in Chrome's settings.
`BrowsingHistory`, `PopularSites`, `GoogleSearchSuggestions`, `FaviconDiscovery`, and
`SiteSearchLearner` are also shared sources, directly referenced by the iOS target.

Mobile saves bounded history and learned searches beside its browser session. Only
actual foreground-tab navigation/SPA URL changes count as visits; title changes do
not. Preview-only pages have their own delegates and never enter browsing history.

The most frequent/recent literal URL match can complete a stable page path after repeat
visits, so a regularly used `voxi.co.uk/account` can outrank `voxi.co.uk`. One-off deep
links and query-bearing URLs still complete only the site until a path is typed.
Login redirects and query-bearing search pages still count toward which site is preferred,
but do not dilute a stable page's share when choosing its usual path. Both platforms give
extra weight to an address chosen in the field, including switching to an already-open tab.
One address choice alone does not establish a preferred path. Private choices and ordinary
searches do not create typed-address evidence; never-loaded failed addresses lose it.
This uses saved visit counts on both platforms without resetting existing learning.
Learned literal addresses can complete from the first character, so repeated visits to
`x.com` let `x` immediately fill `.com`. Literal prefixes outrank title/substring matches
even for one character. Unvisited sites in the built-in catalog still require two characters.
Those counts, page addresses, titles and recency also sync through the existing iCloud
switch. Per-installation counters prevent repeated syncs from inflating frequency;
clear and deletion generations prevent stale offline clients from restoring removed visits.

Autocomplete keeps the person's typed text in the native field and draws only its
suggested suffix with a Safari-style blue highlight. No native selection handles
are created and typing/backspace updates it immediately, without a spring. Tap the
field or press Right to accept the completion for editing; Go opens the completed
address. Paste, composition, and middle-of-string edits do not complete. Late
remote answers, row favicons and iCloud template updates preserve typed text and
the suggestion. Exact matching open tabs are reused, including query/fragment.
The input has a fixed left inset and no favicon; result rows retain their favicons.

A searchable site's extra row appears and disappears immediately as the query changes,
like the other suggestions. All rows are 56 pt tall, including single-line searches
and site searches; link titles and subtitles form a centred group with a slightly tighter gap.
The search and URL-editing panel fills 73% of the window. The site row uses the same
standard iOS typography as other results, its favicon,
and the primary non-neutral colour from that favicon (with a catalog brand colour
as a fallback before the image loads). Tapping enters site-search mode;
Go sends the escaped terms through that site's template. Further keys that still
match the same site keep the row still; UIKit's intermediate cursor notification
during text replacement does not dismiss and re-enter it. X leaves site-search mode. Selecting the site row springs the panel down to the input
just above the keyboard and brings the page forward at the same rate. Its placeholder
names the selected site, with its name in the favicon's brand colour at 45% opacity
and the prefix in the native placeholder colour. The suggestions retain their full-sized
views below the input while compact, covered by the keyboard; they do not accept touches
or VoiceOver focus there. Expanding carries these same rows up with the sheet, without
animating their widths or recreating them. X exits this mode even when terms are present, restores
the original typed prefix, completion and cursor position alongside the full panel
and suggestions, and keeps input focus. Its sole haptic comes from
the bar's touch-down feedback. Compact site search follows keyboard height changes,
including hardware keyboards. Normal search keeps its 73% panel height.

ChatGPT, Claude and Gemini offer **Ask** instead of Search (on the Mac, **Ask ChatGPT [Tab]**,
**Ask Claude [Tab]**, **Ask Gemini [Tab]**). Enter opens a fresh chat in the signed-in web
account and submits the prompt through its composer. A prompt is passed as a script argument,
never through a prefill query string; visiting a normal chat URL does not submit anything.
Typing an assistant's name keeps this offer ahead of old prefill URLs and conversation history;
an explicit conversation path can still be completed normally.

`RiseCore/AssistantPrompt.swift` waits for the composer and its enabled send button to settle,
including client hydration and editor replacement. It supports ChatGPT's textarea/ProseMirror,
Claude's ProseMirror, Gemini's Quill, and Gemini's account-indexed URLs. Existing different drafts
and new user input stop the pending action. Each request clicks Send once; an ambiguous result
is never retried automatically. Navigation away, authentication screens and a 45-second timeout
stop it, with a way to copy the prompt if sending was unavailable. Initial Chromium new-tab
navigation is allowed to finish before the assistant's origin is checked.

Rows retain their content positions and touch bounds while their pressed fill extends
6 pt beyond each horizontal edge; the original colour, scale and release effect remain.

Favicon fetches go directly to site origins, without browser cookies or a third-party
favicon service. In-progress literal addresses wait 300 ms before fetching. Icons
are downsampled and cached locally; local/reserved test domains are never fetched.

Learned templates and address learning sync through the existing private CloudKit zone. See `TabSync.md`
for conflict merging, account switching, and production schema deployment.

Validation:

- `scripts/test.sh --filter 'AssistantPrompt|AddressSuggestion|PopularSites'`: Ask routing,
  history precedence, origin and path checks, cancellation, and native field behavior.
- `python3 scripts/test-chromium-live.py Tests/Live/ChromiumAssistantPromptChecks.swift`: real
  Chromium fixtures for all three composers, delayed hydration, remounting, disabled Send,
  existing drafts, multiline Unicode, repeated evaluation and unacknowledged submissions.

- `swift test`: shared ranking, completion, persistence, learning, remote cancellation,
  favicon discovery, and desktop address UI regressions.
- `AddressSuggestionsTests.testNativeInputFaviconsLearningAndSiteSearch` exercises
  the real UIKit field and WebKit bridge. The equivalent isolated debug audit can run
  with `-RiseAddressSuggestionsAudit` when the beta simulator cannot launch XCTest.
  Results and light/dark captures are in `Library/Caches/AddressSuggestionsAudit`.
- The signed `RiseSigning --test-tab-sync` helper exercises two real CloudKit clients
  in a disposable private zone: concurrent learning, clearing during offline edits,
  and new learning after a clear, alongside existing tab-sync checks.
