# GitHub repository actions on iOS

A long press keeps WebKit's native link menu and adds one stable action row.
A disabled “Checking status...” row appears while a fresh read-only lookup runs.
The same static outline star stays visible during checking, Star and Unstar;
checking only disables the row. On
completion the action changes immediately to “Star repository” or
“Unstar repository”, with the same outline star and no app content transition.
Signed-out or missing repositories are disabled; failed lookups offer a retry.

Every lookup and mutation uses the held page's exact WKWebsiteDataStore. Private
and ordinary browsing never borrow each other's sessions. No cookies or CSRF tokens
are exported: GitHub's own form or hydrated button submits the requested action.
Closing a menu cancels its read-only helper without cancelling an explicit action.

Mutations request a target state, not a toggle. They re-read the server before
pressing once, then verify the result through a second fresh page while the first
stays alive. An optimistic React label cannot substitute for server confirmation.
An already satisfied target returns without a POST. Identical adjacent requests
share work, while Star → Unstar → Star remains three ordered intentions.

The blue toast uses the existing native spinner, Torph morph and interaction
physics. Unstar changes “Unstarring repository...” to “Unstarred repository” with
the same star and one success haptic. Failures never claim success.

## Verification

- `-RiseGitHubStarAudit`: original star, authentication, native menu and failure
  regressions, the disabled checking row's constant star, and fast menu results.
- `-RiseGitHubStarAudit -RiseGitHubUnstarAudit`: fresh lookup, React/forms,
  hydration, delayed commits, duplicate unstars, opposing requests, stale menu
  states, cancelled lookups, isolated sessions, rejected mutations and toast states.
- `-RiseGitHubStarAudit -RiseGitHubMenuPreview`: isolated native menu round trip.
  A deliberate fixture delay keeps the disabled checking row visible for inspection.
- `-RiseGitHubStarDeviceAudit -RiseGitHubUnstarDeviceAudit`: a signed-in live
  round trip on nocdn/Rise, restoring the repository's original state before
  checking its results. It never writes browser tabs or history.
