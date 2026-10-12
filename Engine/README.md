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
| `scripts/engine/patch.sh` | Applies our patches (skips any already applied) |
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
| `chromium/0001-hide-web-contents-after-a-turn.patch` | Rise moves pages between views (Peek, split, ⌘Z); a page out of its window for an instant no longer blanks for several frames when it's back |

## Stages

1. **Toolchain.** Pinned checkout and an unpatched build on this Mac.
2. **Engine boundary in Rise.** One `WebPage` interface for everything Rise asks of a page,
   implemented by WebKit first, so Rise works the same with either engine.
3. **Embedding and motion gate.** A Chromium page inside Rise's views: live Peek resize,
   split, Cmd-Z unsplit, rounded corners, promotion without reload, compared frame by
   frame against WebKit.
4. **Extensions patch.** Embedded pages registered as tabs with Chrome's extension system;
   extension buttons and popups drawn by Rise.
5. **Port features.** Navigation, downloads, find, zoom, page scripts, snapshots, ad
   blocking, preloading, audio, picture in picture, swipes.
6. **Data.** New Chromium profile; tabs, splits, pins, history and icons carry over;
   one-time cookie copy.
7. **Release.** Signing and notarizing nested helpers; regular Chromium security updates
   by moving the pin and re-applying the patches.

## Trying Rise on Chromium

Where the engine is built, `./scripts/build.sh` puts it into Rise.app (the framework and
four `Rise Helper` apps, about 560 MB). Rise still starts on WebKit; Chromium only starts
when asked, and then new and restored tabs use it:

    open -n build/Rise.app --env RISE_ENGINE=chromium --env RISE_PROFILE_DIR=/tmp/rise-chromium

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

Rise's page scripts reach every frame through Chromium's DevTools protocol, inside the app.
Still WebKit-only: the Gmail card, Rise's own page menu, site notifications, and WebKit's
own picture in picture for encrypted video.

Ad blocking uses the filter lists WebKit's rules are made from (`Filters/Sources`, plus
Rise's own rules in `Engine/adblock/rise.txt`), one engine per list so each keeps its own
exceptions, as on WebKit. `./scripts/build.sh` builds the library with `cargo` where the
engine is; the engines are made when the library is built, so Rise only loads them.

Live checks, in a real Rise window with Chromium (see `scripts/test-chromium-live.py`):

    python3 scripts/test-chromium-live.py peek       # Peek's motion, frame by frame
    python3 scripts/test-chromium-live.py features   # the features above

## Build settings worth knowing

- `proprietary_codecs` with `ffmpeg_branding="Chrome"`: H.264 and AAC play, as in Chrome.
- `disable_fieldtrial_testing_config`: a build that isn't Google's official one otherwise
  switches on Chromium's in-progress experiments. In Chromium 156 one of them launches
  helper apps ("Helper (Aperitif)") that CEF doesn't package, so no page process can start.

## Updating Chromium

Move the pin to the next CEF branch, run `checkout.sh`, then `patch.sh`. Fix any patch
that no longer applies, then rebuild. Keep patches small and focused so this stays
quick every four weeks.
