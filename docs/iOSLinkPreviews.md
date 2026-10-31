# Interactive native link previews

Holding an HTTP(S) text link supplies a `LinkPreviewController` through WebKit's
native `UIContextMenuConfiguration`. UIKit owns the preview card, menu, glass,
placement and presentation/dismissal animations. WebKit's suggested actions still
go through `nativeLinkMenu`, including GitHub star/unstar status. Images, video
menus and external schemes retain their existing handling. The old custom Peek
sheet remains disabled and its implementation is retained.

The preview contains its own live `WKWebView`, using the held link's source page's
exact `WKWebsiteDataStore`, ad/cookie protections and video policy. It does not
register with address suggestions, create a tab, sync or record browsing history.
Private previews therefore use their source's nonpersistent session. Scrolling,
ordinary page controls and HTTP(S) navigation stay inside the preview. Deliberate
GET links targeting a new window also navigate inside it. Script-created windows,
external apps, downloads, JavaScript dialogs and media permission requests do not
open from a preview. Dismissing stops loading and media and releases its delegates.
The original page and its scroll offset stay intact.

UIKit's preview-commit callback opens the same live page in the source tab, should
the system choose its ordinary tap-to-open preview behavior. It transfers the
existing page rather than reloading its URL.

## Native interaction compatibility

Apple's public preview-provider API does not expose UIKit's interactive-preview
style flag. `InteractiveLinkMenu` isolates the internal compatibility work: it
subclasses only the particular web view's native `UIContextMenuInteraction` instance,
forwards its original presentation implementation unchanged, and adjusts a copy of
that presentation's style to enable `hasInteractivePreview` and prevent snapshot
rasterization. It does not replace WebKit's delegate, gestures, hit testing or
native actions, and does not globally swizzle a framework class.

Newer WebKit owns its menu interaction through its text-interaction wrapper; the
helper reaches it via the guarded `WKContentView.contextMenuInteraction` getter,
with the direct-view-interaction path retained for older runtimes. The same lookup
keeps the GitHub status row updating on these menus. Every private selector is
checked before use; unsupported runtimes retain an ordinary native preview.
These are private UIKit/WebKit hooks, not App Store-safe public API guarantees.

References: [Apple's context-menu configuration](https://developer.apple.com/documentation/uikit/uicontextmenuconfiguration),
[WebKit's native context-menu implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/WKContentViewInteraction.mm).

## Simulator checks

Launch the debug app with `-RiseLinkPreviewAudit` for a real-link fixture and manual
long-press/scroll check. `-RiseLinkPreviewAutoAudit` additionally presents the same
app configuration directly in UIKit, without HID injection. It checks live native
presentation, that hit testing reaches WebKit within the preview, scrolling while
the menu remains open, working page JavaScript, session cookies, private-store
isolation, absence from browsing history, source preservation and teardown. It also
checks that WebKit's own interaction gets the scoped compatibility hook.

Results and before/after native-window renders are written to
`Library/Caches/LinkPreviewAudit`. The automatic check does not claim to reproduce a
physical long press or swipe: this Mac's Simulator desktop app was missing, and
Device-panel access was disabled during implementation.
