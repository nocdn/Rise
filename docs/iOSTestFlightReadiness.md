# Rise iOS readiness review — 21 October 2026

Read-only source review by a GPT-6.1 Sol subagent at xhigh, against the current
checkout, including the recent private-browsing and summary-cache changes. The
subagent changed no files, ran no builds, and submitted nothing. This is not a
complete runtime test pass or a prediction of Apple's review decision.

**Current status (22 October 2026): version 0.1.0 (build 3) submitted to Beta App
Review, Waiting for Review.** The historical findings and checks below are retained;
the latest submission follow-up supersedes earlier statements about review being
on hold. The basic browser appears structurally eligible to apply for the iOS
default-browser capability.

## Submission follow-up — 22 October 2026

- Disabled the embedded-video **Download Video** action with a fixed false flag
  in `VideoContextMenus`. The implementation remains in source; playback and
  copy/share actions are unchanged. All nine existing video-menu tests passed
  on the physical iPhone in Release configuration.
- Deployed the `RiseTab` and `RiseSearches` schemas to CloudKit Production.
  Console confirmed **Changes Deployed** and both Production record types;
  `RiseTab.payload` is Bytes with the expected indexes. A live Release test build
  signed for Production passed the opt-in two-client CloudKit integration test
  on the iPhone: inserts, navigation, closures and offline reconnection converged.
  Its generated disposable private test zone was cleaned up by the test.
- Rebuilt and relaunched through the required restart script, then archived
  build 3 using the supported App Store Xcode 27.1. App Store Connect processed
  the upload successfully; OS-only encryption compliance was saved.
- Created the prerequisite **Internal Testing** group and **External Beta**
  group, added build 3 to External Beta, supplied What to Test instructions and
  submitted it for Beta App Review. Verified **Waiting for Review**. Both groups
  have zero testers; no invitations or public testing link were issued. The
  submission explicitly has **Sign-in required** unchecked: Rise has no account
  login. Apple's private notes retain the capped review API key.
- Installed the uninstrumented device-test export of build 3 on both paired
  devices after testing. The iPad launch was blocked by its lock screen.
- The recovery test was rerun and still fails with `InvalidTransition { phase:
  idle, targetPhase: failed(deinit) }`; its cause is not established and was not
  hidden or fixed by disabling video downloads. The combined video/recovery run
  therefore had nine passes and one failure. This remains an open verification
  issue; review submission is not a claim that every test passes.

Submission: [Rise 0.1.0 (3)](https://appstoreconnect.apple.com/teams/968654d4-7e80-435c-9b7b-3bf5158384d3/apps/6824847354/testflight/ios/96824f10-4a45-49ba-97da-02d4e8dea3a6).

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

- App Store Connect accepted and processed version 0.1.0 (build 2) on
  2026-10-21. Its status is **Ready to Submit** after completing encryption
  metadata for OS-provided encryption. Beta App Review has not been submitted
  and no testers have been invited.
- The upload was archived from commit `9ccda35adcd1878375232b55609bb1effa63e750`
  with App Store Xcode 27.1 (`27A9275`) and the iOS 27.1 SDK (`24A94232`).
  `CURRENT_PROJECT_VERSION=2` was supplied as a build override; no app features
  were changed. Automatic App Store distribution signing succeeded, with
  Production CloudKit/APNs entitlements for the app and matching build 2 for
  the Downloads widget. This resolves the earlier unsupported-Xcode upload
  blocker. The global Xcode selection was left unchanged.
- TestFlight uses CloudKit Production, while local phone installs deliberately
  use Development. Deployment of the RiseTab/RiseSearches production schemas and
  production sync is not established by local success (see `docs/TabSync.md`).
- AI normally requires a user-supplied provider key with model access. Apple’s
  private Beta App Review notes now contain a dedicated OpenRouter review key
  with a verified $0.50 total cap and expiry of 2027-01-19. The notes include
  setup/consent instructions and a contact route if the cap is exhausted.
  No review credential is included in source, the binary or public metadata.
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
TestFlight gets the icon from an accepted upload, not a separate image field.
The processed 0.1.0 (2) upload contains the compiled Rise primary app icon and
the bundled privacy manifest/policy. Its App Store Connect build is
[available here](https://appstoreconnect.apple.com/teams/968654d4-7e80-435c-9b7b-3bf5158384d3/apps/6824847354/testflight/ios/a0b61a51-7667-42f6-b589-df2ba46a24a2).

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

## Broader pre-review verification — 21 October 2026

The dedicated review credential authenticated successfully and completed a
minimal request to the configured `openai/gpt-6-luna` model with low reasoning
effort. Its cap was already $0.50 total (no reset). A native end-to-end test of
the uninstrumented archived build on the physical iPad also completed a public
example.com summary after the explicit OpenRouter sharing prompt. The summary
was readable after scrolling below the preview card in landscape. Combined
review-key test usage was $0.000085437; the remaining cap was $0.499914563.
The credential itself must remain in Apple’s private notes, not this document.
After the live test, the iPad's previously empty OpenRouter key field was
restored and the temporary AI-sharing permission was withdrawn through the
Privacy Policy panel. The review credential remains available to Apple.

With release Xcode 27.1, the selected suites ran on the physical iPhone 14 Pro
(iOS 27.2) and iPad Air 4 (iPadOS 27.0.1). The builds retained Release
optimization but enabled testability and the existing DEBUG audit hooks solely
for testing. These instrumented test builds are not the uploaded binary.

| Device | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| iPhone 14 Pro | 29 | 1 | 0 |
| iPad Air 4 | 28 | 1 | 1 |

Passing coverage included AI settings/provider transport, consent/revocation,
privacy-panel navigation, session storage/restoration, native back/forward
history, downloads/progress/selection/deletion, and Peek dismissal/expansion.
Real microphone cancellation passed on iPhone; iPad skipped that check because
the required microphone/speech permissions were not already granted.

Both failures were
`BrowserRecoveryTests.testRestoredPageFailureRetryRelaunchAndTabCards`, reporting
`InvalidTransition { phase: idle; targetPhase: failed(deinit) }`. The origin
(app, fixture or test framework) is not yet established. No app fix or feature
change was attempted. After all selected tests finished, Xcode stalled in
post-test collection; interrupting the two runners finalized the result bundles.
Thus neither runner command is reported as a successful overall test pass.
Results: `build/ios-review-iphone-physical.xcresult` and
`build/ios-review-ipad-physical.xcresult`, with compact JSON summaries alongside.

The runtime checks also established a production configuration blocker:
CloudKit rejected writes with **Cannot create new type RiseTab in production
schema** and **Cannot create new type RiseSearches in production schema**.
Production sync must not be reported as working until those schemas are
deployed and end-to-end sync is retested. No cloud schema was changed here.

Separately, the original accepted 0.1.0 (2) archive was exported for registered
device testing with an Ad Hoc distribution profile, `get-task-allow=false` and
Production CloudKit entitlements. That uninstrumented archive was installed on
both physical devices and opened a public webpage. This is a device-test export
of the accepted archive, not an installation delivered through TestFlight.
No app source/features changed, no new Apple build was uploaded, and Beta App
Review remains unsubmitted.
