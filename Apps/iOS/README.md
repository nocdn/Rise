# Rise for iOS

This first version opens `https://news.ycombinator.com/` in a persistent `WKWebView`.
There is no browser chrome. Web links navigate normally; new-window links use the
same page, and WebKit's native back/forward gestures remain available. UIKit and
WebKit manage the status bar, safe areas, rotation, keyboard and scrolling.

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
