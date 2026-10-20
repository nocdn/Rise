# Video playback on iOS

Embedded videos stay within the page. Rise enables WebKit inline playback and supplies
`playsinline` and `webkit-playsinline` before scripted playback, including detached player
probes. A document-start script runs in every frame and watches parser-created videos,
later insertions, removed inline attributes, and open or closed shadow roots. Standard
and legacy fullscreen APIs require a real tap or keyboard action in that input's task;
WebKit's native fullscreen control remains available.

**More → Site settings → App settings → Autoplay videos** allows automatic playback by
default. Switching it off removes video autoplay attributes, rejects automatic `play()`
requests with `NotAllowedError`, and pauses automatic playback already in progress.
Native and website Play controls still work. Playback approval belongs to the selected
video source, so changing the URL or stream does not approve the next video. Audio retains
WebKit's native audible-playback gesture requirement.

The preference is local and persists across launches. `VideoPlaybackPolicy` updates all
tracked live pages, including private tabs, Peeks, and pages retained for Back, without
reloading them. Parent-to-child messages update cross-origin/nested frames; new frames
request their parent's current value to cover a navigation racing a setting change.
Replacing just Rise's playback user script preserves the viewport and protection scripts
for subsequent navigations. Re-enabling autoplay allows the site's next playback attempt
and restores autoplay attributes Rise removed; it does not force every paused player to run.

Long-pressing a video opens a native context menu with Play/Pause, Mute/Unmute and
supported fullscreen/Picture in Picture actions. HTTP(S) sources also offer Copy Video
Address and Share Video; progressive, unencrypted sources can use Download Video through
the page's existing WebKit download pipeline. Blob/MediaStream players and HLS/DASH
playlists retain playback actions without offering a misleading file download. The download
response must also contain a video/binary media type, so an extensionless playlist or
redirect to an HTML login page is rejected before creating a file.

The menu probes the touched position through nested frames and closed/open shadow roots,
including overlays above the video. Native scroll movement cancels the target. The selected
element and source are revalidated before each command, so an old menu cannot control a
replacement video. Explicit native commands use a per-policy capability and approve only
their selected video; they do not grant a new autoplay window to unrelated players.
Native image menus and the existing link Peek remain available. Pending tab-sync updates
wait until the video menu closes. The touch probe supplies the menu state synchronously to
UIKit, avoiding a deferred page query and menu resizing during presentation. The
menu is anchored to the finger using a transparent, noninteractive one-point view. Only
that empty anchor participates in UIKit's preview transitions: WebKit and the video never
leave their original hierarchy, get clipped, or become a drag preview. There are no page
snapshots, placeholder layers, extra media requests, seeking or playback-state changes.
The anchor is removed when native dismissal finishes or an unfinished interaction is
cancelled. Symbols are resolved before the first long press, and
share/download prompts wait for the menu dismissal animation to finish. For a video with
only metadata loaded, selecting fullscreen/Picture in Picture first starts playback and
waits for its first frame: presenting AVKit before a frame is loaded can leave its entry
transition stuck, even in an otherwise unmodified WKWebView.

## WebKit research

- [Apple: allowsInlineMediaPlayback](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/allowsinlinemediaplayback)
  requires both the native configuration and a video inline attribute on iPhone.
- [WebKit: New video policies for iOS](https://webkit.org/blog/6784/new-video-policies-for-ios/)
  explains automatic fullscreen without `playsinline`, visibility-triggered muted autoplay,
  and the distinction between autoplay and inline playback.
- [WebKit bug 238605](https://bugs.webkit.org/show_bug.cgi?id=238605) reports the same
  unexpected iframe fullscreen behavior, including detached autoplay-detection videos;
  its reporter resolved it by adding `playsinline`.
- [Apple: mediaTypesRequiringUserActionForPlayback](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/mediatypesrequiringuseractionforplayback)
  supplies the native media gesture policy. The app keeps `.audio`; the video script
  also handles muted autoplay and live preference changes on existing web views.
- [WebKit's WKWebView implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm)
  passes `forceUserGesture:YES` for public JavaScript evaluation APIs. Rise additionally
  requires trusted page input, so browser-injected scripts cannot authorize autoplay or
  fullscreen. Pointer movement/cancellation distinguishes scrolling from a tap.

- [Apple: WKContextMenuElementInfo](https://developer.apple.com/documentation/webkit/wkcontextmenuelementinfo)
  exposes a link URL, but no public video target. Rise uses a public UIKit
  `UIContextMenuInteraction` and per-frame WebKit hit-testing for video menus.
- [WebKit: HTMLVideoElement](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/html/HTMLVideoElement.cpp)
  ignores legacy exit requests while its presentation mode is changing. The menu's
  metadata-only regression also checks that explicit fullscreen can return inline.
- [Apple: UITargetedPreview](https://developer.apple.com/documentation/uikit/uitargetedpreview/init(view:parameters:))
  identifies the view UIKit animates. Rise supplies an empty finger anchor rather than
  the page. An empty [shadowPath](https://developer.apple.com/documentation/uikit/uipreviewparameters/shadowpath)
  also removes the anchor's preview shadow.

## Verification

`Apps/iOS/RiseTests/VideoPlaybackTests.swift` uses the desktop tests' existing MP4 fixture
as a test-only resource. It checks real playback and fullscreen state, parser/dynamic/
detached videos, removed attributes, closed shadow roots, opaque-origin data frames,
initial blank frames, template clones, scroll callbacks, synthetic clicks, live switch
changes, navigation, persistence, private browsing, and settings layout.

On 19 October 2026, all four fixtures passed in a temporary in-app harness on the iPhone
17 Pro / iOS 27 simulator. Native computer-use checks also verified native Play, a website
Play button, deliberate fullscreen, blocked scroll playback, and blocked playback after a
source change. The normal XCTest runner could not connect to the simulator's Apple test
service (`DTServiceHubClient failed to bless service hub`); the in-app harness ran the same
fixture bodies without that service and was removed after verification.

`Apps/iOS/RiseTests/VideoContextMenuTests.swift` covers explicit commands with autoplay
disabled, invalid authorization, independent playback approval, source/MediaStream changes,
removed elements, overlays and closed shadow roots, transformed opaque-origin frames,
stream/download exclusions, rejected HTML/playlist/error responses, image/link hit-testing,
and entry/exit from fullscreen followed by a blocked unsolicited fullscreen request.

On 20 October 2026, all eight context-menu fixtures and all four playback fixtures passed
in the temporary in-app harness on the same simulator. Native computer use verified the
menu on ordinary videos and player overlays, inline Play/Pause, and deliberate fullscreen
entry. The harness and its copied MP4 were removed before the signed device build.
A subsequent preview regression run passed all nine context-menu fixtures and the four
playback fixtures. Before/after simulator recordings reproduced the blank background with
the old page-sized preview and its removal with the detached crop. Six contact sheets
cover 276 consecutive captured frames across three opening/dismissal cycles, including a
partly scrolled-off video. The page remains visible and the dismissal white flash is gone.
Native UIKit owns the transitions; the crop took 2.9–4.8 ms in the instrumented run and
cached action creation stayed below 0.11 ms. These are simulator measurements, not a
physical-device frame-rate guarantee. Temporary animation instrumentation was also removed.
The live-preview follow-up replaces the frozen video crop with the original live WebKit
renderer and masks the selected video out of the page stand-in. Native preview tests check
background retention, that cutout, clipping and idempotent cleanup. Temporary native-menu
recordings also sample the actual media playhead and paused state before, during and after
holds, including videos clipped against the top or bottom of the viewport and paused media.
All five native-menu cycles opened successfully: four kept advancing their media playhead
before, during and after the hold, and the paused case stayed paused. A further 144
consecutive recording frames cover normal and clipped opening/dismissal transitions;
the background stays visible and only one video appears. All 13 WebKit fixtures passed.
The retained XCTest targets compile with `build-for-testing`.

The subsequent menu-only version removes the video lift and page stand-in completely.
All 13 WebKit fixtures passed again. Five native-menu cycles verified unchanged page
parent, frame, transform, subviews and mask during presentation and after dismissal;
four playing videos advanced continuously and a paused video stayed paused. After each
cycle, the video and two surrounding elements all moved by the same 100-point scroll.
Another 144 consecutive frames cover normal and clipped menu opening/dismissal, with
the video staying embedded throughout. The temporary probes and copied MP4 were removed
before the signed physical-device build.

Run the regression tests when the local XCTest service is available:

```sh
xcodebuild -project Apps/iOS/Rise.xcodeproj -scheme RiseiOS \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -only-testing:RiseiOSTests/VideoPlaybackTests \
  -only-testing:RiseiOSTests/VideoContextMenuTests test
```
