# Rise for iOS

On a fresh launch, New Page's plus dialog opens and focuses its search field while
`https://news.ycombinator.com/` loads behind it in a persistent `WKWebView`. This happens
once for a newly created scene, including relaunching after the process was killed.
Returning to the app while it's still in memory preserves the existing page and panel.
Web links navigate normally; new-window links use the
same page, and WebKit's native back/forward gestures remain available. UIKit and
WebKit manage safe areas, rotation, the keyboard and scrolling.

As in Arc, the strip behind the status bar takes the colour along the page's top edge
(see Peek below for how it's found), and the page sits just below it. The clock and
icons turn light over dark strips by WCAG contrast. Pulling the page down past its top
fills the gap with the same colour, so the strip just grows; nothing is sampled until
the page settles back.

As in Arc Search, a toolbar spans the bottom edge with a hairline on top: white, or a dark
grey rather than black in dark mode, whatever the page, so its buttons and panels stand out.
The app follows the system's light or dark appearance. Tabs, on the left, shows the top of the current page as a
small square card over a tilted one behind it. New Page, the light grey rounded button in
the middle, grows the bar into a panel 70% of the window's height, with Peek's quick spring:
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
while pressed. They're set in [Open Runde](https://github.com/lauridskern/open-runde) Medium,
bundled with its SIL Open Font License in `Rise/Fonts`, beside a grey magnifying glass drawn
like the system's bold one, its handle as thick as its ring and about as long.
At the field's end, the address editor's bold X is always there: it clears the
field, clicking once, and on an empty field closes the panel. Clearing clicks once; Go or choosing a suggestion clicks twice in quick succession. Choosing one searches
Google for it; Go opens what was typed as an address when it looks like one
(`example.com`, `https://…`), and searches Google otherwise. Either way the panel quickly grows
up to fill the window as the search fades out and the new page appears inside it,
while the page behind keeps receding at the same rate; the new page then stays as the page, the previous one held for Back (the edge swipe). Swiping the
panel down or tapping the page puts it back without opening anything. Holding New Page searches by voice instead:
a strong, sharp click, then a constant soft haptic hum while it listens, as the plus swaps (with
the icons' blurred swap) for seven fully rounded red bars that rise and fall smoothly with the
microphone's level, tallest in the middle. Letting go opens New Page as a tap would, a small spinner
where the clear button would be until what was said lands in the field, ready for Go. It's
transcribed on the device by iOS's newest speech-to-text model, `SpeechAnalyzer` with
`SpeechTranscriber` (iOS 26 and later; `DictationTranscriber` where that model isn't available),
whose assets are fetched at launch. The first hold asks for the microphone and speech recognition
instead of listening. More, the ellipsis
circle on the right, grows the bar the same way into a smaller panel, the page
behind receding only as far as that growth takes it at the same rate. The bar's buttons
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
of 60-point rows offers Block ads, Block trackers and Block cookie banners in Open Runde Medium,
with the supplied Tabler icons, inset hairline dividers and blue native switches. The ads icon is
red, trackers orange and cookies green; switching a protection off mutes its icon to 35% opacity.
Tracker and cookie icons are slightly smaller, centred in the same icon column. The rows darken
while pressed without scaling.
Rapid panel changes keep all earlier visible contents in the outgoing fade, so tapping More then
Site settings before the first swap finishes cannot leave the compact toolbar behind.
The switches start on and only change their appearance for now; WebKit's protections are unchanged.
Tapping the page or swiping down still closes the panel.
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

New Page opens what's chosen in a new tab after the current one. Tabs shrinks the page into a
Safari-style tab switcher over a solid, faintly warm grey (#F3F1F0, or #1A1918 in dark mode),
there from the start rather than a blur of the page that would be slow to come in: the page
springs into its card in a two-column grid as the other cards fade, grow and sharpen in
around it, their titles revealed last, each with the page's favicon in line with it. As on the
Mac, the icon's corners are clipped a little (4 points in 16), so square icons round off, and a
page without one shows a blank grey square. Icons are the first bitmap the page declares that
loads (SVGs can't be drawn here), else the site's `favicon.ico`. The bottom bar stays, with New
Page and More, and Tabs becomes a rounded square filled like them that shows how many tabs there
are. Tapping a card grows it back into the page; its close button closes the tab (the last one
stays). A swipe up anywhere on the bottom bar, even starting on New Page, shrinks the page with
the finger, as Summarise's pinch does: its bottom edge follows the finger and the spot across
from where it started stays under it, its corners the screen's own from the start and easing to
the card's, the page cropping towards its card
as it goes, its title riding under it and fading in, with the others', over the last part of the
way. The drag and flight are held at 120 Hz on ProMotion iPhones. Let go past a quarter of the
way or flicked, it flies on at the speed it was going, including its crop and corners, and curves
round into its card on Summarise's springs without a release haptic, a hard flick shrinking past the card's
size first; a short one springs back. Each flight is worked out as it starts and played by Core
Animation, so it carries on smoothly while the app is busy, as when New Page is
pressed straight after Tabs and brings the keyboard up; the page flies as a quick copy of the
screen, and its card's picture is drawn once it's on its way. Every move
turns around from wherever it has got to, carrying on from its speed, so Tabs can be pressed as
quickly as wanted: a page landing in its card can be tapped to grow it back, and a swipe up as a
card grows back catches the page where it is. Going back to the page, the titles fade out quickly.

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

## Summarise

As in Arc Search, pinching in on the page, from its smallest zoom, summarises it. As when pinching
into Safari's tabs, the page follows the fingers at their scale, the spot pinched staying under
them wherever they go, giving a little past its limits, while its corners round at once and it
crops to its top and tips back a little as it shrinks towards the card over a pale backdrop where a
purple and a pink glow circle each other. Let go smaller than 85%, or while shrinking quickly, it
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
