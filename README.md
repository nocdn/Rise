# Rise

A native macOS browser written in **AppKit + WKWebView**, with Arc-inspired chrome matched to the supplied Retina screenshots. No SwiftUI, Electron, or external dependencies. Requires macOS 14 or later.

## Build and run

```sh
./scripts/build.sh
```

The signed local app is `build/Rise.app`. Double-click it in Finder. For development, open `Package.swift` in Xcode or use `swift build`. Run checks with `swift test`.

## Implemented

- 228-point resizable sidebar; system-owned Liquid Glass traffic lights aligned with the native titlebar navigation controls. The buttons have a muted gray appearance at rest and restore their native colors immediately when hovering over the group. They stay enabled and keep native close/minimize/fullscreen behavior. The page has a 7-point inset and a rounded, shadowed surface.
- Neutral gray and rose themes, sampled from the reference screenshots; distinct selected and hovered tabs, with a soft selection shadow.
- Dark mode, selectable from the bottom palette menu, uses Dia’s sampled sidebar gradient (`#363636` → `#2B2B2B`), selected tabs (`#1E1E1E`), and text colors. Address pills, popup/hover surfaces, and accents are matching extrapolations. Native controls and websites supporting `prefers-color-scheme` receive the dark appearance; the chosen theme persists across launches.
- Compact 37-point tab rows with 4-point gaps, continuous rounded corners, and subtle selection shadows (white in dark mode). Light-mode tab hover backgrounds use `#D7D5D4`. Two-line developer tabs are 40 points tall for more space inside the construction border, with unchanged fonts and line spacing. Long addresses fade at the right edge instead of ending in an ellipsis.
- Sidebar closes and opens instantly with ⌘B (⌘S remains an alias). Closing hides the toolbar and native window controls, leaving the page inside a uniform 7-point inset. New Tab uses the same rounded hover background as inactive tabs.
- Control-Tab switches in recently visited order. Releasing Control within 120 ms commits without showing UI; holding it longer reveals a centered preview switcher with favicons, titles, and cached WebKit screenshots. Control-Shift-Tab cycles backward; releasing Control or clicking a card commits, and Escape cancels. The frozen order stays stable during a gesture, with horizontal scrolling for many tabs. Unvisited restored tabs show a placeholder until a preview is captured.
- Loading/reloading fills each sidebar tab with a soft animated background, smooths progress changes, gently pulses while waiting near completion, and fades away when finished. No progress strip over the page.
- Hovered link destinations appear in a small pill at the page’s lower-left corner, including in Peek and split views. A stationary pill with a single 650 ms text shimmer signals a successfully completed preload, including sites that require cache revalidation; failed responses never trigger it. The signal confirms fetching finished, while click speed still depends on the site’s caching. Reduce Motion disables the shimmer.
- Sidebar tabs with page titles and same-origin favicons, an 8-point icon/title gap, and edges aligned with the address pill. Close buttons have a subtle hover background in every theme. Middle-click and release on a tab (including either split half) to close it without first selecting it. Close, duplicate, pin, restore recently closed tabs, and a bottom broom button to clear unpinned tabs.
- Address popup for URLs, Google searches, existing tabs, browsing-history suggestions, and browser actions. The Command-T new-tab/search popup is 400 points wide; editing the current tab's address uses the compact 350-point popup. Suggestions are generated locally.
- URL pill moved slightly lower beneath the titlebar; its popup opens and closes instantly while keeping its soft native shadow and size. Placeholder and entered addresses share the same font; suggestion titles are vertically centered with their icons.
- Two-finger history gestures animate only the existing toolbar arrow, replacing WebKit’s full-page slide. Swipe right for back or left for forward; at 120 points the arrow turns `#007AFF` blue and requests one Generic haptic, then navigates when you lift while still beyond the threshold. Reversing below 120 points removes the blue highlight and cancels navigation; moving past the origin does not switch direction. There is at most one haptic per gesture, including if you cross the threshold again. Arrow compression, increasing resistance past threshold, and release spring (stiffness 600, damping 30) follow the supplied trackpad demo, with more visible arrowhead shortening at toolbar scale. A reversed swipe that reached the threshold still bounces home without navigating; an earlier release returns over 160 ms. Vertical scrolling, horizontal page scrollers, and iframe scrolling remain with WebKit. Momentum cannot trigger navigation, and cancelling or switching tabs cancels the swipe.
- Separate WebKit instances per tab, shared persistent website data, back/forward history, reload/stop, trackpad navigation, zoom, and Find on Page.
- New-window links open in tabs. Command-click opens a tab; Shift-click (or Option-click) opens Peek.
- Optional **Preload Links (Experimental)** in the URL-bar site controls. Hovering over an HTTP(S) link for 150 ms warms the page and its static resources in WebKit’s shared cache, without running page scripts or adding a tab/history entry. Short hovers, downloads, and same-page anchors are skipped. The preference persists and defaults to off. Preloads are limited to two at a time and 32 distinct URLs per minute; switching off cancels pending loads. Cacheable pages open faster; sites that disable caching or depend on JavaScript still load normally. Enabling this uses additional bandwidth and contacts hovered destinations before clicking.
- Peek overlay with close, expand-to-tab, and split controls; two-page split view. Split pairs occupy one sidebar row with two compact favicon/title sections: a divider when inactive, and a softly shadowed rounded container with inset highlights when selected. Clicking either half or page focuses that pane without swapping left/right. Groups remain together when switching tabs and across relaunches; right-click a half to separate the pair. Closing one half leaves the other as a normal tab.
- Developer Mode: striped URL toolbar with an editable address (Enter navigates, Escape cancels), yellow/black selected-tab border, URL copy, screenshot export, JavaScript evaluation, page source, native site-information popover, and split view. Localhost enables it automatically. WKWebView is inspectable from Safari's Develop menu.
- Web dialogs, file-upload panels, downloads with a native save panel, and visible navigation errors.
- Session restoration for URLs, titles, selected tab, pins, theme, developer mode, and sidebar width. Cookies/site storage use WebKit's persistent store. Back/forward stacks, recently closed tabs, and suggestion history are currently session-local.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T | New-tab popup |
| ⌘L | Edit current address |
| ⌘W | Close current tab |
| ⇧⌘T | Restore last closed tab |
| ⌘[ / ⌘] | Back / forward |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌃Tab / ⌃⇧Tab | Recent-tab switcher / reverse; release Control to select |
| ⌘R | Reload / stop |
| ⌘B / ⌘S | Toggle sidebar |
| ⌃D | Toggle developer mode |
| ⇧⌘P | Peek current page |
| ⌘F / ⌘G / ⇧⌘G | Find / next / previous match |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / reset |
| Escape | Dismiss address popup, Find, or Peek |

Use the palette button at the sidebar's bottom to change theme. The broom button clears unpinned tabs; recently closed tabs remain restorable. Right-click a tab to pin, duplicate, split, or close it. Site controls sit beside the compact address pill.

## Scope

This is the first working browsing version, not the full Arc product. Arc account sync, Chromium extensions, multiple spaces/profiles, Boosts, AI features, and Arc's full developer-tool suite are not implemented. The developer toolbar uses native WebKit features; its action set differs from Arc's. The layout and colors follow the references, but pixel-perfect identity across macOS versions is not guaranteed.

Reference behavior: [Arc Developer Mode](https://resources.arc.net/hc/en-us/articles/20468488031511-Developer-Mode-Instant-Dev-Tools), [Arc Pinned Tabs](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around), [Arc Command Bar](https://start.arc.net/command-bar-actions). Engine: [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview).

## Structure

`RiseCore` contains address resolution and persisted session data. `Rise` contains the AppKit window, sidebar, command popup, tab/webview ownership, WebKit delegates, and browser actions. `Tests` covers URL handling, disk persistence, tab lifecycle, split cleanup, restoration, and actual WebKit JavaScript execution.

The preload text shimmer translates [ElevenLabs Shimmering Text](https://github.com/elevenlabs/ui/blob/main/apps/www/registry/elevenlabs-ui/ui/shimmering-text.tsx) to Core Animation: 250% background width, text-length-based spread, and linear text-clipped gradient motion. It runs once in 650 ms instead of the component’s two-second default. Native text rendering and glyph alpha coverage stay the same throughout; a contrasting glint sweeps through the existing strokes in every theme, without changing their weight. See `THIRD_PARTY_NOTICES.md` for the MIT attribution.
