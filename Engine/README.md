# Rise's Chromium engine

Rise keeps its own AppKit interface (sidebar, address bar, Peek, splits, every animation)
and gets Chromium, with Chrome extensions, underneath. This is the approach Arc and Dia
took: Chromium built from source with our own patches and our own embedding layer.
`Engine/fork-plan.md` has how it got here and what's left.

## How Rise sits on Chromium

- Rise animates its pages as ordinary views: rounded clipping, live resizing every frame,
  Peek cards over the page. That only works when Chromium's page view sits **inside**
  Rise's own view tree.
- Each Rise window is backed by a real Chrome `Browser` whose `BrowserWindow` is Rise's
  (`RiseBrowserWindow`), so Chrome draws no window or tab strip of its own, but its tabs are
  real tabs: extensions, settings, permissions and the rest of Chrome work on them as in Chrome.
- Each tab's `WebContents` view sits in Rise's views. Rise reaches the engine through one
  interface, `Sources/RiseChromium/include/RiseChromium.h`, which the fork implements in
  `chrome/browser/rise` and builds into Chrome's framework.
- Where Chrome would show its own UI for a tab (dialogs, file choosers, downloads, full screen,
  context menus), `EmbedderTabHooks` asks Rise first.

## Layout

| Path | What |
|---|---|
| `Engine/chromium.json` | The pinned Chromium tag and GN build settings |
| `Engine/fork/patches/` | Our patches to Chromium, applied in name order |
| `Engine/fork/reach-ins.tsv` | Where Chrome's code reaches for its own window, each reviewed (`scripts/engine/fork-reach-ins.py` fails on new ones) |
| `scripts/engine/checkout.sh` | Fetches the pinned Chromium (no history, about 30 GB) into `../rise-chromium/fork` |
| `scripts/engine/patch.sh` | Applies our patches (skips any already applied), then the branding |
| `scripts/engine/brand.py` | Names Rise where Chromium names itself (in every language) and puts Rise's icon (`Engine/branding/logo.png`) where Chromium's logo shows; a script rather than a patch, so it needs no fitting to new versions |
| `scripts/engine/build.sh` | Builds Chromium.app for Apple silicon, whose framework Rise links and carries |
| `Engine/adblock/` | Ad and tracker blocking for pages: Brave's `adblock` crate behind a small C interface |

Needs Xcode with the macOS SDK the pin expects (26.5 for Chromium 156), its Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`), and about 100 GB free.

The checkout lives outside the repo: `RISE_CHROMIUM_ROOT`, by default
`~/github/rise-chromium`. Only patches and scripts are committed.

Engine builds reuse `out/Release` and its dependency cache. The script defaults to
four parallel jobs to leave RAM for the desktop; set `RISE_CHROMIUM_JOBS` explicitly
to change that limit. `./scripts/engine/build.sh -n` previews pending work.

## Patches

| Patch | Why |
|---|---|
| `0001-hide-web-contents-after-a-turn.patch` | Rise moves pages between views (Peek, split, ⌘Z); a page out of its window for an instant no longer blanks for several frames when it's back |
| `0002-rise-engine.patch` | Rise's embedding layer (`chrome/browser/rise`: the bridge, `RiseBrowserWindow`, Rise's page dialogs host) and the small hooks it needs in Chrome: `EmbedderTabHooks`, the ad-blocking request filter, extension uninstall prompts, and Chrome's code that reached for its own window coping without one |
| `0003-rise-settings-sections.patch` | Chrome's settings leave out what Rise's pages don't use or Rise does its own way (Google sign-in, autofill and passwords, extensions, startup, performance, AI, Safety Check, downloads, and Appearance's rows for Chrome's own window) and the update status of Chrome's updater |
| `0004-rise-settings-rows.patch` | Rise's own settings in Chrome's settings page: rows Rise describes (so a new Rise setting needs no engine change), at the end of Appearance, System and Privacy, and in new Tabs and AI sections, and Rise's mark for About Rise |
| `0005-extension-install-prompt.patch` | Rise asks about extension installs in its own sheet in place of Chrome's dialog |
| `0006-rise-site-search-settings.patch` | Settings' Site search section: the sites Tab searches from the address bar, added and edited by hand (name, search address, colour) or learned, kept by Rise and reached through `riseSettings.request` |
| `0007-remove-privacy-guide-promo.patch` | Removes the Privacy Guide promotional card from settings, keeping the guide itself and the privacy controls |
| `0008-unify-search-settings.patch` | One Search sidebar item for search engine and site search settings, and a plain colour swatch for a site's automatic colour |
| `0009-automatic-script-evaluation.patch` | Background automation evaluates without synthetic user activation and skips inactive frames; user-invoked page commands retain their gesture |
| `0010-align-search-settings-sections.patch` | Aligns Site search with the Search engine section and leaves space below its card |
| `0011-rise-pip-top-bar.patch` | Rise's picture-in-picture controls and window appearance hooks |
| `0012-portable-tab-history.patch` | Exports URL/title entries and the committed cursor, and restores a portable history without visiting its other destinations |
| `0013-avoid-unchanged-generator-rebuilds.patch` | Uses Siso's content comparison for generated files on macOS, preserving timestamps when their contents are unchanged |

`0002` is exported from the fork's tree with `git diff HEAD` over `base` and `chrome`, less the
paths the other patches and `brand.py` own (see `Engine/fork-plan.md`); new files are added
with `git add -N` first.

## Building and trying Rise

`scripts/engine/checkout.sh`, then `scripts/engine/build.sh`, then `./scripts/build.sh`, which
makes `build/Rise.app` with the engine's framework and its helper apps inside. To try a build
without touching the everyday profile:

    open -n build/Rise.app --env RISE_PROFILE_DIR=/tmp/rise-chromium

`RISE_PROFILE_DIR` keeps that session, history and website data apart from the everyday
ones; its Chromium never uses the Keychain, and it doesn't sync tabs through iCloud. The
everyday profile keeps Chromium's key in Rise's own Keychain item, "Rise Safe Storage".

What Rise does on Chromium pages, also for frames of other sites:

- Peek with all its motion, splits, history swipes, and back/forward history across relaunches.
- Downloads, find, Page Assistant, whole-page captures, and camera, microphone and location prompts.
- Rise's floating video, and Chromium's own picture in picture for protected video; the tab's
  sound and play buttons.
- Browsing history, error pages, the prompt before opening another app, tab switcher
  pictures, site icons, crashed-page reloads, and `window.close()` for tabs a site opened.
- Rise's theme (light or dark, and the colour before a page draws), full screen (native,
  in a window of its own, and simulated, with ⇧⌘F), ad blocking and Preload Links.
- Windows a page opens stay its popups, so sign-ins and Gmail's popped-out emails work; the
  Gmail and pull request cards, merge checks, site search learning and site notifications.
- Chrome's settings at rise://settings (⌘,), in Rise's name and with its icon, with every page
  under it and without the parts Rise doesn't use. Rise's own settings are among them: in
  Appearance, System and Privacy, and in Tabs and AI sections of their own. The address bar
  searches with Chrome's default search engine.
- Developer Mode: Chrome's DevTools with ⌥⌘J, on Elements, sliding in from the right.
- Rise's page menu: links (with Open Link in Peek), images, video, selected text (Look Up and a
  search), spelling suggestions, editing and Writing Tools, and Inspect Element. Pages' alert,
  confirm and prompt, leaving with unsaved changes, file choosers, sign-in prompts and Chrome's
  device choosers ask in Rise's sheets or over the page.
- Chrome extensions, as Arc has them. Install from the Chrome Web Store with the “Add to Rise”
  button Rise puts by the extension's name, or from the site controls; Rise's sheet shows what
  the extension can do, and asks before one is removed. Pinned extensions sit in the sidebar's
  address row, every extension is in the site controls, and popups open in popovers under their
  button, sized to their page. Extensions see Rise's windows and tabs through the tabs and
  windows APIs. rise://extensions is Chrome's extensions page.

Ad blocking uses the filter lists in `Filters/Sources`, plus Rise's own rules in
`Engine/adblock/rise.txt`, one engine per list so each keeps its own exceptions.
`./scripts/build.sh` builds the library with `cargo`; the engines are made when the library is
built, so Rise only loads them.

Live checks, in a real Rise window (see `scripts/test-chromium-live.py`):

    python3 scripts/test-chromium-live.py peek       # Peek's motion, frame by frame
    python3 scripts/test-chromium-live.py features   # the features above
    python3 scripts/test-chromium-live.py extensions # a test extension: tabs, buttons, popups

and `scripts`, `app`, `float`, `capture`, `tools`, `youtube` and `media`. Some need Rise's
window in front, and say so when it wasn't.

## Build settings worth knowing

- `proprietary_codecs` with `ffmpeg_branding="Chrome"`: H.264 and AAC play, as in Chrome.
- `disable_fieldtrial_testing_config`: a build that isn't Google's official one otherwise
  switches on Chromium's in-progress experiments.

## Updating Chromium

Move the pin in `Engine/chromium.json` to the next stable tag, run `checkout.sh`, then
`build.sh` (which applies the patches). Fix any patch that no longer applies, run
`scripts/engine/fork-reach-ins.py` for new places Chrome reaches for its window, and rebuild.
Keep patches small and focused so this stays quick every four weeks.
