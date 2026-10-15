# Plan: Rise on its own Chromium fork, without CEF

Where Rise goes after CEF: a fork of Chromium in which every Rise window is a real Chrome
browser window, with real Chrome tabs, while Rise's own AppKit interface and motion stay
exactly as they are. Arc built its browser this way. Helium (a restyled Chrome) and staying on
CEF are the alternatives this was weighed against.

## Why

On CEF, Rise's pages are CEF's "Alloy" pages: they can sit inside Rise's views, but they aren't
Chrome tabs. Every Chrome feature that expects a tab has to be bridged one by one, as the
extensions work did (`cef/0006`–`0009`, `chromium/0004`–`0005`). Still unbridged: extension side
panels, commands and context menu items, `windows.create`, passwords and autofill, Chrome's
permission prompts, the memory saver, session restore. CEF's own direction is its "Chrome"
style, which can't be embedded on macOS, so the style Rise depends on gets less attention, and
each Chrome release reaches Rise only once CEF has caught up.

With a real `Browser` behind each window, those features work as they do in Chrome, and
Chrome's security fixes ship as soon as Chrome's do.

## The shape of it

- **Rise stays the app.** Rise's `main`, its `NSApplication`, menus, windows and every view stay
  Rise's. Chromium is built as a framework (as Chrome's own "Google Chrome Framework" is), which
  Rise starts inside its process.
- **A Rise window is a Chrome `Browser`** with a `RiseBrowserWindow`: Rise's implementation of
  Chrome's `BrowserWindow` interface (72 methods today), in place of Chrome's `BrowserView`.
  Chrome draws no window, toolbar or tab strip. The `Browser`'s tab strip holds Rise's tabs, in
  Rise's order.
- **A tab's page goes where Rise puts it.** Each tab's `WebContents` view is handed to Rise,
  which places it in its own views, as `RCBrowserView` is placed now, so Peek, split, ⌘Z and live
  resizing work as they do today.
- **A thin engine API of Rise's own** replaces CEF: Objective-C, in a new `src/rise/` directory
  in the Chromium tree. New files, so they don't conflict on updates. Small, focused hooks in
  Chrome's code where there's no other way in.
- **Rise's code barely changes.** Rise talks to its engine through `WebPage`. A new
  implementation replaces `ChromiumPage`'s CEF one, and the interface code above it stays.

## Stages

Each stage ends at a gate; the live checks that exist today (`peek`, `features`, `extensions`)
are most of them.

0. **Spike: the motion gate again.** Chromium built as a framework, started from a Rise-owned
   `main` with Rise's `NSApplication`; one `Browser` with a `RiseBrowserWindow`; one tab's page in
   a Rise view. It passes the Peek, split, ⌘Z and handle-drag frame comparisons that CEF passed in
   stage 3. **Stop here if it can't.** Then nothing else is worth doing.
   **Result (passed).** The fork's patches are `Engine/fork/patches/` (on Chromium 156.0.8078.17).
   `RISE_ENGINE_FORK=1 ./scripts/build.sh` makes `build/RiseFork.app`, and
   `RISE_ENGINE_FORK=1 python3 scripts/test-chromium-live.py peek` checks it. All 14 Peek checks
   pass, three runs in a row. Frame by frame, every scene matches CEF's as closely as CEF's
   matched WebKit's, or closer. A page loading in a Peek first shows at about 0.15 s, as on CEF
   and before WebKit. What it took:
   - **A flag for an embedder's window:** Chrome allows a window of someone else's only in
     tests, so `BrowserWindowCreateParams` gets an `embedder_window` flag.
   - **The full-screen context:** Rise's window is its own `ExclusiveAccessContext`. Chrome's
     input handling reached for it on the first mouse move: the first of stage 4's reach-ins.
   - **Making the app first:** Rise makes the app before Chrome reads its command line, so
     Chrome's app class waits until it has before applying its forced text direction.
   - **The exports:** Rise's classes join Chrome's framework export and order lists.

   Two things to know when checking: the first run after a rebuild starts pages slowly while
   macOS checks the newly signed helpers, and Chromium stops drawing pages in a window that's
   behind others, so the check's window must stay in front.

   **One `Browser` per Rise window (done).** `RCTabStrip` owns its window's `Browser`. Tabs move
   into it as Chrome moves dragged tabs between windows, keeping their pages; pages that aren't
   tabs (a Peek, its standby page, DevTools) wait in a hidden `Browser`. What Chrome does to the
   tabs itself (an extension switching, moving, pinning or closing them) is asked of Rise. The
   Peek check still passes three runs in a row and matches CEF. What it took:
   - **Chrome's test paths:** Chrome guards code that only tests' windows (which aren't Chrome's
     own either) should reach with `CHECK_IS_TEST()`, about 400 of them. Rise declares that it
     takes those paths (`base::SetEmbedderTakesTestPaths()`), and each one it takes is logged
     once, for stage 4. `CHECK_IS_NOT_TEST()` still holds.
   - **Empty windows stay open:** Chrome closes and deletes a `Browser` whose last tab leaves.
     Rise's windows say they stay open (`BrowserWindow::StaysOpenWhenEmpty()`), and close the
     way Chrome's do, through `UnloadController::OnWindowClosing()`.
   - **Activation:** Rise's key window tells Chrome's `BrowserActiveStateManager`, so Chrome
     takes it as the current window.
   - **Chrome's history swipe is off:** it took Rise's swipe gesture now and then.

   **Page scripts in Chrome's renderer (done).** Rise's scripts no longer go through DevTools. A
   small agent in each frame (`chrome/renderer/rise`) runs them as each document starts, from
   Chrome's own document-start hook, before the page's scripts and before extensions'. Each
   script gets its own `riseHandlers`, which nothing else in the page can reach. The browser
   sends a frame its scripts, and where its messages go, just before each navigation in it
   commits (`chrome/common/rise/rise_frame.mojom`), so a new document never starts without
   them, in frames of other sites too. Messages say which frame sent them from the browser's
   side, not the page's. Only the page's process needed a hook in Chrome's code: the
   browser hands each frame its connection back to Rise itself. Checked by
   `python3 scripts/test-chromium-live.py scripts`, which passes on the fork. On CEF it shows
   where the DevTools route falls short: scripts in Rise's own worlds run after the page's
   first script, and frames often miss them.

1. **The engine API.** Everything `RiseChromium.h` offers today, on the fork:
   - Navigation, and saving and restoring back and forward history.
   - Sound playing; zoom and pinch.
   - Rise's page scripts and messages, run from Chromium's renderer instead of through
     DevTools: faster, and no DevTools workarounds.
   - Context menus, dialogs, file choosers, downloads.
   - Permissions; find; picture in picture.
   - Windows that pages open; DevTools in Rise's panel.
   - Settings pages; the search engine; ad blocking.
2. **Rise on the fork.** The new `ChromiumPage`; the `features` and `peek` live checks pass.
3. **Real extensions.** The bridging goes: `ExtensionWindow`, `cef/0006`–`0009`,
   `chromium/0004`–`0005`. Rise's Arc-style buttons read Chrome's own toolbar model. Popups use
   Chrome's real popup host, shown in Rise's popover. The Web Store's own install button should
   then work, with the store's "Switch to Chrome" prompts hidden. The `extensions` live check
   passes, plus uBlock Origin Lite, Dark Reader and Bitwarden by hand.
4. **Where Chrome reaches into its own window.** Today 116 files in `chrome/browser` look for
   Chrome's `BrowserView` (45 outside `ui/views`). Each is sorted into one of three groups:
   - **Not needed:** interface Rise replaces (bubbles, toolbar, side panel). Nothing to do.
   - **Needs Rise's version:** Rise provides its own.
   - **Harmless:** the code does nothing when there's no `BrowserView`.

   A script lists them, and a Chrome update that adds one is flagged before it ships.
5. **Chrome features Rise now gets.** Decide, one by one, what Rise shows: Rise's own permission
   prompts, password and autofill (or none, as now), extension side panels in Rise's sidebar,
   Chrome's memory saver.
6. **Data.** CEF already keeps a Chrome profile directory, so Rise's Chromium profile should
   carry over as it is. WebKit-era data comes over as planned in the original stage 6.
7. **Release.** As planned: signing and notarizing the nested helpers, and licence notices.
   Plus the update routine below.

## Updating Chromium, every four weeks

1. Move to the new Chrome stable branch, and take Chrome's weekly security fixes in between.
2. Re-apply Rise's patches. Most of Rise is new files in `src/rise/`, so few conflict.
3. Fix compile errors from Chrome's window interface. These are loud and cheap: over the last
   year, `browser_window.h` changed 43 times, three or four times a release, mostly a method added
   or removed.
4. Run the `BrowserView` list script. Any new place Chrome reaches into its own window gets
   sorted before release. This is the quiet kind of breakage, so the script is what catches it.
5. Run the live checks.

## Risks

- **Chrome doesn't support replacing its window code.** That's what stages 0 and 4 are for,
  and what the update routine watches. It's shrinking: Chrome's own "bedrock" work, which moves
  code from `Browser` to `BrowserWindowInterface`, keeps removing these reach-ins (it removed
  `GetBrowserForMigrationOnly` this year). Chrome for desktop Android already runs windows with
  no `BrowserView` at all.
- **Chrome's Views dialogs need somewhere to go.** Some Chrome dialogs still use Chrome's own
  toolkit. Each either becomes a Rise sheet, or gets an anchor in Rise's window through
  `GetWebContentsModalDialogHostForWindow`.
- **Two app controllers.** Chrome's `AppController` owns menus and windows on macOS; Rise's does
  too. Chrome's is stubbed out, and what it does that Rise needs (handoff, the dock menu, URLs
  opened from other apps) is done by Rise.
- **Unchanged from CEF:** Widevine needs Google's approval. Google sign-in and sync need keys
  Google won't give. Passkeys need Apple's entitlement.

## What carries over from the CEF work

- **Rise's side:** `WebPage`, all of Rise's interface code, including the extension buttons and
  the install sheet.
- **Checks:** the live checks and the motion comparisons.
- **Engine patches and scripts:** the settings patches (`chromium/0002`–`0003`), branding, and the
  build and patch scripts, minus CEF.

What goes: CEF, `cef/0001`–`0009`, `chromium/0004`–`0005`, and the DevTools-protocol route for
page scripts.
