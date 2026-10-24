# iOS cold-launch performance audit

Code review and simulator measurements on 23–24 October 2026 use commit `6af97296ba58fc62bccfccd94f2a0835444aef33`. The physical trace uses the existing installed Debug binary, without rebuilding it for this audit.

The best next change is a dedicated **search-first launch path**: attach and focus search earlier, then prepare the rest of the browser as it becomes useful. The other large structural improvement is to restore inactive tabs as data rather than eagerly constructing a `WKWebView` for each one.

This was an investigation. The app source in the working checkout was left unchanged. Experimental instrumentation and runtime switches lived in `/tmp/rise-launch-audit`. The phone's installed app was profiled without replacing it. Measurements, the temporary instrumentation patch, scripts, and traces are preserved in [`build/launch-audit-2026-10-24`](../build/launch-audit-2026-10-24).

## What was measured

- **56 simulator process launches**, including 25 randomized, interleaved A/B runs: five launches for each of five conditions. Each run terminated the app first; it was not an in-memory resume.
- iPhone 17 Pro simulator, iOS 27.0; Release configuration, `-O`, whole-module optimization, no debugger attached during timing runs. Software keyboard enabled and verified through native Device Hub UI. A real tap on its Q key was also verified to update the search field in the combined experimental path; this was a functional check after appearance, not an input-latency measurement.
- Synthetic saved sessions containing 1, 20, or 100 tabs. The selected tab used `example.com`; other tabs retained metadata and did not navigate. Local history, learned searches and icon caches were empty except in the history stress test. The sync cache was reset for each trial.
- One valid Instruments **App Launch** capture on the physical **iPhone 14 Pro, iOS 27.2**. The installed app was Debug: its `RiseiOS.debug.dylib` UUID matched the local Debug build (`CE07FFFB-106E-3BD4-9BB6-B64D23B889CD`). Additional phone recordings encountered another profiling session's kperf lock; they are excluded.
- One ETTrace 1.1.0 simulator launch capture, with UUID-matched app/framework dSYMs, launched from the Home screen. Sampling was separate from the timing comparisons.

The primary comparison endpoint is **`UIKeyboardDidShowNotification`**, measured from AppDelegate initialization. Search-focus entry and return were recorded separately. These numbers exclude dyld work before AppDelegate creation, SpringBoard, the icon tap, and other OS launch overhead. They are **not absolute tap-to-type times**. Keyboard appearance is a useful conservative endpoint; a production regression test should also check receipt of a real input event without a main-thread stall.

The Mac had an unrelated background workload. Interleaving reduces ordering bias, but these are exploratory measurements, not device performance guarantees. Five trials do not establish a reliable tail percentile. Repeated force quits keep many OS caches warm; launch after reboot or memory pressure still needs separate device testing. Apple describes these launch conditions as a spectrum in its [launch-time guidance](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time).

## Controlled comparison

Medians in milliseconds; five launches per condition, randomized within five comparison blocks:

| Experiment | Focus requested | Focus call returned | Keyboard appeared |
| --- | ---: | ---: | ---: |
| Current launch path | 398 | 578 | **1,047** |
| Open search in `viewIsAppearing` | 280 | 345 | **897** |
| Skip startup toolbar/search crossfade only | 384 | 551 | **1,043** |
| Skip summary glow preparation only | 353 | 519 | **1,030** |
| Earlier search + omit other startup work | 242 | 310 | **802** |

Earlier search improved the median keyboard endpoint by **149 ms / 14%**. The combined experiment improved it by **245 ms / 23%**; its advantage within each comparison block was 236–259 ms.

The combined experiment opened search earlier, skipped its initial crossfade and expansion spring, and omitted initial page navigation, sync startup, download setup, speech preparation and summary glow generation. **Those tasks were disabled for this experiment; production-safe deferral and handoff were not implemented.** It still constructed all hidden panels and the selected WebKit view. Its result establishes an opportunity, not a finished optimization or a sum of each individual change's savings.

The crossfade-only and glow-only experiments did not show a dependable keyboard-ready improvement across all five blocks. Glow generation still consumed about 50 ms on the main thread, but removing work does not necessarily save its full duration from the endpoint: some work overlaps the wait for appearance or keyboard services.

## What the physical trace says

The existing Debug app spent **368 ms in scene connection**. Initial frame rendering completed about **480 ms after the first recorded process-initialization phase began**. Search focus was still executing in samples about **706–786 ms after that phase began**, after the first frame. There is no exact keyboard-ready endpoint in this uninstrumented phone capture.

Among 67 main-thread running samples during scene connection:

| Inclusive stack | Samples | Share of scene samples |
| --- | ---: | ---: |
| Browser controller initialization | 50 | 74.6% |
| `makeWebView` | 15 | 22.4% |
| `FindPanel.init` | 9 | 13.4% |
| `SharedTabsSync` | 6 | 9.0% |
| `AppSettingsPanel.init` | 3 | 4.5% |

These are overlapping inclusive stacks; they must not be added. The capture warned that a requested 1 ms sampling interval differed from the configured 5 ms interval, so sample counts are not converted into precise CPU milliseconds. First-party stacks are symbolicated. The phone was a different build, runtime and device from the simulator, so its times are not a before/after comparison.

The separate optimized simulator ETTrace also attributed sampled stack time to `BottomBar.init` (~96 ms inclusive), `AppSettingsPanel.init` (~31 ms), and the summary glow-preparation closure (~46 ms). Its marked AppDelegate-to-keyboard span was ~1.09 s. First-party frames resolved, although optimized functions can appear as aliases or `<deduplicated_symbol>`; many iOS 27 system symbols were unavailable. Use this capture for app-level corroboration, not precise system-framework attribution.

## Recommendations, in priority order

### 1. Make search the initial launch surface and focus it earlier

[BrowserViewController.swift:476](../Apps/iOS/Rise/BrowserViewController.swift#L476) opens search in `viewDidAppear`, after setup, first layout and the initial appearance transition. It also runs download setup before opening the panel. [openPanel](../Apps/iOS/Rise/BrowserViewController.swift#L1179) prepares search results, hidden-panel appearance, blurred copies and the expansion animation before requesting focus.

Use a separate initial-scene path that prepares the search layout and requests focus as soon as the view is attached and its geometry is valid. The `viewIsAppearing` experiment is a concrete starting point. Consider presenting search already open on cold launch while keeping the existing spring and crossfade for subsequent New Page taps. This removes a transition between two states the person never asked to visit. The earlier-focus experiment preserved the normal opening animation; the combined experiment also skipped it.

Validate cold launch, an external URL, home-screen History/Downloads actions, private search, accessibility sizes, rotation and scene reactivation. Search must never steal focus from an explicit incoming link or reopen on an ordinary resume. Preserve text and selection when deferred work finishes.

**Evidence:** the strongest directly measured keyboard-ready improvement. **Effort:** small-to-medium for early focus; medium for a clean search-first startup state.

### 2. Restore inactive tabs without constructing WebKit views

[BrowserViewController.swift:166](../Apps/iOS/Rise/BrowserViewController.swift#L166) maps every restored tab to `makeWebView`. Page navigation is lazy, but view creation, configurations, user scripts, observers and delegate installation are eager.

| Saved tabs | Median total `makeWebView` time | Runs |
| --- | ---: | ---: |
| 1 | 21 ms | 6 |
| 20 | 108 ms | 5 |
| 100 | 479 ms | 5 |

Store a tab's ID, URL, title, history and preview independently from an optional live web view. Materialize the selected page when needed and inactive pages on selection. With search covering launch, even the selected live view could potentially wait while a saved preview fills the background.

This requires auditing `track`, tab reconciliation, close/select paths, session serialization, preview generation and `sessionTab`: none should accidentally materialize every web view. Preserve private-store isolation and back/forward history. A simple `lazy` property alone will not achieve that.

**Evidence:** large, directly measured scaling cost; a fully lazy implementation was not prototyped. **Effort:** medium-to-large. This becomes the highest priority for people with many tabs.

### 3. Create and lay out other panels on first use

[BottomBar.swift:80](../Apps/iOS/Rise/BottomBar.swift#L80) creates Search, More, Find, settings, privacy, downloads and history eagerly. The hidden panels together cost **61 ms** in the interleaved baseline, with 60–95 ms medians across the broader fixtures. [FindPanel.swift:94](../Apps/iOS/Rise/FindPanel.swift#L94) creates two SwiftUI hosting controllers before Find is opened. Settings builds menus, text fields and Keychain-backed key display state.

Keep search and the necessary toolbar shell ready; instantiate the other surfaces when first requested, then retain them. Move their action wiring and host attachment into the same one-time setup. Also change `contents`, gesture setup, availability refreshes and [layoutSubviews](../Apps/iOS/Rise/BottomBar.swift#L366), which currently access and size all panels: merely changing `let` to `lazy var` would immediately force them again.

Keep the first opening responsive through lightweight setup or idle-time preparation after search is usable. Do not replace the existing small SwiftUI controls simply to avoid SwiftUI; avoid creating them before they are needed.

**Evidence:** direct constructor measurements and physical profile stacks. **Effort:** medium.

### 4. Remove summary glow generation from the launch path

[BrowserViewController.swift:2129](../Apps/iOS/Rise/BrowserViewController.swift#L2129) schedules `SummariseView.prepareGlows()` using `DispatchQueue.main.async`. It still runs on the main thread, and in the captures it ran before the first search opening. [Summarise.swift:1720](../Apps/iOS/Rise/Summarise.swift#L1720) creates gradients, a Core Image context and blurred images for a feature that is not visible.

Prefer generating these fixed glow assets at build time and bundling them. Alternatively, generate them on demand or after the keyboard settles, with an appropriate concurrency boundary and no competing interactive work. Keep their appearance and existing summary motion unchanged.

**Evidence:** ~50 ms direct work in the paired baseline and ~46 ms sampled inclusive time. The keyboard endpoint improved only ~17 ms by median when this alone was omitted, with inconsistent block-level results. **Effort:** small-to-medium.

### 5. Separate startup metadata from expensive session/history payloads

[MobileBrowserSessionStore.load](../Apps/iOS/Rise/MobileBrowserSession.swift#L75) uses `writer.sync`; the main thread waits for the read, decode and validation. The saved file also embeds each tab's WebKit interaction state, up to **2 MB per tab before JSON base64 overhead**. Every launch decodes all of it, even though only one tab might be used. History, learned searches and the sync cache also load synchronously.

Read and decode immutable values off the main actor; hand back a coherent snapshot before creating main-thread UI. For a larger improvement, split compact tab metadata from per-tab interaction-state files and load those archives only when materializing that tab. Avoid an empty initial state later overwriting restored data or syncing an incomplete session.

The 2,000-entry history fixture spent a median **60 ms in suggestion-store initialization** and **43 ms in sync startup**. That fixture exercised supported legacy-history migration on every run; it demonstrates that path's cost and must not be presented as steady-state history performance. Current-format history and large interaction archives need separate benchmarks before choosing the storage redesign.

**Evidence:** synchronous paths in code; a measured migration stress case. **Effort:** medium; larger for a storage format change.

### 6. Defer cloud reconciliation and coalesce cache serialization

[viewDidLoad](../Apps/iOS/Rise/BrowserViewController.swift#L2122) starts tab/history sync before search is ready. [SharedTabsSync.start](../Sources/RiseCore/SharedTabsSync.swift#L79) merges local state and captures tabs/history synchronously. [persist](../Sources/RiseCore/SharedTabsSync.swift#L266) encodes the complete cache on the caller before dispatching the file write. Repeated startup status/capture changes can encode it repeatedly.

Show local search data first, then start cloud reconciliation after the launch endpoint. Coalesce writes and arrange immutable snapshot encoding away from the main actor. Preserve immediate local durability, correct merge ordering and the guard that prevents remote tab changes from disrupting an open search.

**Evidence:** low ~3 ms with an empty paired fixture, higher in the migration stress case, and visible in the phone stacks. Data-dependent priority; do not expect a large gain for every launch. **Effort:** medium.

### 7. Keep download restoration out of search readiness

`setUpDownloads` runs in both toolbar setup and `viewDidAppear`. `MobileDownloads.shared` synchronously restores records, checks files and reads sizes, then enumerates ActivityKit activities. The duplicate wiring itself is cheap after the first call, but the first initialization is unnecessary for typing. It took about 26 ms inclusive in the ETTrace run.

Attach download confirmation support when needed, restore the list asynchronously, and perform stale live-activity cleanup after the launch endpoint. Keep active transfer callbacks and toolbar progress correct. Benchmark a realistically large downloads folder before redesigning the model.

**Evidence:** code and sampled startup work; no isolated production-safe deferral was implemented. **Effort:** small-to-medium.

### 8. Decode only the suggestion icons that are needed

[MobileSuggestionFavicons.swift:24](../Apps/iOS/Rise/MobileSuggestionFavicons.swift#L24) reads and decodes up to 128 saved icons synchronously during address-store creation, even though only a few suggestion rows are visible. Keep cached bytes available and decode visible icons on demand, or preprocess them away from the main actor before publishing images. Use placeholders without delaying the field.

**Evidence:** code-level opportunity; the empty-icon fixtures do not quantify this saving. **Effort:** medium.

### 9. Load AI credentials when a feature needs them

`AISettingsGroup.init` calls `refresh`, which reads the selected provider's key. Startup settings updates refresh it again although Settings is hidden. The phone trace contains `SecItemCopyMatching` inside this work. Lazily creating Settings avoids most of it; otherwise cache the display state appropriately and read the actual key when opening settings or invoking AI.

Do not move secrets into preferences or logs, and invalidate any in-memory cache on provider/key changes. **Evidence:** code and one sampled Keychain call; no reliable standalone saving quantified. **Effort:** small.

### 10. Give keyboard setup the earliest useful opportunity

The baseline's synchronous focus call alone took a median **174 ms**; the keyboard's later appearance added substantial asynchronous time. Calling focus earlier reduced the synchronous call to about **66 ms**, but that does not eliminate keyboard work—it changes when UIKit can perform it.

Focus the actual search field rather than warming a throwaway field and then focusing search. The existing `KeyboardWarmer` is not on this normal cold-search path, so removing its one-second timer would not accelerate this case. Keep stable keyboard traits (`.webSearch`, `.go`, correction off) and measure visible keyboard plus real input, not only `isFirstResponder`. Do not depend on private keyboard APIs or third-party keyboard internals.

**Evidence:** direct timings and current call flow. **Effort:** mostly covered by recommendation 1.

### 11. Schedule optional preparation after interaction is ready

Speech asset installation is already detached with utility priority, and ad-filter resource validation is already offloaded. Preserve that useful separation. Consider postponing speech preparation, preview-cache/icon work and nonessential page-analysis callbacks until the startup interaction is ready, then yield/cancel when the person types. Main-actor `Task` work and `DispatchQueue.main.async` still compete with input; changing syntax alone does not make work background work.

Do not disable ad or cookie protections to improve launch. If initial navigation is deferred, apply the existing protections before that navigation starts. Background tab preview rendering already checks whether a panel is open; preserve that behavior.

**Evidence:** code-level scheduling opportunities; not individually quantified. **Effort:** small-to-medium.

### 12. Use a representative launch background and verify Release on the phone

If search is the intended first screen, consider launch-screen colors and a cached page preview that visually match that state. A coherent first frame can avoid an empty page flash while WebKit starts. This improves perceived continuity rather than necessarily reducing execution time; do not use it to hide delayed focus.

The installed phone build is Debug, while the simulator experiment is optimized. The project already uses `-O` and whole-module optimization for Release. A physical Release comparison is necessary before choosing a shipping launch budget. There is no evidence that changing optimization flags, adding manual keyboard warming, or broadly removing system frameworks is the best first fix. The app delegate's remote-notification registration occupied only about 0.5 ms in the phone capture.

**Evidence:** build configuration, matching phone binary and trace. **Effort:** small for validation; medium for a polished initial presentation.

### 13. Keep a launch-to-input regression benchmark

Add signposts around scene setup, local snapshot loading, tab materialization, panel preparation, focus and the final usable state. Pair a first-frame launch metric with a custom post-launch keyboard/input metric, since the first frame occurs before the requested task is ready. Apple's [launch-time documentation](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time) explicitly distinguishes these endpoints.

Run optimized, debugger-free physical-device tests with 1/20/100 tabs, rich history and icon caches, offline operation, no iCloud account and an active account. Include force-quit relaunch, first launch after installation/update, and launch after memory pressure. Keep settings/private-tab/external-link correctness checks separate from the launch timing. Compare multiple launches and retain distributions; do not add the individual measured costs as if all savings were independent.

## Suggested implementation sequence

1. Implement and validate earlier focus with existing interaction behavior; measure on an optimized phone build.
2. Introduce an explicit initial-search state, and move glow generation/download restoration/optional sync work beyond its readiness boundary. Preserve the ordinary New Page transition.
3. Make inactive tabs genuinely lazy. Make non-search panels lazy, including their setup and layout paths.
4. Benchmark realistic persisted data before changing session/history storage and icon decoding.
5. Retain the custom launch-to-input benchmark and monitor first-frame and input-ready times separately.

## Artifacts and reproduction

The artifact directory contains `measurement-summary.json`, all 56 raw event records, `iphone-existing-app.trace`, exported lifecycle/profile XML, `iphone-profile-summary.json`, the processed ETTrace JSON and its analyzer output, the instrumentation patch, and the measurement scripts. Failed trace attempts are excluded.

The temporary patch is diagnostic scaffolding, not a proposed production patch. Apply it only to a disposable copy of the measured commit. Build and relaunch using `./scripts/restart.sh --ios --simulator <UDID> --configuration Release`, enable the software keyboard through native Device Hub controls, and adapt the simulator/container paths in the scripts. The timing build does not link ETTrace. For sampling, link the simulator ETTrace framework temporarily, collect UUID-matched dSYMs, launch from Home, and remove its wiring afterward.

Original simulator session/preferences were backed up before synthetic fixtures. The final cleanup restores that session/preferences and reinstalls the uninstrumented baseline app. App-source changes and TestFlight/device replacement are outside this audit.
