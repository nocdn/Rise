# iOS popup protection

Site settings has independent **Block ads**, **Block popups**, and **Block cookie
banners** rows (red, orange, green). Popup protection defaults on, persists per
host, shares the `www` preference, and keeps private overrides in memory. Changing
it takes effect immediately in sibling pages using that policy, without a reload.

`MobilePopupBlocker` authorizes new windows in `WKUIDelegate`. An isolated-world
document-start script captures trusted pointer/keyboard intent in every frame,
before page handlers can rewrite a link or form destination. Synthetic events and
page-world bridge calls cannot mint an allowance. A recent explicit link, form,
or action button gets one window; generic page/media clicks and invisible large
link overlays do not. Denying a mismatched ad does not consume the real link's
allowance. Native browser context-menu actions keep their own navigation paths.

Popup-only AdGuard Base/EasyList and Mobile Ads rules additionally block known
destinations, including click-driven windows from real buttons. Exceptions,
source-domain scopes, case sensitivity, party restrictions, and `$badfilter`
overrides are retained. The generator rejects unknown modifiers instead of
silently broadening a rule. Source snapshots and licences are shared with the
existing ad blocker; popup rules apply even when ad blocking is off, including
on YouTube. Regenerate with `python3 scripts/ios-adblock/popup_rules.py`, or the
normal `scripts/update-ios-adblock.py` workflow.

Allowed windows use WebKit's supplied configuration in a real tab, preserving
POST bodies, window handles, blank-then-navigate, document writes, exports,
opener access, and the original website data store/private mode. A window's
automatic redirect chain retains popup filtering until the person interacts
with it. Blocked popup redirects close that window and return to the opener.
The opener's script-driven navigation is checked against popup rules for 1.5
seconds after a popup attempt, catching the common popunder swap.

This is a heuristic plus maintained rules, not a guarantee against every unwanted
navigation. A new ad destination opened from a genuine action button can resemble
a sign-in window. Party matching deliberately treats shared two-label suffixes
as first party to avoid false positives between related hosts without shipping
a second public-suffix database. This can miss third-party rules between two
different sites under a suffix such as `co.uk`. Entity block scopes recognize
single-label and common country suffixes conservatively; entity exceptions are
permissive. Ordinary same-tab links and unrelated automatic redirects are not
globally filtered. The per-site switch is the escape hatch for unusual workflows.

## Verification

- `python3 scripts/ios-adblock/test_popup_rules.py`
- `node scripts/ios-adblock/runtime.test.mjs`
- `PopupBlockingTests` and `AdBlockingTests` in the `RiseiOSTests` scheme.
- Running-app audits are available when XCTest's simulator service is broken.
  Run `python3 scripts/ios-popups/fixtures.py --port 8765`, rebuild with
  `./scripts/restart.sh --ios --simulator <UDID>`, then launch Rise with
  `-RisePopupAudit http://127.0.0.1:8765`. Tap each displayed **Run case** control
  using native Codex computer use (iframe controls sit lower). The audit records
  results, policy/matcher/settings checks, and a settings screenshot under the
  app container's `Library/Caches/PopupAudit`. The fixture verifies the tap hit
  its control, and the guard itself has no testing bypass.
- Add `?cases=direct-link,post-form,...` to select cases, and
  `-RisePopupPrivate` to repeat them with actual private tabs. Assertions include
  data-store identity and private-mode inheritance for new windows.
- Existing ad/cookie regressions:
  `python3 scripts/test-ios-cookie-consent.py --simulator <UDID> --no-build --checks-only`.

Fixtures cover intentional links and buttons; click theft; href and form-action
rewriting; synthetic and stale gestures; popup bursts; blank/document-written
windows; GET/POST; shadow DOM; cross-origin frames; invisible overlays; same-window
navigation; popunders; blob exports; `window.close`; disable/re-enable; asynchronous
buttons; `noopener`; and allowed/blocked HTTP and blank-window redirects. All
network endpoints are local fixtures; known ad URLs are denied before opening.

## Diagnosing a reported website failure

Popup diagnostics are enabled in Release as well as Debug. Regular logs live in
`Library/Application Support/RiseDiagnostics/Popups`, survive app updates and
relaunches, and are excluded from backups. The serial writer retains seven UTC
calendar dates, capped at eight 1 MiB segments. Busy sites can rotate older logs
out sooner. No telemetry is uploaded automatically.

Ask for the website, approximate time, and what they tapped. With the iPhone
connected, fetch and inspect the relevant events:

```sh
python3 scripts/popup-log.py --device "Bartek’s iPhone" --site example.com --last 200 --output build/popup-diagnostics
python3 scripts/popup-log.py --read build/popup-diagnostics --site example.com --blocked
```

Private traces are a separate bounded in-memory ring, released with their
private session, and are never written to the persistent log, so they can't be
fetched.

Records include app-run/policy/page/document/request/chain IDs; exact executable
hash (including the Debug library where applicable); version, OS, engine and
filter-catalog IDs; source/destination/frame paths; trusted gesture kind, timing
and consumption; native window policy; allow/deny reason; original matching
filters and exceptions; automatic redirects, closes, navigation errors and
process termination. URL credentials, query values, fragments, opaque payloads
and sensitive path segments are scrubbed before persistence. Run-local keyed
fingerprints distinguish hidden URL differences without exposing their values.
No cookies, headers, form bodies, element text or general keyboard input is logged.
Timestamps are UTC Unix milliseconds; the helper renders readable UTC times.

`window.decision` and native redirect events explain Rise's decisions. The
document-start `window.open` observer also records calls which WebKit may reject
before its delegate runs. Page-world observations are explicitly unverified and
rate limited, and cannot grant a popup allowance. A returned null handle is not
proof of blocking: `noopener` can produce one too. Page code can replace the
observer, so use native events and the surrounding trace as the authoritative
evidence. Exceptions and implicit WebKit gating must be distinguished from a
Rise filter match before changing policy.

Disk failures retain the latest failed records in a bounded memory fallback;
exports report write failures, unreadable lines, queue drops, and private ring
evictions. The logger never blocks a navigation decision on disk IO.

Additional verification:

```sh
swiftc Apps/iOS/Rise/PopupDestinationRules.swift Apps/iOS/Rise/PopupLogRecord.swift Apps/iOS/Rise/PopupLogStore.swift scripts/ios-popups/test-logging.swift -o build/ios-popups/logging-tests
build/ios-popups/logging-tests
node scripts/ios-popups/observer.test.mjs
```

The native popup audit also verifies per-case decision traces and runs on-device
checks of privacy separation, bounded memory, persistence, export redaction,
backup exclusion, exact binary identity, and filter-exception explanations.
