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
| `scripts/engine/fetch.sh` | Copies Chromium.app from another Mac that built it, for Macs that can't (`docs/EngineRebuild.md`) |
| `Engine/ublock.json` | The uBlock Origin release Rise carries for ad blocking, and the key that fixes its extension id |

Needs Xcode with the macOS SDK the pin expects (26.5 for Chromium 156), its Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`), and about 100 GB free.

The checkout lives outside the repo: `RISE_CHROMIUM_ROOT`, by default
`~/github/rise-chromium`. Only patches and scripts are committed.

The engine is an official build, as Chrome's and Helium's are (`is_official_build`, which brings
profile-guided optimisation from Chrome's profiles, ThinLTO and V8's builtins profiles; `checkout.sh`
fetches the profiles). On Speedometer it scores about a third higher than the developer build
Rise had before. Its final link alone takes about 6 minutes.

Engine builds reuse `out/Official` and its dependency cache. The script defaults to
four parallel jobs to leave RAM for the desktop; set `RISE_CHROMIUM_JOBS` explicitly
to change that limit. Preview pending work with `./scripts/engine/build.sh -n` before
every build: a small change should be a few steps and the link, and anything far larger
means the build files changed and most of Chromium will compile again (hours).

The patch script recognizes an installed prefix of overlapping patches, so adding the next
patch applies only the new suffix instead of replaying older changes. Its regression checks
run without a Chromium checkout: `python3 -m unittest discover -s scripts/engine/tests`.

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
| `0014-navigation-loading-ui.patch` | Uses Chromium's navigation loading-UI state so lazy frames loaded while scrolling do not restart the tab's progress sweep or Stop button |
| `0015-page-layer-follows-its-view.patch` | Keeps Chromium's page layer aligned with its view during animated resizing |
| `0016-zoom-is-the-pages-own.patch` | Reads the page's actual Chromium zoom after per-site restoration |
| `0017-touch-id-passkeys-follow-the-app.patch` | Derives the local passkey keychain group from the signed embedding app's identity |
| `0018-snapshot-a-strip-of-the-page.patch` | Copies a small rendered page strip for the page bar's colour |
| `0019-extension-requested-popups.patch` | Routes `chrome.action.openPopup()` through Rise's popup host, retaining Chrome's active-window and action checks |
| `0020-authentication-diagnostics.patch` | Local macOS unified logs for passkey lifecycle/availability and native-host launch/disconnect outcomes, without credential or page data |
| `0021-covered-pages-keep-their-tooltips.patch` | A page covered by a Peek sets aside only Chromium's mouse tracking, not AppKit's tooltip areas, which otherwise come back pointing at freed tooltips |
| `0023-rise-keyboard-shortcuts.patch` | A Keyboard shortcuts section in Settings, using Chromium's shortcut recorder and controls with Rise's saved command registry |
| `0024-element-permission-steps-and-macos-location.patch` | Rise's permission prompt follows a page element's (`<usermedia>`, `<geolocation>`) later steps as Chrome's element prompt does, asking macOS rather than deciding the requests again, which crashed; and asks macOS for location when a page is allowed it, which Chrome does from its address bar |
| `0025-https-first-full-page-warning.patch` | Turns off `HttpsFirstDialogUi`, so HTTPS-First's fallback to http warns with Chrome's full-page interstitial rather than a dialog over Chrome's own window, which Rise's pages don't have and crashed |
| `0026-rise-pip-buttons-and-camera-spring.patch` | Keeps a page picture-in-picture window's back to tab and close buttons in the bar's 28 pt square, gives the camera and microphone button the same Rise style, and springs it into the buttons' space at up to 120 Hz as they fade |
| `0027-rise-keychain-item.patch` | Lets Rise name the Keychain item its cookie and password key is kept in (`setKeychainService:account:`), so it keeps it in "Rise Safe Storage" as Chrome keeps its in "Chrome Safe Storage"; without it, Chromium's own item as before |
| `0028-helium-shortcut-editor.patch` | Helium's shortcut editor, adapted to Rise's registry: shortcut chips, ranked search, explicit recording/Save/Cancel, per-command reset and reset-all confirmation. Upstream source and GPL-3.0 license are in `Engine/third_party/helium` |
| `0029-ublock-origin-ad-blocking.patch` | Ad blocking is uBlock Origin, loaded from Rise's Resources as a component extension (allowlisted by the id its pinned key gives) and unloaded when Block Ads is off; takes out `0002`'s own request filter, `RCAdBlockUseEngine` and the embedder URL loader factory hook |
| `0030-background-tabs-hidden-and-frozen.patch` | Pages start hidden until first in a window, as Chrome's background tabs do (Chromium otherwise keeps a page opened in the background running as if shown); and Chrome's `InfiniteTabsFreezing` is on, as in Helium: background tabs past the five most recently used freeze, waking a few seconds a minute |
| `0031-attached-page-visibility.patch` | Preserves the checkout's fix that unhides Chromium's native page view when Rise attaches it, while the owning page still controls whether it is shown or hidden |
| `0032-context-menu-downloads.patch` | Implements the formerly empty explicit-download bridge and saves context-menu links, images, audio and video through Chromium's downloader, retaining the clicked document's credentials, referrer policy and blob storage; stale menus cannot save from a later document |
| `0033-node-build-steps-one-file-at-a-time.patch` | Chromium's node build scripts that read a whole batch of files at once work through them one at a time: DevTools' copying, compression, CSS and JSON steps, and WebUI's minifying. It was meant to stop SentinelOne killing `node` mid-build for the burst, but it doesn't (`docs/EngineRebuild.md`); it stays as it does no harm. Compressing DevTools takes about 10 seconds longer; the rest take no longer |
| `0034-devtools-menus-and-device-mode.patch` | DevTools' menus (the » past their tabs, toolbar menus, right-clicks on nodes and requests) reach Rise as the page's own entries (`RCContextMenu.customItems`), which Rise shows and reports back as Chrome does; Chrome's own menu needs a Views window, which Rise's aren't. DevTools load undocked but able to dock (`can_dock`), which gives them device mode: as in Chrome's own undocked DevTools, they open a toolbox page that Rise shows in the inspected page's place, and tell Rise where to lay out the page in it (`browserView:setInspectedPageBounds:`) |
| `0035-client-certificate-chooser.patch` | A site asking for a client certificate (TLS client authentication) reaches Rise (`browserView:chooseClientCertificate:host:completion:`) with the keychain's identities that suit it, as `SecIdentity`s, instead of Chrome's selector, a Views dialog that needs a Chrome window. Rise shows macOS's chooser (`SFChooseIdentityPanel`), as Safari does, and answers with the one chosen or none; a request that goes away closes it (`browserViewDidCancelClientCertificate:`) |
| `0036-declining-unsaved-permission-requests.patch` | Declining a site's request resets only permissions Chrome keeps a setting for. Requests with none (a site handling links such as `mailto:`, several downloads, writing files, storage, signing in) otherwise reached `SetContentSettingDefaultScope`, whose check for a registered setting crashed Rise on declining one |

`0002` is exported from the fork's tree with `git diff HEAD` over `base` and `chrome`, less the
paths the other patches and `brand.py` own (see `Engine/fork-plan.md`); new files are added
with `git add -N` first.

## Building and trying Rise

`scripts/engine/checkout.sh`, then `scripts/engine/build.sh`, then `./scripts/build.sh`, which
makes `build/Rise.app` with the engine's framework and its helper apps inside. To try a build
without touching the everyday profile:

    open -n build/Rise.app --env RISE_PROFILE_DIR=/tmp/rise-chromium

`RISE_PROFILE_DIR` keeps that session, history and website data apart from the everyday
ones; Chromium's Safe Storage key is kept out of the Keychain, and it doesn't sync tabs through iCloud.
This does not disable WebAuthn's platform authenticator: a passkey explicitly registered in a test
profile can still be stored in the Mac's keychain, bound to that profile's metadata secret. The
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

Ad blocking is uBlock Origin, pinned in `Engine/ublock.json`. `./scripts/build.sh` puts it in
the app's Resources (`scripts/ublock.py`, with the pinned key in its manifest), and the bridge loads
it as a component extension: Chrome's extensions page and Rise's controls leave it out, and as a
component it keeps Manifest V2's blocking web requests. Turning Block Ads off unloads it.

Live checks, in a real Rise window (see `scripts/test-chromium-live.py`):

    python3 scripts/test-chromium-live.py peek       # Peek's motion, frame by frame
    python3 scripts/test-chromium-live.py features   # the features above
    python3 scripts/test-chromium-live.py extensions # a test extension: tabs, buttons, popups
    python3 scripts/test-chromium-live.py passkeys   # signed platform availability, RP isolation, cancellation

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
