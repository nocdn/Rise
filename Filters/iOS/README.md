# iPhone ad blocking

The iPhone uses WebKit content rules converted from AdGuard's full Safari Base
list (including EasyList), Mobile Ads, and Quick Fixes. The Base/Mobile lists also
contain maintained anti-adblock fixes. It does not install the desktop's separate
EasyPrivacy or HaGeZi lists; the tracker switch remains a visual control. Cookie
banner acceptance has a separate engine and functional per-site switch; see
[Cookie consent](../../docs/CookieConsent.md).

`Sources/` contains the original GPL-3.0 snapshots. Converted rules, bundled
Scriptlets/Extended CSS, licenses and a SHA-256 manifest are in
`Apps/iOS/Rise/Blocking/`. `scripts/ios-adblock/package-lock.json` pins all build
dependencies. The app validates every asset and caches WebKit compilation by hash.

Refresh on an Apple Silicon Mac with Node/npm installed:

```sh
python3 scripts/update-ios-adblock.py
```

Use `--reuse-sources` to reproduce the committed snapshot. Conversion uses pinned
SafariConverterLib 4.3.0 and Safari 17 syntax. Native exceptions are repeated in
each shard, preserving order. Advanced rules are parsed with AGTree, grouped by
domain, and injected at document start (scriptlets) or document end (cosmetics).
Scriptlet dependencies are bundled into self-contained functions; no runtime eval
or downloaded executable code is needed. Domain wildcards use the Public Suffix
List through tldts. Cosmetic, scriptlet and document exceptions remain effective.

YouTube, its subdomains, youtube-nocookie.com, youtu.be and youtubekids.com are
hard-excluded. Each native shard also exempts YouTube top pages, frames and video
resources, and scripts return immediately for YouTube contexts. The navigation
delegate removes all ad rules/scripts before a YouTube page or redirect commits.
The ad switch is disabled and off there. This is a product policy, not a guarantee
about account enforcement by YouTube.

On other hosts, ad blocking defaults on. Turning it off is saved per host (www
and non-www share a setting), removes this blocker's rules/scripts, then reloads
from origin. Turning it on installs the catalog before reloading. A native spinner
remains beside the switch until navigation finishes or fails. Existing Rise
viewport/paint scripts are preserved. Known anti-adblock fixes reduce warnings;
unknown detectors and server-inserted ads can still require new filters.
