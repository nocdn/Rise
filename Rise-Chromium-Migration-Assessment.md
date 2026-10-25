# Rise: WebKit → Chromium feasibility assessment

Assessed 5 October 2026 against the current working tree at `/Users/bartosz/github/Rise`. This is analysis, not an implemented migration. The only app changes made for this request are the separately requested URL-picker font/padding correction.

## Decision

**A Chromium-backed Rise with the existing AppKit interface is feasible. It is a substantial browser-backend migration, not a replacement of one view class.** Keep the current native interface, its layout constants, fonts, continuous corners, shadows, popovers, and motion code. The preferred first route is Chromium Embedded Framework (CEF), behind a narrow Objective-C++ bridge to Swift.

Your latest priority changes the acceptance criteria: the interface and **Peek must retain their current appearance and behavior**. Swipe effects are a lower priority. Therefore an embedding/Peek experiment must pass before investing in the full conversion. A working Chromium page alone would not establish that the migration is successful.

There is an important qualification: the CEF configuration that fits the current native macOS interface uses **Alloy-style browsers**. This does not bring all of Chrome's browser-level features. If the underlying purpose of the migration is complete Chrome extension, password/autofill, or passkey parity, that is a separate, potentially more expensive requirement. Chromium rendering compatibility and Chrome product-feature compatibility are different outcomes.

## What I examined

Rise has 66 Swift source files, comprising 6,939 lines. Nineteen files directly reference WebKit, comprising 3,224 lines; several other files indirectly use `tab.webView`. These numbers describe the coupling surface, **not the percentage that must be rewritten**. For example, the 385-line download-flight file imports WebKit but its animation is mostly independent native code.

The audit covered tab construction and observation, navigation/UI/download delegates, controller ownership and layout, split views, Peek and standby pages, swipe routing, Metal snapshot transitions, script injection, permissions, preloading, ad blocking, favicon/history persistence, native controls, build/signing, and tests. There are 33 Swift test/benchmark files with 117 `test…` methods; 23 reference WebKit or `webView`. Existing test intent is useful, but many integration fixtures would need to change engines.

The external API reference was pinned to CEF commit `ff57d4eae16d36457895f2de115a71d502e85a08` from 29 September 2026. That is an inspection snapshot, **not a selected release for shipping**. No CEF runtime was installed, no Chromium page was run, and no performance or behavioral compatibility was experimentally established in this assessment.

## Engine choice, with the current UI as the priority

| Route | Effect on Rise's existing interface | Assessment |
|---|---|---|
| CEF native child view, Alloy style | Existing NSWindow and AppKit controls remain; replace the page view and engine services | Best first candidate. Least disruptive to native input and accessibility. Peek capture and compositing must be demonstrated. |
| CEF off-screen rendering, Alloy style | Existing chrome remains; Rise owns the rendered page surface and input forwarding | Potentially excellent for capture/animation control, but significantly more implementation responsibility for text input, focus, accessibility, popups, dragging, cursor, scrolling, and display scaling. A fallback, not the first choice. |
| CEF Chrome style | More of Chrome's browser features, but a different hosting arrangement | Not a drop-in native child view on macOS. Conflicts with the easy route to preserving Rise's view hierarchy and multiple page surfaces. Investigate only if specific Chrome features are mandatory. |
| A maintained CEF fork | Native UI could remain while missing browser features are added | Possible escalation after identifying a specific blocker. Every engine update would also have to carry and verify our patches. |
| Direct Chromium fork/content embedding | Native UI can theoretically remain, but embedding infrastructure and integration must be maintained | Much larger undertaking. Appropriate only if CEF demonstrably cannot satisfy required features. |
| Electron | Chromium is readily available, but its supported window/view model is Electron's | A poor fit for preserving this exact Swift/AppKit application. An ordinary Electron port would recreate native UI that already works. |

The pinned macOS CEF header explicitly says supplying `parent_view` or using windowless rendering selects Alloy style. Windowless rendering also always uses Alloy in the runtime-type header. This is not solved by an old `chrome_runtime=true` tutorial: the old Alloy **bootstrap** was removed in M128; browser **style** is still a separate choice. Chrome extensions are supported with Chrome-style browsers/windows, not Alloy-style ones. [CEF macOS window API](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/internal/cef_types_mac.h), [runtime styles](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/internal/cef_types_runtime.h), [maintainer explanation](https://github.com/chromiumembedded/cef/issues/3685), [Alloy extension request closed as not planned](https://github.com/chromiumembedded/cef/issues/3859).

Electron's WebContentsView is part of Electron's own View/window architecture; it does not offer a supported Swift `WKWebView` substitute inside the current application. Direct Chromium builds introduce a much larger source/toolchain workload than using a CEF binary distribution. [Electron API](https://www.electronjs.org/docs/latest/api/web-contents-view), [Chromium macOS build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md), [CEF project](https://github.com/chromiumembedded/cef).

## What can stay, and what changes

| Rise feature | Existing implementation | Migration work / difficulty |
|---|---|---|
| Sidebar, tabs, rename/reorder, haptics | Native AppKit views and models | Keep drawing/layout/motion. Replace loading/progress data and page focus calls. Low risk. |
| Small URL bar, expanded picker, suggestions, Google/Kagi, switch-to-tab | AppKit plus RiseCore history/ranking and URLSession | Keep. No engine-based rewrite of the palette needed. Low risk. |
| Native settings, copy/AirDrop, notification prompts | AppKit popovers and actions | Keep presentation and preferences; replace engine operations underneath. Low visual risk. |
| Inset page size, continuous corners, shadow | `PageAppearance`, `PageSurface`, Core Animation | Keep existing frame and contour constants. Verify CEF GPU content clips and transforms correctly inside them. Medium integration risk. |
| Page navigation, popup/new-tab policy, errors | `BrowserTab`, KVO, WK delegates | Replace with CEF load/display/lifespan/request handlers and explicit async state. Medium/high work. |
| Peek | Live second page plus ghost snapshots and native springs | Preserve animation code; replace DOM link lookup, image capture, first-paint detection, page ownership and promotion. Highest fidelity priority. |
| Split tabs | Two independent child page views | Preserve layout and tab grouping. Validate two CEF views, keyboard focus and context sharing. Medium risk. |
| Swipe arrows, threshold haptic | Native event routing and `HistorySwipeState` | Keep gesture mathematics/haptics. Replace page hit-testing, isolated DOM probe, replay and navigation. Medium risk. |
| Compression/ripple | Metal drawing over captured pages | Keep shader/motion; replace capture and history-entry cache keys. Lower priority, medium/high capture risk. |
| Ad blocking | WK content-rule lists, native compiled rules | Replace backend completely. Reuse ad filter lists and toggle UX. High work. |
| Hover preloading/shimmer | Hidden WK pages sharing storage, isolated hover bridge | Keep pill/shimmer. Replace page bridge and cache-warming mechanism. Medium/high work. |
| Find, zoom, developer tools, dialogs | WK APIs and AppKit UI | Map to CEF APIs; preserve native controls. Zoom and callback semantics differ. Medium work. |
| Downloads | WKDownload feeds native model/progress | CEF download handlers feed the same model. Keep collision-safe filenames and flight animation. Medium work. |
| Favicons, frequent links, tab metadata | Mostly engine-independent persisted data | Preserve stored icons/history/titles/pins/settings. Replace page icon discovery when useful. Low risk. |
| Back/forward restoration, website storage | WK `interactionState` and default website data store | No compatible import into CEF. Requires an explicit transition plan. High compatibility risk. |

Local entry points: [BrowserTab](/Users/bartosz/github/Rise/Sources/Rise/BrowserTab.swift:5), [controller integration](/Users/bartosz/github/Rise/Sources/Rise/BrowserController.swift:335), [navigation delegates](/Users/bartosz/github/Rise/Sources/Rise/WebDelegates.swift:5), [page outline](/Users/bartosz/github/Rise/Sources/Rise/PageAppearance.swift:6), [split attachment](/Users/bartosz/github/Rise/Sources/Rise/SplitTabs.swift:20).

## Preserving Peek exactly

Peek is already structured in a favorable way. It animates an AppKit ghost card rather than repeatedly resizing the live browser during the animation. Its open spring is 0.3 seconds with bounce 0.12, close spring 0.22 seconds with bounce 0.11, and the background page recedes to scale 0.982. These are native animation decisions and can remain unchanged. Its shadow, clipping, card placement, control reveal and interrupted-open reversal can remain too. [Peek implementation](/Users/bartosz/github/Rise/Sources/Rise/PeekTransition.swift:89).

The hard part is the image supply. Current Peek locates and remembers the originating link in an isolated JavaScript world, crops a WK snapshot of that link, streams page snapshots into the growing card, then hands over to the real live page. Closing captures the current Peek and locates the source again, with an 80 ms fallback; opening has a 150 ms fallback. The standby feature invisibly renders a page at the final card size after an 80 ms modifier-hover dwell and promotes that **same page** when clicked. A Chromium version must preserve state during standby → Peek → full-tab/split promotion, not load a duplicate browser at each step. [Standby ownership](/Users/bartosz/github/Rise/Sources/Rise/PeekStandby.swift:25).

For native CEF, investigate its in-process DevTools protocol methods for isolated-world script execution and `Page.captureScreenshot`. This is not the same as turning on a network debugging port. CEF supports sending these methods without a visible DevTools frontend or remote-debugging session. However, protocol screenshots are asynchronous and encoded: API availability does **not** establish that repeated captures meet Peek's deadlines. Generic `NSView` bitmap caching must not be assumed to capture GPU-backed web content correctly. [CEF protocol integration](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_browser.h).

The off-screen alternative can supply rendered frames directly. The pinned CEF implementation includes a macOS IOSurface path, and the rendering callback describes access through Metal. It requires copying content into an app-owned texture within the documented frame lifetime; retaining CEF's pooled surface indefinitely is invalid. There is a stale Windows-only comment elsewhere in the API and an open macOS external-begin-frame bug, so the chosen release/configuration needs a real test. Do not design around unverified manually driven frames. [Rendering callback](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_render_handler.h), [macOS frame implementation](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/libcef/browser/osr/video_consumer_osr.cc), [reported begin-frame issue](https://github.com/chromiumembedded/cef/issues/4033).

**Peek acceptance gate:** compare the same pages in the current build and prototype at the same window size, theme and display scale. Require the same link-origin crop, springs, backdrop scale, corner contour, shadow and control timing; no white/black flash at handoff; no reload on promotion; correct pointer and text focus; correct closing target after source scrolling; reliable reversal when dismissed mid-open. Test slow pages, video, cross-origin frames, form state, split views, repeated opening/closing, Retina/non-Retina displays and Reduce Motion. Capture frame sequences, not only final screenshots. If native capture cannot deliver that result, test off-screen rendering before accepting any Peek simplification.

Website pixels themselves may differ between Blink and WebKit. The requirement can preserve Rise's native UI exactly; it cannot make different rendering engines draw every website identically.

## Backend work that cannot be skipped

### Lifecycle, event handling and threading

`BrowserTab` currently constructs a usable WK view synchronously, observes its properties and often relies on normal native object lifetime. CEF browser creation and closing are callback-driven. Browser/renderer/GPU helpers, process crashes, async `beforeunload`, popup ownership and shutdown all need explicit management. Closing a Swift tab must initiate browser closure and keep the bridge alive until CEF reports completion. Detaching an inactive tab's view must not accidentally destroy its browser.

CEF's macOS API requires an NSApplication subclass implementing its application protocol. Rise currently calls `NSApplication.shared` and runs the regular AppKit loop. Initialization must precede creating the wrong application class, and current BrowserWindow event interception needs to coexist with CEF's event scope. Network callbacks must not synchronously block on Swift's MainActor; UI events must be delivered on the appropriate UI thread. Renderer RPC replies need cancellation and generation checks when tabs navigate or close. [Required application protocol](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_application_mac.h), [macOS sample lifecycle](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/tests/cefsimple/cefsimple_mac.mm), [CEF lifecycle callbacks](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_life_span_handler.h).

### JavaScript bridges and permissions

Rise uses distinct WK content worlds, document-start scripts, frame metadata and message handlers with replies. These are part of hover detection, Peek lookup, gesture eligibility, notifications and automatic PiP. Replacing `webkit.messageHandlers` with a global JavaScript object is insufficient: scripts need isolated contexts, per-frame installation, trusted browser/frame identity, bounded payloads, navigation cancellation, and no privileged methods exposed to arbitrary sites.

CEF permission/media callbacks can feed the current native permission coordinator and saved origin decisions. Preserve origin including scheme/port, visible-page checks, and resolve-once semantics. OS camera/microphone/location permissions still matter. Current notifications are a page-level native shim, not a complete service-worker Web Push implementation; a migration should not silently expand that scope. Automatic PiP has WebKit-specific code and must be adapted and tested independently. [Current coordinator](/Users/bartosz/github/Rise/Sources/Rise/PermissionCoordinator.swift:17), [CEF permission API](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_permission_handler.h).

### Ad blocking

The current compiled WK rule JSON cannot be attached to a Chromium browser. Keep the original EasyList input and Rise-specific ad rules, then use a native filter matcher through CEF request interception. Brave's `adblock-rust` is a credible candidate because it implements network and cosmetic filtering, hosts rules and additional filter syntax. It still requires integration, resource packaging and its license/notices; it is not a one-call CEF plugin. [Current blocker](/Users/bartosz/github/Rise/Sources/Rise/AdBlocker.swift:6), [Brave library](https://github.com/brave/adblock-rust).

Matching must include requesting-frame origin, resource type, exceptions, redirects and relevant worker requests. Cosmetic hiding needs its own installation and dynamic-document behavior. Decisions should happen efficiently on the engine's request path, not through an AppKit callback per resource. Preserve the enabled-by-default preference and reload-on-toggle behavior, including Peek, standby and inactive tabs. Re-run controlled request/cosmetic tests and the public test suites; the WebKit build's scores do not prove Chromium blocking parity. [CEF request interception](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_resource_request_handler.h).

### Preloading, history and stored website data

Current preloading uses up to two JavaScript-disabled WK pages sharing the source data store. A plain URLSession fetch would not necessarily warm Chromium's actual HTTP cache. Investigate CEF requests sharing the same RequestContext, or restricted background CEF browsers, and demonstrate cache reuse rather than assuming it. Retain the concurrency/rate/timeout controls and only shimmer after successful completion. [Current preload policy](/Users/bartosz/github/Rise/Sources/Rise/LinkPreloader.swift:74), [CEF contexts](https://github.com/chromiumembedded/cef/blob/ff57d4eae16d36457895f2de115a71d502e85a08/include/cef_request_context.h).

Rise saves an opaque WK `interactionState` blob for each tab. CEF's inspected public APIs enumerate navigation entries but do not supply a compatible WK blob importer or equivalent general serialization/restoration mechanism. Preserve tab URLs and metadata, but distinguish that from restoring the exact back/forward stack, POST state, scroll state and live document. If exact stack restoration is mandatory, investigate a dedicated CEF extension or an explicit approximate history model; replaying all URLs is not a faithful restoration. The ripple cache also keys images by WK history-item object identity, so it needs stable Chromium navigation identifiers. [Saved state](/Users/bartosz/github/Rise/Sources/Rise/BrowserTab.swift:64), [transition cache](/Users/bartosz/github/Rise/Sources/Rise/PageClothTransition.swift:10).

Use a new Chromium profile directory. Do not point Chromium at WebKit's cookies, IndexedDB, local storage or service-worker databases. Keep the old WebKit data for rollback. Native history, favicon PNGs, tab order, custom titles, pinned/developer flags, split groups and preferences can transfer. Cookie export/import is a separately scoped operation with limitations; the conservative initial transition requires signing in again. Engine-tag saved session data so a fallback build never attempts to deserialize the other engine's blob.

## Passkeys, extensions, media and browser expectations

**Passkeys are a go/no-go experiment if they motivate the migration.** Chrome having WebAuthn does not prove a macOS Alloy CEF child view has the necessary ceremony UI and credential-provider integration. CEF maintainers distinguish Chrome browser functionality from lightweight embedding; older WebAuthn popup reports point to the Chrome route. Their age prevents treating them as definitive proof of present Alloy failure, but they are enough to reject an automatic-support claim. Test credential creation/sign-in, conditional UI, cancellation, hardware keys and cross-device flows on the exact signed CEF prototype. [Maintainer WebAuthn response](https://github.com/chromiumembedded/cef/issues/3505#issuecomment-1546654623), [ceremony UI response](https://github.com/chromiumembedded/cef/issues/3508#issuecomment-1550921306).

For Apple's browser access to credential providers for arbitrary websites, switching engines does not remove the managed entitlement requirement. Apple's current documentation specifies a request by an organization account's Account Holder and review. Keep the existing signing/profile validation; establish which process and APIs need the capability in the chosen integration. Do not promise that a Chromium switch resolves the earlier Apple approval question. [Apple entitlement requirements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).

Do not count full Chrome extension support as a benefit of the recommended Alloy route. Nor should Chrome sync, a password manager, website form autofill, Google-backed services or Safe Browsing be assumed from the presence of Chromium. Rise's existing **URL** autocomplete is its own feature and survives. Chrome-layer browser services need separate support/configuration and sometimes a different style. [CEF architecture](https://chromiumembedded.github.io/cef/architecture.html), [Chromium service/API-key restrictions](https://www.chromium.org/developers/how-tos/api-keys/).

Verify ordinary video/audio codecs, hardware decoding, screen sharing/WebRTC, fullscreen, PiP and PDFs against the selected distribution. Standard CEF media configuration can differ from Chrome; protected streaming also requires an appropriately supported/distributable DRM integration, not merely an EME API. Review codec and Widevine distribution requirements before committing to a build source. Do not copy another browser's proprietary module as the migration plan. [CEF codec discussion](https://github.com/chromiumembedded/cef/issues/3559), [Widevine access process](https://developers.google.com/widevine/access).

## Build, release and ongoing ownership

The current built Rise.app is approximately 28 MB on disk. It uses the system WebKit rather than packaging a browser runtime. CEF adds a framework, helper executables and runtime resources; expect a materially larger package. An exact size, memory, startup or battery comparison requires building the selected runtime. A faster or lighter browser is **not established by this code audit**.

The current SwiftPM/build script only packages one executable and resources. Add a pinned CEF distribution, a compiled Objective-C++ adapter, the framework loader and process helpers, required resources/locales, architecture-aware builds, and debug symbols. Extend signing from the existing outer app to correctly signed nested helpers/frameworks with role-appropriate entitlements, then validate sandboxing and notarization for a distributable build. A successful development launch is not enough. Preserve the current stable development identity and privacy-grant behavior.

With WebKit, engine updates are provided through the OS. With bundled Chromium, Rise owns its engine security-update cadence. Every CEF update requires rebuilding, signing, distributing and rerunning the critical integration suite. Maintain a version/dependency inventory and a practical update path; do not ship `--no-sandbox` or expose remote debugging to make the prototype easier. CEF provides binary releases and process/threading abstractions, but embedding does not remove this operational responsibility. [CEF general usage](https://chromiumembedded.github.io/cef/general_usage.html).

## Proposed implementation boundary — not implemented

Introduce one page-engine boundary, owned by `BrowserTab`, while keeping its existing tab metadata and the UI controllers. The boundary should provide a hosted NSView; readiness/lifecycle events; title/URL/loading/navigation state; navigate/reload/stop/back/forward; a stable history-entry identifier; zoom; find; capture/crop; isolated script RPC; permissions/dialog/download events; focus/visibility; and engine-tagged saved state.

Swift/AppKit remains responsible for layout, tabs, native menus/popovers, preferences, user-facing history/ranking and animation. Objective-C++ owns CEF references, lifecycle, request callbacks, renderer messaging and safe threading. Use CEF's shipped wrapper/API rather than relying on an unmaintained Swift wrapper with its own incomplete coverage. Add only operations actually needed by Rise; do not build a speculative general-purpose browser framework.

Initially keep the existing WebKit backend available for comparison and rollback. Select the backend at app startup during development; avoid automatically switching engines per website, which would fragment cookies/history and double the lifecycle complexity.

## Sequencing and acceptance gates

1. **Freeze visual reference.** Same-size screenshots and motion recordings of native chrome, Peek open/close/reversal, standby promotion, splits, developer-header motion, copy/settings behavior and cursor/focus. Preserve existing appearance constants.
2. **Native CEF + Peek proof.** One page in the current inset, with correct clipping, two-page split, popup, input and shutdown; then link-origin capture, standby rendering, ghost streaming and promotion. This is the first decision gate. If it misses Peek fidelity, investigate off-screen capture before proceeding.
3. **Validate feature blockers early.** Signed passkeys if required; video codecs/DRM expectations; extensions if required; profile/cache behavior. Do not postpone a potential architecture-changing limitation until after porting all UI actions.
4. **Port engine services.** Adapter, navigation/error policy, isolated scripts, permissions, downloads, find/zoom/devtools, preloading, blocker. Preserve native presentation. Restore instant arrow/button/keyboard navigation; implement swipe effects after core/Peek parity.
5. **Migrate persisted data safely.** New profile, engine-tagged session schema, preserved metadata and favicons, explicit limitations for back stacks and site storage, tested rollback. No destructive conversion of WebKit databases.
6. **Parity and release hardening.** Controlled ad-block and preload tests; multiple windows/tabs; close-during-load; beforeunload; renderer/GPU crashes; popup/opener behavior; file inputs and external schemes; media/TCC; cross-origin frames; IME and VoiceOver; display changes and long sessions. Measure cold startup, idle CPU, video power and memory for 1/10/30 tabs. Verify signed/notarized builds and updates.

Keep the current unit-test intent, but port engine fixtures and add targeted lifetime/security/capture tests. The existing live Peek, cloth, download and permission benchmarks are valuable starting points, not proof of CEF behavior. Visual gates should inspect animation frames and fresh screenshots in both engines, not only whether a method returned success.

## Effort and confidence

These are planning judgments for one experienced full-time macOS/CEF developer, not measured estimates or a commitment:

| Milestone | Approximate effort |
|---|---|
| Native embedding + exact-Peek feasibility gate | 1–2 weeks |
| Existing functional parity, including bridges/blocker/data transition | A further 4–8 weeks |
| Reliability, visual/input/accessibility parity, packaging/release checks | A further 2–4 weeks |
| Practical total with contingency | Roughly 8–16 weeks |

An initial page can appear much sooner than this. That is not equivalent to a daily-use browser that preserves the present experience. A required CEF/Chromium fork for extensions, passkeys or exact session restoration may expand the scope substantially; this range assumes those gates permit the ordinary native CEF route.

Confidence is **high** that Rise's existing native chrome can be retained, **medium** that Peek can be preserved without deeper rendering work, and **unproven** for exact website session restoration, all Chrome browser features, performance gains and signed macOS Alloy passkeys. The code is small enough to migrate deliberately, but the browser-runtime edge cases dominate the effort.

**Recommendation:** proceed only with an isolated native-CEF/Peek feasibility experiment if you later authorize implementation. Do not rewrite the interface. If that experiment preserves Peek and meets the actual Chromium feature requirements, migrate the backend in stages. If essential Chrome-level features require abandoning the current UI arrangement or maintaining a major engine fork, reassess that tradeoff before committing.

## UI correction completed alongside this analysis

The expanded URL picker now uses 13.5 pt main text: a 0.5 pt increase over its previous 13 pt baseline. The input area increased from 44 to 46 pt and result rows from 38 to 40 pt, adding a small amount of vertical room. The switch-to-tab caption/shortcut sizes were also reduced by 0.5 pt from the earlier +1 pt change. Position, width, shadow, corner styling and existing regular weight were retained.

Rise was rebuilt and relaunched with the repository restart script, visually checked, and the 10 address-suggestion tests passed. No Chromium migration changes were made.
