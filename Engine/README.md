# Rise's Chromium engine

Rise keeps its own AppKit interface (sidebar, address bar, Peek, splits, every animation)
and gets Chromium, with Chrome extensions, underneath. This is the approach Arc and Dia
took: Chromium built from source with our own patches and our own embedding layer.

## Why a fork, and why on top of CEF

- Rise animates its pages as ordinary views: rounded clipping, live resizing every frame,
  Peek cards over the page. That only works when Chromium's page view sits **inside**
  Rise's own view tree.
- Stock CEF can do that ("Alloy" pages in a parent view), but those pages aren't tabs to
  Chrome, so extensions don't see them. CEF's maintainers won't change that
  ([cef#3859](https://github.com/chromiumembedded/cef/issues/3859)).
- CEF's Chrome-style pages do have extensions, but on macOS they need Chrome's own
  window ([cef#3294](https://github.com/chromiumembedded/cef/issues/3294)). Floating
  that window over Rise would break clipping, transforms and layering, so we don't.
- So we build CEF and Chromium from source and patch them: Rise's embedded pages become
  real tabs to Chrome's extension system. CEF still gives us the hard, already-solved
  parts: framework packaging, helper processes, threading, NSApplication integration.

## Layout

| Path | What |
|---|---|
| `Engine/chromium.json` | The pinned Chromium tag, CEF branch and commit, and GN build settings |
| `Engine/patches/cef/` | Our patches to CEF, applied in name order |
| `Engine/patches/chromium/` | Our patches to Chromium, applied in name order |
| `scripts/engine/checkout.sh` | Fetches the pinned sources (no history, about 30 GB) into `../rise-chromium` |
| `scripts/engine/patch.sh` | Applies our patches (skips any already applied), then the branding |
| `scripts/engine/brand.py` | Names Rise where Chromium names itself (in every language) and puts Rise's icon (`Engine/branding/logo.png`) where Chromium's logo shows; a script rather than a patch, so it needs no fitting to new versions |
| `scripts/engine/build.sh` | Builds the engine for Apple silicon and makes the framework distribution |
| `Engine/adblock/` | Ad and tracker blocking for Chromium pages: Brave's `adblock` crate behind a small C interface |

Needs Xcode with the macOS SDK the pin expects (26.5 for Chromium 156), its Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`), and about 100 GB free.

The checkout lives outside the repo: `RISE_CHROMIUM_ROOT`, by default
`~/github/rise-chromium`. Only patches and scripts are committed.

## Patches

| Patch | Why |
|---|---|
| `cef/0001-navigation-state-and-audible.patch` | Back/forward history saved and restored with Chromium's own session format, and when a page starts or stops making sound |
| `cef/0002-attach-devtools-frontend.patch` | Chrome's DevTools front end, loaded in a page of Rise's own, inspects another page; CEF can't put its own DevTools window inside an app's view on macOS, so Rise's DevTools slide in beside the page this way |
| `cef/0003-allow-settings-and-extensions-pages.patch` | Chrome's settings and extensions pages open in Rise's own pages, as rise://settings and rise://extensions (CEF otherwise only allows a short list of chrome:// pages there) |
| `cef/0004-default-search-engine.patch` | Rise's address bar searches with the default search engine chosen in Chrome's Search engine section of rise://settings |
| `cef/0005-context-menu-actions.patch` | What Rise's page menu needs that CEF doesn't offer: copying the image clicked, inspecting the element clicked in DevTools, and Look Up on the selection |
| `cef/0006-tab-strips.patch` | A Rise window as extensions see it (`CefTabStrip`): a browser window whose tabs are Rise's pages, which the tabs and windows APIs list, watch and act on, with what extensions ask (open, switch to, move, pin, close) passed to Rise |
| `cef/0007-extension-actions.patch` | Extensions' toolbar buttons for Rise to draw: their titles, icons and badges for a tab, a click (which gives the extension the tab, then names the popup to show), and word when any change |
| `cef/0008-extension-install.patch` | Installing from the Chrome Web Store by an extension's id, asking in Rise's own sheet in place of Chrome's dialog, and letting the installer's download through (CEF drops downloads not started by one of its pages) |
| `cef/0009-extension-popups.patch` | A page made an extension's popup, as extensions see it: a "popup" view, not a tab |
| `chromium/0001-hide-web-contents-after-a-turn.patch` | Rise moves pages between views (Peek, split, ⌘Z); a page out of its window for an instant no longer blanks for several frames when it's back |
| `chromium/0002-rise-settings-sections.patch` | Chrome's settings leave out what Rise's pages don't use or Rise does its own way (Google sign-in, autofill and passwords, extensions, startup, performance, AI, Safety Check, downloads, and Appearance's rows for Chrome's own window: theme, toolbar, mode, tab strip, side panel, quitting and split view) and the update status of Chrome's updater |
| `chromium/0003-rise-settings-rows.patch` | Rise's own settings in Chrome's settings page: rows Rise describes (so a new Rise setting needs no engine change), at the end of Appearance, System and Privacy, and in new Tabs and AI sections, and Rise's mark for About Rise |
| `chromium/0004-extension-embedder-windows.patch` | The extension APIs see an embedder's windows (CEF's tab strips) beside Chrome's own, and cope with tabs that aren't in a Chrome tab strip (no lifecycle unit; popups that have tab ids but aren't tabs). Made against the tree after CEF's own patches, as CEF also patches `tabs_api.cc` |
| `chromium/0005-extension-install-prompt.patch` | An embedder can ask about extension installs itself in place of Chrome's dialog |

## Stages

1. **Toolchain.** Pinned checkout and an unpatched build on this Mac.
2. **Engine boundary in Rise.** One `WebPage` interface for everything Rise asks of a page,
   implemented by WebKit first, so Rise works the same with either engine.
3. **Embedding and motion gate.** A Chromium page inside Rise's views: live Peek resize,
   split, Cmd-Z unsplit, rounded corners, promotion without reload, compared frame by
   frame against WebKit.
4. **Extensions patch.** Embedded pages registered as tabs with Chrome's extension system;
   extension buttons and popups drawn by Rise. Done: Web Store installs, buttons, popups and
   the tabs and windows APIs, tried with uBlock Origin Lite, Dark Reader and Bitwarden.
5. **Port features.** Navigation, downloads, find, zoom, page scripts, snapshots, ad
   blocking, preloading, audio, picture in picture, swipes.
6. **Data.** New Chromium profile; tabs, splits, pins, history and icons carry over;
   one-time cookie copy.
7. **Release.** Signing and notarizing nested helpers; regular Chromium security updates
   by moving the pin and re-applying the patches.

## Trying Rise on Chromium

Where the engine is built, `./scripts/build.sh` puts it into Rise.app (the framework and
four `Rise Helper` apps, about 560 MB), and Rise runs on Chromium: new and restored tabs use
it. WebKit is still there when asked for, with `RISE_ENGINE=webkit` or
`defaults write dev.bartosz.Rise RiseEngine webkit`. To try a build without touching the
everyday profile:

    open -n build/Rise.app --env RISE_PROFILE_DIR=/tmp/rise-chromium

`RISE_PROFILE_DIR` keeps that session, history and website data apart from the everyday
ones, and its Chromium never uses the Keychain. The everyday profile keeps Chromium's key in
Rise's own Keychain item, "Rise Safe Storage".

On Chromium tabs these work, also for frames of other sites:

- Peek with all its motion, and back/forward history across relaunches.
- Downloads, find, and camera, microphone and location prompts.
- Picture in picture, and the tab's sound and play button.
- Browsing history, error pages, the prompt before opening another app, tab switcher
  pictures, site icons, crashed-page reloads, and `window.close()` for tabs a site opened.
- Rise's theme (light or dark, and the colour before a page draws), full screen (native,
  in a window of its own, and simulated, with ⇧⌘F), ad blocking and Preload Links.
- Windows a page opens stay its popups, so sign-ins and Gmail's popped-out emails work; the
  Gmail card, merge checks, site search learning and site notifications.
- Chrome's settings at rise://settings (⌘,), in Rise's name and with its icon, with every page
  under it and without the parts Rise doesn't use. Rise's own settings are among them: in
  Appearance, System and Privacy, and in Tabs and AI sections of their own (AI: OpenRouter,
  OpenCode or OpenAI, with an API key kept in the keychain, a model and a reasoning effort); the site
  controls' ⋯ opens them. The address bar searches with Chrome's default search engine.
- Developer Mode: Chrome's DevTools with ⌥⌘J, on Elements, sliding in from the right as the
  docked sidebar does from the left; the JavaScript Console, View Source and the screenshots.
- Rise's page menu, as WebKit's: links (with Open Link in Peek), images, video, selected text
  (Look Up and a search), spelling suggestions, editing and Writing Tools, and Inspect Element
  opening DevTools on the element. Pages' alert, confirm and prompt, leaving with unsaved changes
  and file choosers ask in Rise's sheets, as on WebKit; a page navigating away closes its dialog.
- Pinch zoom (which the Peek allows for), force-click Look Up, and Chromium's own picture in
  picture for protected video, where WebKit's pages use WebKit's.

- Chrome extensions, as Arc has them. Install from the Chrome Web Store with the “Add to Rise”
  button Rise puts by the extension's name (the store itself offers Chrome only), or from the
  site controls; Rise's sheet shows what the extension can do. Pinned extensions sit in the
  sidebar's address row, every extension is in the site controls (right-click to pin, unpin or
  manage), and popups open in popovers under their button, sized to their page. Extensions see
  Rise's windows and tabs through the tabs and windows APIs. rise://extensions is Chrome's
  extensions page, for turning them off, removing them, and loading unpacked ones.

Rise's page scripts reach every frame through Chromium's DevTools protocol, inside the app.
Not carried over yet: the WebKit profile's cookies and sign-ins.

Ad blocking uses the filter lists WebKit's rules are made from (`Filters/Sources`, plus
Rise's own rules in `Engine/adblock/rise.txt`), one engine per list so each keeps its own
exceptions, as on WebKit. `./scripts/build.sh` builds the library with `cargo` where the
engine is; the engines are made when the library is built, so Rise only loads them.

Live checks, in a real Rise window with Chromium (see `scripts/test-chromium-live.py`):

    python3 scripts/test-chromium-live.py peek       # Peek's motion, frame by frame
    python3 scripts/test-chromium-live.py features   # the features above
    python3 scripts/test-chromium-live.py extensions # a test extension: tabs, buttons, popups

## Build settings worth knowing

- `proprietary_codecs` with `ffmpeg_branding="Chrome"`: H.264 and AAC play, as in Chrome.
- `disable_fieldtrial_testing_config`: a build that isn't Google's official one otherwise
  switches on Chromium's in-progress experiments. In Chromium 156 one of them launches
  helper apps ("Helper (Aperitif)") that CEF doesn't package, so no page process can start.

## Updating Chromium

Move the pin to the next CEF branch, run `checkout.sh`, then `patch.sh`. Fix any patch
that no longer applies, then rebuild. Keep patches small and focused so this stays
quick every four weeks.
