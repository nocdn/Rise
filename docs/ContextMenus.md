# Website and browser context menus

Normal right-click keeps the website's context menu. **Shift–right-click** bypasses
the website menu and opens Rise's native menu for the actual clicked element, including
Download Video, Copy Link and the usual text-editing actions where applicable.

`NativeContextMenuOverride` is installed at document start in an isolated script world
on every Chromium page and frame, including cross-origin frames and popups. It stops
the website's trusted secondary-pointer/context-menu handlers for that gesture without
canceling Chromium's default action. Mouse-up remains covered if Shift is released
mid-click. Primary clicks, ordinary right-clicks and synthetic page events are unchanged.
The existing native context-menu/download bridge retains the clicked document's context.

Players such as X put transparent controls in front of their video. For this gesture,
Rise briefly lets hit testing pass through those controls within the clicked player,
including when the video itself has pointer events disabled. Chromium then builds its
real media menu. The original styles are restored as soon as the menu opens; ordinary
clicks and unrelated dialogs keep their usual behavior.

X's MediaSource blobs cannot be saved as files. When Download Video is chosen on X,
`ContextMenuVideoSource` reads the clicked player's own rendition metadata and chooses
the highest-bitrate complete MP4. This runs only for that action, matches the original
blob exactly, and accepts only HTTPS MP4s on `video.twimg.com`. The download still uses
Chromium's normal download list and animation. Ordinary file/blob downloads are unchanged.

This follows [Firefox's Shift–right-click convention](https://developer.mozilla.org/en-US/docs/Web/API/Element/contextmenu_event).

Validation: `python3 scripts/test-chromium-live.py Tests/Live/ChromiumContextMenuOverrideChecks.swift`.

Selected text also offers **Encode → Base64** near the end of the native menu on
desktop and iOS. Readable UTF-8 Base64 has a separate **Decode Base64** submenu,
with **Copy Decoded Value** and a disabled, shortened preview. Standard and URL-safe
Base64, omitted padding and wrapped lines are supported by the shared
`SelectionBase64` implementation. Encoding preserves the exact selected text,
including whitespace. Clipboard actions use the existing notice/toast with the QR
icon; conversion stays on-device. Inputs above 64 KiB and binary decoded payloads
are omitted from these text utilities.

Decode and Encode share one section on both platforms. On iOS, the decode copy
action is labeled **Copy Value**, and selection menus use Rise's translation glyph
while preserving the native Translate command and its responder routing. Desktop's
menus and URL-bar copy notice use the same lighter QR finder outlines as iOS menus.

Hovering a GitHub repository link shows a native mini spinner in the normal link
pill, then an outlined or filled star for the signed-in account's state. Shift's
Peek hint keeps its existing layout. An existing GitHub page can answer with a
read-only authenticated GET. Otherwise, or if raw HTML omits the current state,
the live offscreen repository page uses the same hydrated control recognition as
starring, without pressing it. It waits for a fresh document even at the same URL,
and records lookup diagnostics in `github-star.log`. It starts after a 150 ms dwell,
caches known states for 15 seconds, and ignores late results for departed links.
Signed-out, failed and unavailable lookups leave the pill plain; starring from
Rise updates its cached result immediately.

The desktop **Page** menu follows Edit and holds **Dismiss Cookie Banners**,
**Automatic PiP**, and **Preload Links on Hover** as checkable actions. Cookie
dismissal defaults off on desktop; Automatic PiP and link preloading default on.
Cookie dismissal and PiP follow the current site, while preloading is browser-wide.
Explicit choices persist. The site-controls popover has no Settings heading or
the former four toggles; Developer Mode remains in Develop. iOS keeps its existing
cookie-dismissal default.
