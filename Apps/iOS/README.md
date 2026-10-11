# Rise for iOS

This first version opens `https://news.ycombinator.com/` in a persistent `WKWebView`.
There is no browser chrome. Web links navigate normally; new-window links use the
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
its top corners round as it grows, and the page recedes behind it, dimmed. The bar's
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
Clearing the field clicks once; Go or choosing a suggestion clicks twice in quick succession. Choosing one searches
Google for it; Go opens what was typed as an address when it looks like one
(`example.com`, `https://…`), and searches Google otherwise. Either way the panel quickly grows
up to fill the window as the search fades out and the new page appears inside it,
while the page behind keeps receding at the same rate; the new page then stays as the page, the previous one held for Back (the edge swipe). Swiping the
panel down or tapping the page puts it back without opening anything. More, the ellipsis
circle on the right, grows the bar the same way into a panel about a third as tall, the page
behind receding only as far as that growth takes it at the same rate. The bar's buttons
swap the same way for the page's address, styled like the search field: Back and Forward
close together, each only if there's a page that way, the host behind a green padlock on HTTPS pages, then Reload. Under it,
square buttons Share, Pin, Find (on page) and Copy (the link), labelled in rounded type. Back and Forward keep the
panel open (Back also returns to a page a Peek or search replaced); Reload, Share, Find and
Copy close it. Pin
and tapping the address do nothing yet. Each button taps with a light, crisp haptic as the
finger lands, and acts as it lifts. Tabs doesn't do anything yet. Scrolling down collapses the bar to a thin empty strip; scrolling up,
reaching either end of the page or tapping the strip opens it again. Pages scroll clear
of the open bar through extra safe area.

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
