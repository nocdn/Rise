# Rise iOS readiness review — 21 October 2026

Read-only source review by a GPT-6.1 Sol subagent at xhigh, against the current
checkout, including the recent private-browsing and summary-cache changes. The
subagent changed no files, ran no builds, and submitted nothing. This is not a
complete runtime test pass or a prediction of Apple's review decision.

**Assessment: not ready for external TestFlight review yet.** The basic browser
appears structurally eligible to apply for the iOS default-browser capability.

## Completed alongside the audit

- Added `Apps/iOS/Rise/PrivacyInfo.xcprivacy`, declaring UserDefaults (`CA92.1`),
  app-container file metadata (`C617.1`), and elapsed-time/timer APIs (`35F9.1`).
  These cover preferences, downloads, summary-cache eviction, and local timing.
- Validated the plist, rebuilt the app, and verified all three declarations in
  the packaged app bundle. Installation succeeded; relaunch was blocked by the
  locked iPhone.
- Updated and saved the TestFlight beta description and review notes in App Store
  Connect. They describe optional OpenRouter/OpenAI API-key setup, on-device
  Keychain storage, page-content sharing, and pending browser/passkey capability.
  They no longer claim AI is disabled. No build or review was submitted.

## Findings to resolve before review

### Private UIKit corner lookup replaced

`PageRecede` now uses iOS 26's public container-concentric corner configuration
and `UIView.effectiveRadius(corner:)`. A transparent, noninteractive measuring
view lives behind the window's root view, outside the page's animated transform.
It is reused and laid out before the first moving frame. Earlier iOS versions
and detached views use the existing 32-point fallback; square windows keep the
existing square-screen behavior. No private selector or KVC lookup remains.

### Generic video-download action is a review risk

`VideoContextMenus.swift:130–158` offers Download Video for discovered embedded
media URLs. `VideoContextMenuScript.swift` filters DRM/streams, but does not
establish authorization from the media source. Guideline 5.2.3 addresses
downloading third-party media without authorization. Decide the supported,
authorized scope before submission; actual review treatment is Apple's decision.

Policy source: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Corrections implemented after the read-only audit

- **Delete File:** now deletes the saved file before clearing its row. A failed
  filesystem deletion keeps the row and reports the error. An already-missing
  file can have its stale row cleared. Clear All / Clear Selected remain
  list-only; active transfers retain WebKit's safe cancellation/partial cleanup.
- **Voice cancellation:** cancelled/failed New Page holds call `voice.cancel()`
  before hiding the waveform. The scene also cancels recording when it resigns
  active, and a failed recording start cleans up the audio session.
- **AI sharing:** every iOS model request passes a consent gate in
  `ModelService.run` before either network client starts. Native permission
  explains the provider/recipient, page title/full URL/readable text/selection,
  questions/conversation context and private tabs. Permission is separate for
  each provider and versioned; an existing API key is not consent. Declining,
  cancelling or revoking a pending prompt fails closed. Turning AI off or using
  the policy panel withdraws permission for future requests. Streams recheck
  permission before delivering subsequent events.
- **Privacy policy:** App settings → Privacy Policy opens an offline bundled
  policy with provider links and an AI-sharing permission switch above its text. It describes
  browsing storage, iCloud sync, Google suggestions, optional AI, private tabs,
  voice, downloads, caches and key removal. A non-expiring public copy is at
  [Rise for iOS — Privacy Policy](https://files.bartoszbak.org/paste/cb6aef75a39ee60c7206e93cde60f89c).
  TestFlight metadata was updated with the policy URL and the new review steps;
  no review was submitted.

Verification: all 15 focused iPhone tests passed, including real microphone
cancellation, file deletion/failure retention, provider-specific consent and
revocation, cancelling a presenting native prompt, zero outgoing AI requests
before permission, the bundled policy, provider transports, Ask highlighting
and WebKit downloads. All seven desktop PageAssistant tests also passed. The
required restart script rebuilt, installed and successfully relaunched Rise on
the paired iPhone. TestFlight review remains on hold.

## Privacy behavior and remaining declarations

Private browsing uses ephemeral WebKit storage, excludes private tabs/history
from durable sessions and iCloud snapshots, excludes disk previews, skips
summary-cache access, and adds an app-switcher privacy cover. It still sends
search prefixes to Google through an ephemeral cookie-free client and permits
user-invoked AI requests. Describe that accurately; private is not offline.

Regular summaries persist as plain JSON in Caches, up to 300 entries, with
content-hash filenames (`SummaryCache.swift`). No clear-summary-cache control was
found. The required-reason manifest does not claim no data leaves the device.
App Store privacy answers still need assessment against AI-provider retention
and Google suggestions, distinguishing ordinary web browsing from app-directed
collection. [Apple's privacy-label guidance](https://developer.apple.com/app-store/app-privacy-details/)

## Default browser and website passkeys

- HTTP/HTTPS URL schemes are declared, the app uses system WKWebView, fresh launch
  offers search, and incoming web URLs load their destinations. The audit found
  none of Apple's prohibited broad photo/always-location/HomeKit/Bluetooth/Health
  permission keys. These support the basic application criteria.
- `Rise.entitlements` currently contains CloudKit/APNs only. Apple must approve
  `com.apple.developer.web-browser`, it must be enabled on the iOS App ID, and the
  matching provisioning profile must be regenerated before default-browser
  selection can work.
- Apple's iOS 16.4 release notes state that the browser entitlement enables
  WKWebView passkey AutoFill without code changes. WKWebView handles website
  WebAuthn. After approval/provisioning, test passkey creation, modal sign-in,
  AutoFill, third-party credential providers and hardware security keys on a real
  iPhone. None of those flows is established by this source audit.
- The macOS/Mac Catalyst public-key-credential entitlement and its organization
  Account Holder requirement are separate. Do not treat Individual membership as
  an established disqualifier for the iOS default-browser application.
- A functional public TestFlight evaluation link still depends on an accepted
  upload and external beta review/distribution. Capability approval is separate.

Sources: [Default-browser criteria](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser),
[iOS 16.4 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-16_4-release-notes),
[Web browser passkeys](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers),
[macOS credential entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).

## Release preparation still unverified

- App Store Connect currently shows No Builds. The earlier upload was rejected
  for unsupported SDK/Xcode; the installed Xcode 27 beta remains a blocker.
- TestFlight uses CloudKit Production, while local phone installs deliberately
  use Development. Deployment of the RiseTab/RiseSearches production schemas and
  production sync is not established by local success (see `docs/TabSync.md`).
- AI requires a user-supplied provider key with model access. Reviewers need a
  practical way to exercise advertised optional AI; no personal developer key
  has been included in the notes or build.
- The deployment target is iOS 17 on iPhone/iPad; voice transcription is gated to
  iOS 26. Metadata should state the voice limit if it advertises that feature.
- Verify a distribution/Release build on supported iPhone/iPad configurations
  after fixing the issues. This audit did not run the full test suite.

Sources: [Complete review access](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review),
[External TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).

## App icon verification

The requested Downloads image is already preserved, byte-for-byte, as
`Assets/AppIcon/Original.png` (SHA-256
`07c1ec0b9669675fac5789e92a3c4a54bfee5c54e261a62c99b862c1379439a1`).
The shared `Rise.icon` document references its 1024 × 1024 derivative, both iOS
configurations select it, and the built iPhone app contains the compiled Rise
icons and CFBundlePrimaryIcon metadata. No duplicate source asset was needed.
App Store Connect still shows No Builds; TestFlight gets the icon from an
accepted upload, not a separate image field. The previous upload's unsupported
Xcode/SDK rejection remains unresolved; only Xcode 27 beta is installed.

The public corner geometry resolves to 55 points on the paired iPhone 14 Pro.
The existing scale, downward travel, continuous curves and spring timing are
preserved. Full-size content explicitly clears its temporary corner clipping
at the end of the return animation.

The physical iPhone passed the three `PageRecedeTests`, including all 92 deck
audit checks: the first page/card radius is 55 pt, landing at the unchanged
26 pt card radius, and interrupted flights still work. Light/dark panel captures
were inspected; Peek's drag/return test also passed. An older broad bottom-bar
test still has stale font/opacity, tile-aspect and animation-timing expectations;
this is a focused corner verification, not a full UI-suite pass.
Debug and Release builds succeeded, and the Release executable no longer contains
the private corner selector. Panel-control hit testing passed on the physical
device. Manual Mirroring tap/drag delivery was inconclusive; the same behavior
occurred in a comparison build without the measuring view, so a full manual
interaction pass is not claimed.
The owner subsequently tested the installed fix on the iPhone and confirmed that
it looks good.

Sources: [App icons in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon),
[Public concentric radii](https://developer.apple.com/documentation/uikit/uicornerradius-swift.struct/containerconcentric(minimum:)),
[Effective corner radius](https://developer.apple.com/documentation/uikit/uiview/effectiveradius(corner:)).

## Privacy panel refinement

Privacy uses the existing `BottomBar` panel rather than a modal sheet. It calls
the exact `swapMenuPanel` path used for Site settings → Settings, sharing its
spring, blurred crossfade and Reduce Motion behavior. It grows 100 points taller
than Settings where the screen allows it, capped below the top safe area, and
returns to Settings through the X, edge gesture or accessibility escape.

The supplied blue Tabler shield, standard settings switch row and concise
withdrawal subtitle sit at the top of the same scroller as the policy. They
scroll away together, with a normal settings group gap before the policy text.
A native header in WebKit’s scroll view keeps a single scroller and avoids
creating a document-height WebKit viewport.
The policy text has 32-point horizontal padding, in line with settings subtitles.
Its fixed viewport uses the summary's 140-point `(1 − u)²` bottom fade and 156
points of bottom scroll inset, so the final lines clear the fade completely.

The switch reflects explicit consent for the selected AI provider. Deliberately
turning it on on this disclosure screen grants that provider permission;
turning it off revokes every provider’s permission. Turning AI features off
also revokes it and disables the sharing switch. Neither opening the policy nor
turning AI features on silently grants permission. The group’s shorter AI
subtitle is capped at three lines (errors remain fully readable).

All 14 focused iPhone tests passed, including the native model-request consent
boundary, provider-specific/revocable permission, policy navigation, the larger
panel, scrolling control, gesture arbitration and return to Settings. Rendered
light/dark captures are generated by
`ReviewFixesTests.testPrivacyMorphsInPlaceScrollsPermissionAndReturnsToSettings`
in the app’s `Library/Caches/PrivacyPanelCapture` directory. No review submitted.
