# Shared address suggestions

Mac and iPhone use `RiseCore/AddressSuggestionEngine.swift` for learned URL-prefix
completion, popular sites, open-tab matches, local history frecency, and mixing remote
search suggestions. Literal URLs in remote results also become links, deduplicated by
their normalized destination. Platform adapters only attach icons, commands, and UI behavior. The engine takes any `SearchProvider`
(a name and a search-address builder); the iPhone passes Google or Kagi, the Mac the default
search engine chosen in Chrome's settings.
`BrowsingHistory`, `PopularSites`, `GoogleSearchSuggestions`, `FaviconDiscovery`, and
`SiteSearchLearner` are also shared sources, directly referenced by the iOS target.

On desktop, browser commands appear only after a leading `/`. Typing `/` lists available
actions by how often they have been used; `/zoom` or `/settings` filters that list by
title and keywords. Removing the slash immediately restores ordinary address and search
suggestions. Command mode cancels remote search suggestions and never searches the web
for an unmatched command. Zoom, theme and capture choices keep their existing submenus;
only executing an action or choosing a submenu option counts toward its ranking.
Counts are saved locally in `command-usage.json` beside the desktop session.
Hidden aliases cover everyday descriptions, such as `/side-by-side` for Split View,
`/night mode` for Change Theme, `/snapshot` for Capture Page and `/add-ons` for Extensions.
Aliases ignore case and punctuation, keep the normal action titles and usage ranking,
and follow toggle state (for example, `hide sidebar` versus `show sidebar`).
The command list includes every available action and scrolls within the bounded panel.
Filtering starts at the top, shrinks the panel to fit the matches, and explains when no
commands match. `⌘↑` selects and reveals the first option in commands, their submenus,
and ordinary address/search suggestions.

The desktop address palette and tab switcher share one `PanelVeil` view: the same
light/dark dim and the palette's existing 150 ms entry and 60 ms exit fades. Dismissal
releases pointer handling immediately; reopening or moving between panels cancels a
pending exit without stacking overlays. Reduce Motion skips both animations.

Mobile saves bounded history and learned searches beside its browser session. Only
actual foreground-tab navigation/SPA URL changes count as visits; title changes do
not. Preview-only pages have their own delegates and never enter browsing history.

With the input empty, both platforms show current habits rather than lifetime visit-count
leaders: frequency loses half its weight after a week without use, with a separate recent-use
boost that halves after two days. Frequency is logarithmic and capped for this list, so an old
testing session cannot pin a page indefinitely. Choosing an already-open address also refreshes
its relevance. Saved counts and typed-prefix/path completion keep their existing behaviour.
The list shows the best actual destination per site, grouping www and HTTP/HTTPS variants while
keeping different apps/subdomains and ports separate. Search results and authentication handoffs
are left out of blank-panel shortcuts but remain searchable. Open tabs backfill missing sites;
the built-in starter links appear only when no personal destinations are available. This reads
the current history each time the panel opens, including synced visits and persisted learning.

The most frequent/recent literal URL match can complete a stable page path after repeat
visits, so a regularly used `voxi.co.uk/account` can outrank `voxi.co.uk`. One-off deep
links and query-bearing URLs still complete only the site until a path is typed.
An address typed repeatedly completes even when a site's many pages share its weight,
as with a console used through several sub-pages; typing it in full leaves it unchanged
rather than filling in a deeper page.
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
On iOS, light and dark artwork is kept in a native image asset, so visible suggestion,
history and tab icons follow their view's appearance, including private panels. Both
variants survive relaunch; existing suggestion caches upgrade when next displayed.
Legacy GitHub tab previews reload their icons while retaining their cached pictures.
Desktop resolves SVG root presentation rules as well as appearance media rules, including
ChatGPT's white dark-mode logo. Fully transparent images are rejected, and older blank
cached variants fall back to the site's visible icon during restoration.

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
- `MobileFaviconTests` covers appearance switching, declared media variants and cache
  migration. `-RiseMobileFaviconAudit` runs the same checks without XCTest and captures
  GitHub's published light/dark icons in `Library/Caches/MobileFaviconAudit`.
- The signed `RiseSigning --test-tab-sync` helper exercises two real CloudKit clients
  in a disposable private zone: concurrent learning, clearing during offline edits,
  and new learning after a clear, alongside existing tab-sync checks.
