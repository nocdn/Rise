# Rise for iOS

With no saved session, New Page's plus dialog opens and focuses its search field while
`https://news.ycombinator.com/` loads behind it in a persistent `WKWebView`. Later launches
restore the open tabs in order and resume the selected page behind New Page.
Addresses, titles and selection are saved atomically in Application Support on tab and
navigation changes, including History API changes in background tabs. Scene lifecycle
events flush pending writes; ordinary app updates retain the file. Only the selected
restored tab loads at launch; other tabs retain their saved title/address and load when
selected. Temporary Peek pages and DEBUG replays/audits have no session store. This
restores the selected page and its Back/Forward list, including the current position.
Local WebKit interaction archives retain the engine's session when possible; portable
URL/title history restores tabs received from the Mac and adopted Peek pages.
Returning within five minutes preserves the existing page and panel. After five minutes in
the background, New Page reopens and focuses its search field above the selected page;
no tab is created until a destination is chosen. An already-open search keeps its draft,
selection and private/site-search mode. Incoming links and Home Screen actions take priority,
and presented dialogs and summaries remain intact. Brief inactive transitions such as Control
Centre do not count as time away. The timeout uses a monotonic clock and needs no background timer.
Tabs also form one shared list with the Mac app through the user's existing iCloud
account. Sync is enabled by default under **More → Site settings → App settings**;
there is no app login. See [Shared tabs with iCloud](../../docs/TabSync.md) for the
merge behavior, signing setup and verification.
Web links navigate normally; new-window links use the
same page, and WebKit's native back/forward gestures remain available. UIKit and
WebKit manage safe areas, rotation, the keyboard and scrolling.

Embedded videos play inline instead of opening fullscreen automatically. **More → Site
settings → App settings → Autoplay videos** can also require tapping Play, including for
muted videos. The green video row sits below iCloud sync. Changes apply to existing tabs
and Peeks without reloading; deliberate fullscreen stays available. Long-press a video for
Play/Pause, Mute/Unmute, supported fullscreen/Picture in Picture, and video address,
sharing or download actions when available. The menu also works in embedded frames and
through player overlays. The menu appears at your finger while the video stays embedded
and keeps playing on the page. Nothing is lifted or duplicated, and paused videos stay
paused. See
[Video playback](../../docs/VideoPlayback.md) for WebKit details and verification.

Selecting a time written in another zone, such as "11pm PST", puts it first in the selection
menu in your own time, with its day when that isn't today and how far off it is: "Tomorrow at
07:00 (in 15 hours)". It opens to Copy (the time, dated when it isn't today) and Add to Calendar,
Calendar's own editor filled in with the time and page, which needs no calendar access. The
reading is shared with the Mac's right-click menu (`Sources/RiseCore/SelectionTimes.swift`); a
script in each frame keeps the app told of the selection, as UIKit asks for the menu before the
page could be asked.

Selecting an event, such as an invitation's date, time and location, puts its time first in the
same menu ("Tue 3 Nov, 13:30 – 20:30"), opening to Add to Calendar with Calendar's editor filled
in with its title, place, times and zone, Add to Reminders and Show in Calendar. See
[Selected events](../../docs/SelectionEvents.md).

**More → Site settings → App settings → AI features** enables or disables page questions,
Summarise, and summary follow-ups. It is enabled by default. The joined AI Provider and
API key rows select OpenRouter or OpenAI and save a separate masked key for each provider
in this device's Keychain (not in iCloud or preferences). The key's dots menu checks
authentication without generating an answer; focusing the field reveals the key in system
monospace, while leaving it restores masking dots. Both states fade at the right edge without
an ellipsis, and the field is eight points narrower than the provider selector. Key checks distinguish
invalid credentials and temporary service
failures are distinguished. Requests use the selected provider's GPT-6 Luna with low
reasoning effort. Mobile builds contain no embedded fallback API credential. Local Debug
installs can migrate a development key once via `RISE_AI_OPENROUTER_KEY` in the launch
environment, without including its value in source or the app binary.

As in Arc, the strip behind the status bar takes the colour along the page's top edge
(see Peek below for how it's found), and the page sits just below it. The clock and
icons turn light over dark strips by WCAG contrast. Pulling the page down past its top
fills the gap with the same colour, so the strip just grows; nothing is sampled until
the page settles back.

As in Arc Search, a toolbar spans the bottom edge with a hairline on top: white, or a dark
grey rather than black in dark mode, whatever the page, so its buttons and panels stand out.
The app follows the system's light or dark appearance. Tabs, on the left, shows the top of the current page as a
small square card over a tilted one behind it. New Page, the light grey rounded button in
the middle, grows the bar into a panel with four suggestion rows above the keyboard
(71% of the window's height without a software keyboard), with Peek's quick spring:
its top corners round as it grows, and the page recedes behind it, dimmed, its corners following
the screen's own, as far in as the page has moved, so it never looks cut square into them: they
round the moment the panel starts opening, stay round as the page comes back, and square off
only once it's full size again. The bar's
buttons swap for the panel's contents, and back, as a Motion transition on the web would:
the incoming side fades in, grows from 96% and sharpens from a 1-point blur over 0.27 s
(`cubic-bezier(0.26, 0.08, 0.25, 1)`), while the outgoing side fades in 0.19 s as it shrinks
and blurs. The blur is a blurred snapshot laid over each side, as iOS has no public blur for
live layers. New Page's plus is a little softer than the other symbols. New Page, More and
More's squares share the search field's fill; each shrinks a little while pressed and its
fill darkens, or lightens over dark pages, the plus deepening with it. At the panel's top, an empty "Search or enter URL" field, filled
and rounded like New Page (#F8F9FA, 14-point corners) with semibold rounded text, is
focused at once, so the keyboard comes up alongside. Shaking the phone while typing there clears the field with two sharp taps,
instead of offering to undo the typing. Google's
suggestions appear under it as you type, the latest query's only, each shrinking a little
while pressed. Up to twelve ranked rows share a native scroll view; the fifth starts just
behind the keyboard, with normal row spacing and six points of extra clearance below the
fourth row, and scrolling keeps the field and sheet in place.
The sheet fits shorter visible areas and keeps the last result fully reachable. Changing the
query returns to the top, while late icons/results preserve the scroll position. Site-search
mode preserves the list and its scroll position under the keyboard during the compact transition.
Titles use the standard iOS font at 17 points and medium weight; URL subtitles use the same
face at 12 points and medium weight, with a tighter baseline gap and darker grey in light mode.
Display addresses omit the scheme, leading `www.` and a bare origin's final slash, preserving
paths, queries and fragments; navigation always uses the complete original URL.
Icons sit beside them, including a grey magnifying glass drawn
like the system's bold one, its handle as thick as its ring and about as long.
At the field's end, the address editor's bold X is always there: it clears the
field, clicking once, and on an empty field closes the panel. Clearing clicks once; Go or choosing a suggestion clicks twice in quick succession. Choosing one searches
Google for it; Go opens what was typed as an address when it looks like one
(`example.com`, `https://…`), and searches Google otherwise. Either way the panel quickly grows
up to fill the window as the search fades out and the new page appears inside it,
while the page behind keeps receding at the same rate; the new page then stays as the page, the previous one held for Back (the edge swipe). Swiping the
panel down or tapping the page puts it back without opening anything. Pulling down from the
top of the suggestions also moves the whole panel: a short pull settles back, while a long
pull or downward flick closes it and the keyboard. Upward drags and drags further down the
results keep scrolling normally. Holding New Page searches by voice instead:
a strong, sharp click, then a constant soft haptic hum while it listens, as the plus swaps (with
the icons' blurred swap) for seven fully rounded red bars that rise and fall smoothly with the
microphone's level, tallest in the middle. Letting go opens New Page as a tap would, a small spinner
where the clear button would be until what was said lands in the field, ready for Go. It's
transcribed on the device by iOS's newest speech-to-text model, `SpeechAnalyzer` with
`SpeechTranscriber` (iOS 26 and later; `DictationTranscriber` where that model isn't available),
whose assets are fetched at launch. The first hold asks for the microphone and speech recognition
instead of listening. Web pages' fields get the same dictation from a microphone added to WebKit's
own bar above the keyboard, just before its ✓ (`FormAccessoryDictation.swift`; ↑, ↓ and ✓ stay
WebKit's): tapping it swaps the microphone for the waveform, with the same click and hum, and tapping
again swaps in a spinner until the transcription is typed at the caret, after a space when it
follows a word. Holding it listens until let go instead. More, the ellipsis
circle on the right, grows the bar the same way into a smaller panel, the page
behind receding only as far as that growth takes it at the same rate. Holding More for 0.35 seconds
copies the page's link instead, More's ellipsis turning to a checkmark with a success haptic, as
Copy does, and letting go opens nothing; on a page without a link, the hold opens More as a tap
does. VoiceOver offers the same as More's Copy Link action. The bar's buttons
swap the same way for the page's address, styled like the search field: Back and Forward
close together, each only if there's a page that way, the host behind a green padlock on HTTPS pages, then Reload.
The 14.5-point history chevrons keep their normal tap areas. When the only available direction
changes from Back to Forward or back, the chevron turns a half-circle on a quick, lightly bouncing
0.32-second spring, carrying on from its current angle if reversed before it finishes. Under it,
buttons a little less tall than wide, each just a symbol: Share, Summarise, Find (on page) and Copy (the link). Back and Forward keep the
panel open (Back also returns to a page a Peek or search replaced); Reload, Share and
Copy close it; Summarise is below. A full-width Site settings button sits beneath the four
icons, with its gear and title centred, using their fill, press effects and outline weight.
It swaps More's contents with the same blurred crossfade as returning to the bar, while the panel
grows on the closing spring. Settings has an Open Runde Semibold title at the left and the address
editor's X at the right, returning to More with the same animated swap. Beneath it, a joined group
of two 60-point rows offers Block ads and Block cookie banners in Open Runde Medium,
with the supplied Tabler icons, inset hairline dividers and blue native switches. The ads icon is
red and the cookie icon is orange; switching a protection off mutes its icon to 35% opacity.
The cookie icon is slightly smaller, centred in the same icon column. The rows darken
while pressed without scaling.
Rapid panel changes keep all earlier visible contents in the outgoing fade, so tapping More then
Site settings before the first swap finishes cannot leave the compact toolbar behind.
Both switches default on and apply their independent per-site policies, reloading the page with native progress feedback.
Tapping the page or swiping down still closes the panel.
The Downloads button fills horizontally with translucent light blue while files download.
Progress combines the current batch by byte count when sizes are known; completed files keep
their share until the remaining transfers finish. Unknown sizes reserve a share until measured
or finished. Updates animate from the visible fill over 0.25 s. Completion fills the button,
then fades it back to normal over 0.18 s; a new transfer safely interrupts that fade.
The flying row produces one sharp impact when it reaches More. Each
successful WebKit completion plays three brief rising haptic pulses. Concurrent completions
queue separate patterns; confirming, cancelling, failing or restoring a saved file does not
play completion feedback. Files and the finished list retain their existing storage paths.
Cancelling removes the row immediately and deletes the partial file after WebKit stops
writing, including a cancellation before the destination is handed over. Its filename stays
reserved until cleanup completes, so cleanup cannot delete a newer transfer's file.
Downloads supports UIKit's native two-finger selection interaction, including range
selection, deselection and edge autoscrolling. Its collection cells host the same download
row views, retaining their existing icon/checkbox blur and scale transitions. Tapping a file
icon enters Multi Select and checks that file; row taps toggle selection while editing.
History shares this native range-selection list, its check-circle drawing and the title's
compact three-dot menu. History's Multi Select shifts favicons and titles 32 points right,
leaving check circles in the original favicon column; Done reverses that motion. Two-finger
dragging enters selection directly, and row taps toggle checks without opening a page.
The menu also selects all visits or deletes only the selected visits. Selection follows URL
identity across refreshes and reuse; updates wait for an active range to finish. Reopening
History starts outside selection. Individual swipe deletion is disabled while selecting.
Arrivals and removals during a range gesture wait until it ends, preserving selection by ID.
The sheet always opens at its original compact height. A drag or flick snaps between that
height and a taller detent, about 80% of the window and slightly higher than New Page.
Dragging stops at those two limits; it cannot dismiss or stretch Downloads. Long lists scroll
at the tall detent, and scrolling back to the top allows a downward sheet drag. X returns to
More from either height using the existing blurred swap, keeping outgoing rows in place.
The native interaction follows [Apple's two-finger selection sample](https://developer.apple.com/documentation/uikit/selecting-multiple-items-with-a-two-finger-pan-gesture).
Search and Downloads dragging hold the display's maximum refresh request, up to 120 Hz,
through the release spring. Search closing commits its motion before keyboard resignation
and blurred-copy preparation. The last 20 panel drag/frame records are saved after settling;
`python3 scripts/panel-motion-log.py --simulator <UDID>` (or `--device <ID>`) reads them.
See [Motion.md](../../docs/Motion.md) for measurements and the distinction between callback
gaps and rendered animation hitches.
Tapping the address grows More into a New Page-sized
editor on the same spring, receding the page further while the tiles blur and fade away. The
address bar itself stays intact: the full URL slides from the center to the left as the sheet
grows, the padlock and history buttons fade, and Reload swaps to a clear X with the same blur,
scale and fade as Send/Stop. X clears the address, and on an empty field closes the dialog,
leaving the page as it was. The keyboard starts opening immediately on tapping, with the full
URL selected, while the sheet and label spring into place. Input during the spring appears
immediately and keeps its caret when the animation finishes. Editing uses the same suggestions
as New Page; Go navigates the current tab, while
clearing or dismissing preserves its page. Find swaps the panel's contents, with the same blurred
crossfade and spring, for a single "Find on Page" field styled like the search field, the panel
moving to sit just above the keyboard as the page comes forward again, undimmed, to show its
matches. It's laid out like the Mac's find bar: the current match and the count ("4/5") at the
field's right end, with a little air either side of the slash, then, a little apart, Previous
and Next chevrons, which shrink while pressed like the other buttons. Typing highlights every match in the page, the count changing at once; Next, Return
and Previous step through them, the current match's number rolling over with SwiftUI's numeric
text transition, and the page scrolling the match into what shows above the panel. No matches
turns the text red; Return switches a completed search with no matches into Ask, retaining the query
without submitting it. An empty field replaces the counter and chevrons with Ask; clearing a search immediately
restores that empty state and removes the page highlights. The compact filled Ask/Find button
switches its title immediately while its width and position spring: left to
make room for Send, then back to the right to return to Find. The inline SwiftUI titles and
counter ignore window safe-area insets, keeping them centered inside the field. Ask changes
the placeholder to "Ask about the Page". Send stays grey until the question contains text;
while a response is running its icon changes to `stop.circle.fill` with a 0.3-second blur,
fade and scale transition. Once an answer finishes, Send stays grey until the question is
edited, as sending it again would repeat the answer, and tapping the field selects the question
to replace; a failed answer can be retried at once. Return or the send button submits the question, which shimmers while
the answer streams underneath in the same panel. The panel grows as each visible line appears,
without reserving space for queued words; longer answers scroll within the capped height.
The desktop's shared OpenRouter client uses
`gpt-6-luna` and the existing development key; its word scheduler and color transitions also
drive the mobile answer, with light Markdown and no model attribution. Supporting passages
are highlighted in the page and kept above the panel. Stop cancels a request; Find returns to
page search. Closing clears the answer, conversation and passage highlight.
Tapping the page closes it and takes the highlights off, leaving the page
where it was scrolled to. The highlighting, counting and stepping run in the page, through
the Mac's `PageFind` (`Sources/Rise/PageFind.swift`, shared into the iOS target). Each button taps with a light, crisp haptic as the
finger lands, and acts as it lifts. Scrolling down collapses the bar to a thin empty strip; scrolling up,
reaching either end of the page or tapping the strip opens it again. Pages scroll clear
of the open bar through extra safe area.

New Page opens what's chosen in a new tab after the current one. Tabs opens an Arc-style
horizontal deck over Rise's solid warm grey (#F3F1F0, or #1A1918 in dark mode). The current
page shrinks towards the right while older tabs rise from the bottom-left toolbar stack,
with a smooth, quick 0.3–0.4 s transition and no incoming bounce. Large cards are 70% of
screen width, overlap, and compress behind the focused card's left edge.
Swipe horizontally to bring each page forward; native momentum snaps to a card. This local
recent-tab display order does not reorder the shared iCloud tab list.

Favicons sit above each card, aligned with the page’s left edge; only the centred card shows
its title text. Cards to the left subtly shrink by 2% per step, equally at the top and
bottom, with a progressively darker overlay (14% per step, up to 36%). The centred card
and cards to its right stay full size and undimmed. Pages have the device's generously
rounded corners from their very first moving frame, for both button entry and swipe-up;
they ease towards
22-point card corners. A subtle shadow forms during the flight and hands over at landing.
Pressing a card shrinks it to 97%, then opens immediately from its actual visible size.
The small light close button and an upward card swipe both close its tab. A swiped tab
stays opaque until it leaves the screen. During the drag, the tab behind moves forward
to the right, grows and loses its depth shading. Releasing eases it into place on the
app's soft spring; cancelling eases it back. The offscreen tab's removal does not restart
that spring or delay the remaining cards' movement.
Cancelling that swipe springs it back, and the last tab stays. VoiceOver can scroll horizontally and close
cards through separate targets or the Close Tab custom action.

The bottom bar stays, with New Page and More. More in the switcher contains only History,
using the usual animated sheet/contents swap and the URL row's width, 48-point height,
14-point corners, press fill, scale and haptic. History expands that surface to 80% of the
screen, with a heading, X and scrollable suggestion-style rows. X or a left-edge swipe returns
to the switcher's menu. The same left-edge gesture returns from Downloads and both Settings
panels, using their X buttons' return route and starting as soon as a swipe is recognized.
Vertical drags rubber-band back to History's resting height. Horizontal row
swipes delete visits, with light resistance and a small pull on the neighbouring two pairs of
rows. A soft haptic at the threshold releases those neighbours onto a spring while the selected
row springs to the live finger position; reversing reconnects them and restores resistance. The
swiped row fades and carries its displayed velocity offscreen on release, before
the list closes the gap. Deleted visits also leave history-based suggestions. More over a live
page keeps the page menu.

Swiping up anywhere on the bottom bar still shrinks the page under the finger. Its bottom
edge and horizontal touch anchor follow the finger; its corners start at the screen's own
radius. Letting go past a quarter of the travel or flicking commits, carrying position,
size, crop and corner velocity onto the deck's own springs without a release haptic. A short
swipe springs back. Reversing a flight, catching it with the bottom-bar swipe, or swiping
horizontally during entry continues from the displayed pose. Explicit 120 Hz keyframes
keep the page and rising stack moving while WebKit draws its deferred thumbnail; a rate
hold also covers finger tracking and horizontal scrolling. Summarise's springs are unchanged.
See `docs/Motion.md` for the reference measurements and `-RiseTabDeckAudit` for native checks.

Pull down from the top of the page to reload. An eight-spoke spinner charges up one
spoke at a time in the gap, complete at 115 points, while light haptic ticks every
5 points follow the pull both ways, stronger the closer it gets. Reaching the threshold
lands as one firm click. Letting go past it reloads: the gap stays open while the
spinner turns, for at least half a second, then the page slides back up. The pull
follows the scroll view's own pan gesture, leaving WebKit's scrolling untouched; the
held gap is extra top inset on the scroll view.

Long-press an HTTP or HTTPS link to **Peek**: an interactive page opens in a card
that springs up from the bottom over the dimmed page, inset 10 points from the window's
edges and 80% of its height. The original page keeps its history, forms and scroll
position. The card has no bar or buttons, only a handle in a thin strip above the page.
The strip takes the colour along the page's top edge, so it reads as part of the page:
the colour painted there when most of the edge agrees on one, otherwise the site's
theme colour, then WebKit's background. It's sampled after loads and paints and while
scrolling. Holding the handle lengthens and darkens it with the springs of the Mac's
split handle. Its invisible touch area reaches a little into the page.

- Drag the card down by its handle, or by the page once it is scrolled to the top. Let go
  past 30% of the way, or flick, to dismiss; otherwise it springs back. Tapping outside
  the card also dismisses it.
- Drag the handle up and the card grows towards the whole window. Let go past halfway,
  or flick up, and it quickly fills the window and becomes the page, as expanding a Peek
  does on the Mac. The Peek's live page moves in without loading again, keeping its
  scroll position, forms and history.
- The page it replaced is held for Back: swiping in from the left edge at the start of
  the new page's history slides back to it.

VoiceOver's escape gesture closes Peek, and the handle offers Close and Open as page
actions. Peek shares the normal cookie store and input-zoom policy. Its own long-press
menus retain WebKit's suggested actions instead of creating nested sheets. Images and
non-web links also keep their suggested actions. The page behind can also recede
(`PeekPresentationController.recedesPage`); that's off for now.

Link detection uses [WebKit's context-menu delegate](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:contextmenuconfigurationforelement:completionhandler:));
presentation uses a [custom UIKit presentation controller](https://developer.apple.com/documentation/uikit/uipresentationcontroller)
with spring animations, so the card and the page behind can follow the same drag.

In dark mode, a new page is see-through until it first paints, as on the Mac (`PagePaint.swift`),
so the dark surface behind it shows instead of the white WebKit fills an unpainted page with.
Once painted it's opaque again, so pages without a background of their own still get white, and
the status bar strip samples its top then. Later navigations keep showing the old page until the
new one paints, so they don't flash either.

Download starts also throw a miniature download row from the original page touch into More,
which absorbs it with a small directional spring kick and the single start haptic at impact.
Concurrent throws coexist and normal
button press feedback remains independent. Reduce Motion skips the throw. See
[Download motion](../../docs/DownloadMotion.md) for the reference measurements and checks.

## Summarise

As in Arc Search, pinching in on the page, from its smallest zoom, summarises it. As when pinching
into Safari's tabs, the page follows the fingers at their scale, the spot pinched staying under
them wherever they go, giving a little past its limits, while its corners round at once and it
crops to its top and tips back a little as it shrinks towards the card over a pale backdrop where a
green and a pink glow circle each other. Let go smaller than 85%, or while shrinking quickly, it
flies from wherever it is to the card at the top, carrying on at the speed it was going in scale
and position, coasting the way the fingers were going before it curves round to its place: a
gentle pinch glides into place, while a hard one shoots smaller than the card and springs back up
to it. Let go otherwise, it springs back to the page. Summarise in More takes the
page into the card the same way on its own. The bottom bar drops away, speeding up, as it goes.
The card shows the top of the page, with another card peeking out behind, and swings gently from side to side while the shared OpenRouter
model (`gpt-6-luna`) reads the page, a soft haptic hum running meanwhile, as when holding New
Page. When the summary arrives, the reveal waits for the swing to pass the middle: the card
settles, growing a little, the hum ends in one short, strong, dull hit, and the summary's
paragraph and key points, each beside a blue symbol, fade in from a heavy blur one after another
as the glows settle. Everything scrolls together over the backdrop. Tapping the card grows it back
into the page, uncropping as it grows, as the summary fades and sinks back a little and the bar
springs back. On the way back, or springing back from a short pinch, a pinch catches it at once
from wherever it is, as in Safari, and let go it takes it back into the card, showing the summary
it already had again once it lands. Fingers can still move the page underneath, two of them
panning it as they pinch, or touches reaching it as the card grows back, so its scroll and zoom
are put back as the card showed them before it takes over again; once Summarise has the pinch,
WebKit's own zoom and scrolling are ended. The card is a replica of the page from `snapshotView`, quick
enough not to hold up the pinch's first frames, and the haptic engine starts away from the main
thread for the same reason. The motion runs at up to 120 Hz
on ProMotion iPhones (`CADisableMinimumFrameDurationOnPhone`). The timings, springs and sizes were
measured from a recording of Arc Search frame by frame and tuned in `Playgrounds/summarise.html`;
`SummariseMotion` holds them, noting where the app has since moved on from the playground.
`docs/Motion.md` records everything learned about this motion and the tab switcher's: the
measurements, the physics, what was tried and removed, and the preferences behind it.

Each Summarise is logged on the device: its events (the pinch, letting go, the summary arriving,
the reveal, the close with what the page underneath was doing, the finish) and its frames, every
one while things move fast and the dropped ones otherwise, with half a second of the page's own
frames after the card has grown back. The last 40 are kept in the app's caches.
The browser reuses one SwiftUI text host, keeping it hidden in the same window between summaries,
while each scene gets a fresh model and request. Closing releases the scene and page replica;
the haptic engine's audio-session teardown runs off the main thread. This avoids the text-view
and audio cleanup stalling the first frames of the live page.
`python3 scripts/summarise-log.py --device <iPhone> [--last N]` fetches them and reports, for each,
what happened when, every phase's frame rate, and each dropped frame with what happened near it.

## Project layout

- `Rise.xcodeproj`: native Xcode project with a shared `RiseiOS` scheme and folder-synchronized source groups. Add Swift files to `Rise` or `RiseTests` without maintaining file lists or running a project generator.
- `Rise`: iOS-only scene lifecycle, web view and input-zoom policy.
- `RiseTests`: local WebKit regression fixtures, including a control that reproduces small-input focus zoom on a real iPhone.
- `Configuration/Base.xcconfig`: deployment and signing defaults. The app supports iOS 17 and later on iPhone and iPad.
- `../../Assets/AppIcon`: the original photo and shared Icon Composer document used by both platforms.

The macOS app stays in the root Swift package. Future platform-independent browser
logic can live in `Sources/RiseCore`; UIKit and AppKit view code remain in their own
platform targets. No new third-party dependencies are required.

## Build and install

Open `Apps/iOS/Rise.xcodeproj` in Xcode 26 or later, select `RiseiOS`, choose your
iPhone, and run. The phone must be paired, unlocked and have Developer Mode enabled.
Automatic signing uses the existing development team; select your own team in
Xcode or override it with `--team` when using the scripts.

From the repository root, the same restart entry point handles physical iOS builds:

```sh
./scripts/restart.sh --ios --device "Your iPhone"
```

For a Simulator, pass its UDID from `xcrun simctl list devices available` instead. The
script boots it, builds into `build/ios-simulator`, installs and relaunches the app:

```sh
./scripts/restart.sh --ios --simulator "Simulator UDID"
python3 scripts/ios.py test --simulator "Simulator UDID"
```

Names, hardware UDIDs and CoreDevice identifiers are accepted. To build without
installing, or run the WebKit checks on your paired phone:

```sh
python3 scripts/ios.py build
python3 scripts/ios.py test --device "Your iPhone"
```

Use `--configuration Release` for a release build, or add `--console` to the restart
command to stream app logs while debugging. Build products and local signing
profiles are ignored by Git; the source project, scheme and original icon are tracked.

`BrowserSessionTests` exercises ordered atomic saves, invalid/corrupt records, tab opening
and closing, selection, background History API/title changes, lazy restoration, and Peek
adoption/Back using real on-device WebKit and HTTP. All four tests passed on iPhone 14 Pro
on 13 October 2026, alongside the existing address-editing, Peek and fresh-launch checks.
The existing `testTabsShrinkIntoCardsUnderTheBarAndASwipeUpDropsThePageIn` timing check
failed on both this build and an isolated build of the preceding commit (`c2956b5`).
The normal phone session's tab identities, addresses and selection also survived installation
and relaunch with the restart script.

## Input focus and zoom

The injected script caps focus zoom at the page's declared initial scale (normally 1),
or its initial rendered auto-fit scale when none is declared,
preserving the other viewport directives and the site's input fonts. It repairs later
viewport insertions and replacements. `ignoresViewportScaleLimits = true` keeps
manual pinch zoom available. This uses public WebKit APIs and ordinary viewport
metadata; it does not disable zoom gestures or use private selectors.

The script runs in WebKit's isolated client content world at document end and applies
again when viewport metadata changes. It does not inject a device-width layout into
sites that omitted one. Desktop-width pages keep their auto-fit scale and mobile
pages such as Hacker News stay at their declared initial scale. The physical-device test compares an unmodified
12-pixel input with the same input under this policy, checks that the font remains
12 pixels, and checks the native pinch gesture and zoom range remain enabled.

See [WebKit's scaling guidance](https://webkit.org/blog/7367/new-interaction-behaviors-in-ios-10/),
the [WebKit focus-zoom change](https://bugs.webkit.org/show_bug.cgi?id=162471), and
[Apple's configuration API](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/ignoresviewportscalelimits).

## Browser engine

This app uses the system WebKit engine. Apple permits alternative engines through
special entitlements for qualifying distribution in the [European Union](https://developer.apple.com/support/alternative-browser-engines/)
and [Japan](https://developer.apple.com/support/alternative-browser-engines-jp/).
Those regional entitlements and a separate engine are outside this initial app.
