# Validation — 13 October 2026

The initial motion changes were committed and pushed as `7c3fe8a` before this work.
The blocker was tested in the real Rise WKWebView on iPhone 14 Pro (iOS 27.2)
and iPhone 17 Pro Simulator (iOS 27). No tap-driving automation was used for the
website checks. The DEBUG audit visits public pages in a non-persistent session,
compares blocking off/on, inspects DOM and resource timing, and saves snapshots
for samples or ambiguous results. Explicit non-essential-cookie rejection buttons
can be clicked by the audit; it never subscribes or accepts all cookies.

## Automated regressions

All five `AdBlockingTests` passed on the phone:

- Default-on policy, saved host preferences, mandatory YouTube exclusions and
  lookalike-domain protection.
- Actual bundled WebKit compilation, blocking a real HTTP ad-pattern script while
  allowing the ordinary script and retaining the article.
- Switch-driven reloads in both directions, native spinner/disabled row during the
  update, preserved settings panel and preserved Rise viewport/paint scripts.
- Spinner cleanup after a replacement navigation and a real network failure.
- Cosmetic filtering/removal on a public-origin fixture, a maintained document-start
  detector fix, and native YouTube fallback exclusions while lists remain installed.
- Removing/reinstalling the catalog when a page changes browser owners.

Four existing navigation/UI regressions also passed: fresh-launch search,
address editing, Peek adoption, and rapid More → Site settings taps. The selector
runtime tests passed for host/path scopes, exclusions, scriptlet aliases, generic
exceptions, both generated YouTube early exits, and a normal destination linked
from YouTube. Asset SHA-256 validation and `git diff --check` passed.

`swift test` ran 299 desktop tests: 3 skipped and 7 failures in two window tests
(`HistorySwipeTests.testRealWebKitHistoryNavigatesOnReleaseAndIgnoresMomentumAndCancellation`
and `YouTubePictureInPictureTests.testPinchResizesTheRealWindowAndRestoresBothLimitsWithoutChangingPlayback`).
Those two tests reproduced the same seven failures on a targeted rerun. No desktop
source, desktop filters, package settings or Chromium branch was changed.
Simulator XCTest could not start because Xcode reported
`DTServiceHubClient failed to bless service hub`; the phone ran the XCTest suite.

## Public websites

There were 50 paired-mode page loads across 20 sites (including repeated samples
on the phone). No visible “disable your ad blocker” warning was observed in these
runs. This is coverage of the tested pages/time, not a universal detector bypass.

| Site | Ad blocking / compatibility observation |
| --- | --- |
| The Guardian | 9 visible ad slots → 0; article text retained; ordinary consent prompt remained. |
| CNN | Content loaded in both modes; no ad-block warning. |
| The Verge | 7 visible slots → 0 after consent rejection; confirmed on phone too; article text retained. |
| Ars Technica | 5 visible slots → 0; content retained; ordinary consent prompt remained. |
| Tom's Hardware | Content retained; advertising-host resource entries disappeared. |
| PCWorld | Content retained; Amazon advertising resource entry disappeared. |
| Speedtest | Page loaded in both modes; no ad-block warning. |
| IMDb | Page loaded in both modes; no ad-block warning. |
| Time and Date | Page loaded in both modes; no ad-block warning. |
| AccuWeather | Page loaded in both modes; no ad-block warning. |
| Reuters | Page loaded in both modes; no ad-block warning. |
| BBC | Page loaded in both modes; no ad-block warning. |
| Wikipedia | Content/navigation control loaded in both modes. |
| Hacker News | Content/navigation control retained. |
| Can You Block It | Test page loaded in both modes; no custom benchmark rules added. |
| Forbes | Content loaded without an ad-block warning; ordinary consent prompt remained. |
| India Today | Content retained; advertising-host resource entries disappeared. |
| Android Authority | Content retained; DoubleClick/Amazon advertising entries disappeared; confirmed on phone. |
| PC Gamer | Content retained; advertising-host resource entries disappeared. |
| YouTube | Confirmed on phone: both attempted settings left the blocker uninstalled, 0 blocker scripts, and the ad switch off/disabled. |

Resource-timing entries are supporting evidence, not a packet capture: blocked or
cross-origin requests can still appear in timing data. DOM ad slots can be empty
placeholders. The HTTP fixture and paired snapshots provide independent checks.
The audit does not bypass paywalls, consent requirements or login restrictions;
cookie consent prompts can still cover a page. Separate tracker/cookie-banner
controls remain visual and are not implemented by this change.

## Reproduce

```sh
node scripts/ios-adblock/runtime.test.mjs
python3 scripts/update-ios-adblock.py --reuse-sources
./scripts/restart.sh --ios --device <device-id>
```

Run `RiseiOSTests/AdBlockingTests` with Xcode on the phone. For public-site checks,
launch the DEBUG app with `-RiseAdBlockAudit caches:<folder>`; optional comma-separated
site indices select a subset. Results and snapshots are saved under the app's
`Library/Caches/<folder>`. `fixtures` in place of the indices runs the native
running-app checks when Simulator XCTest is unavailable. Finish by relaunching
normally with `./scripts/restart.sh --ios --device <device-id>`.
