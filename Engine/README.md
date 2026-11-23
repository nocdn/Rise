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

Needs Xcode with the macOS SDK the pin expects (27.0 for Chromium 158), its Metal
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
| `0037-extension-popups-close-before-quitting.patch` | Quitting closes extension popups' pages, the one open and the one Rise makes ahead (`spareExtensionPopup`), as their Rise view owns them rather than a Browser whose tabs Chrome closes, and deletes them at once rather than on the next turn, which doesn't come before Chrome destroys the profile. One left behind made Chrome stop Rise as it quit (`WebContentsOfBrowserContext`'s check that no page outlives its profile) |
| `0038-page-key-acks.patch` | Rise lets a page try the shortcuts it might want first. Asked to (`watchNextKeyPress`), the bridge watches the keyboard's widget for the press's ack and tells Rise if the page used it (`browserView:pageUsedKeyCode:`), so the page bar can offer Rise's command; one it didn't use reaches Rise before the menu bar (`browserView:handleUnusedKey:`), for Rise's own undo. Only Rise's bridge changes, through Chromium's public `InputEventObserver` |
| `0042-print-command.patch` | Rise's File > Print, ⌘P and Print… in the page's menu (`RCBrowserView.printPage`, `canPrint`, `printPageUsingSystemDialog`, `RCContextMenu.printPage`) start Chrome's print preview for that page as Chrome's own commands do (`printing::StartPrint`), so a PDF prints as itself and a selection on its own. The preview takes its size from the page's own tab, which Rise shows whatever Chrome's tab strip has active; sized from the window's, it ran off the page |
| `0043-site-permissions-kept.patch` | A site's allowed camera, microphone and location are kept for it, as Chrome keeps them (`Accept` rather than `AcceptThisTime`), and `RCEngine.setPermissions:state:forOrigin:` tells Chrome each choice in Rise's site settings, so a page checking before it asks, as Meet does with the Permissions API, sees them allowed rather than asking every meeting |
| `0044-pip-placement-logging.patch` | Where Chrome places and moves a page's floating window, and why, in the system log beside Rise's own (subsystem `dev.bartosz.Rise`, category `FloatingPage`, lines starting `engine:`): its first bounds and the bounds cache, child dialogs growing it and putting it back, Chrome's tuck, a site resizing it, and its focus |
| `0045-site-notifications-user-notifications.patch` | Sites' notifications are shown from Rise's own process with the UserNotifications API (`MacNotificationServiceUN`, as Chrome's app shims show theirs), not the deprecated `NSUserNotificationCenter`. Rise uses UserNotifications itself, and once an app has, macOS refuses its `NSUserNotificationCenter` notifications without a word ("You can't mix modern clients with legacy clients"), so Google Chat's and every other site's never showed |
| `0046-no-alerts-helper.patch` | No alert dispatcher: every site's notification is already a banner from Rise's own process (`0039`, `0045`), and Chrome only started its alerts helper (`Chromium Helper (Alerts)`) at launch to list or close alerts it never showed. Starting it was enough for macOS to ask, under Chromium's name, whether it could send notifications |
| `0047-chromium-158-build-targets.patch` | Uses Chromium 158's smaller browser UI build targets for Rise's embedding layer and permits its use of `browser.h` |
| `0048-chromium-158-settings-lint.patch` | Meets Chromium 158's Lit template checks: conditionally rendered Appearance controls are read from their change event, and keyboard shortcut loading rows use a tagged template branch |
| `0049-chromium-158-v8-callback-data.patch` | Reads Rise's renderer message handler data through V8's `DataV2` API, replacing the deprecated `Data` accessor |
| `0050-chromium-158-browser-api.patch` | Follows Chromium 158's browser API: `BrowserWindow` no longer has the profile IPH methods, `WindowOpenDisposition`'s values are `kCurrentTab` and so on, and an extension event takes its arguments as shared `EventArgs` |
| `0051-settings-events-without-browser-view.patch` | Chromium 158's settings tell the window's `BrowserView` element when the search engine changes or browsing data is cleared, and CHECKed that it was there; Rise's windows have none, so choosing a search engine crashed Rise. They now skip it |
| `0052-pdf-find-and-text.patch` | A PDF Chromium draws itself, for Find and Page Assistant: `RCBrowserView` says whether it shows one (`showsPDF`), searches it with Chrome's own find (`findText:forward:completion:`, its count and current match as they come in, and `stopFindingSelectingMatch:`), says when its document has loaded (`whenPDFLoaded:`), and gives its pages' text (`PDFPageTextsWithCompletion:`) and what is selected in it (`PDFSelectedText`) |
| `0053-settings-search-without-people.patch` | Searching settings shows what it finds: Chrome falls back on "You and Google" as the top-level section a search starts from, which Rise hides, so every search threw and showed a blank page. It falls back on Privacy instead, and the site settings list skips rows without a route |
| `0054-page-size-ignores-ancestor-scaling.patch` | A page's size is its view's own, not how big an ancestor that scales it shows it: Rise's floating video stretches its page to fill the window, and measured in the window, every step of a resize laid the page out at another size, which showed through the picture as a flicker or a blank corner |
| `0055-keep-reading-the-old-key.patch` | Rise's profile keeps what it encrypted before Chromium 158: 158 marks the key older Chromiums encrypt with ("v10") as unavailable for a profile outside Chromium's default folder, as Rise's is, and dropped every cookie it couldn't read and every extension whose signed settings it couldn't check, files and all. Rise reads that key still; 158's own ("v11"), which takes precedence, encrypts |
| `0056-cursor-check-only-in-full-screen.patch` | A page checks the system cursor, a round trip to the window server, only in full screen and at most ten times a second: Chromium asked on every mouse move, for a reset only full screen's toolbar window causes, and it took about 3% of the main thread while the pointer moved over a page |

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
    python3 scripts/test-chromium-live.py extensions # a test extension: tabs, buttons, popups; the Web Store's Add to Rise
    python3 scripts/test-chromium-live.py upgrade    # a profile the previous release made keeps its cookies and extensions
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
Then run the live checks, `upgrade` and `extensions` among them: `upgrade` has the last release,
on the old engine, make a profile the new one must open with its cookies and extensions intact,
which Chromium 158 didn't (0055), and `extensions` installs from the Web Store.
Keep patches small and focused so this stays quick every four weeks.
