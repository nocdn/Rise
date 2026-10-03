# Built-in blocking filters

Rise ships EasyList and EasyPrivacy from the EasyList authors (https://easylist.to/), and HaGeZi Multi PRO mini (https://github.com/hagezi/dns-blocklists). These source lists and their converted JSON data are licensed under GPL-3.0; see LICENSES/GPL-3.0.txt. EasyList also offers CC-BY-SA 3.0 as an alternative: https://easylist.to/pages/licence.html. The original source snapshots are in Sources/.

The JSON snapshots are in Sources/Rise/Resources/Blocking/. AdGuard SafariConverterLib 4.3.0 (https://github.com/AdguardTeam/SafariConverterLib, GPL-3.0) converts EasyList and EasyPrivacy at build time using Safari 17-compatible syntax. The converter is a development tool and is not linked into Rise or shipped in the app. HaGeZi domain rules are emitted directly in WebKit format, excluding top-level documents so visiting a site is still possible. Rise adds general ad-slot selectors and ad-script/banner filename rules; it does not modify test results or contain benchmark-specific host allow/block rules.

Each source retains its own exceptions. Large lists are split below WebKit's rule-count limits; exception rules are copied to each part in their original order. WebKit compiles these lists once and caches them by SHA-256. Pages wait for installation before initial navigation, including restored pages and popups.

Refresh the bundled snapshots with `python3 scripts/update-adblock.py` on an Apple Silicon Mac. The app uses bundled snapshots rather than downloading executable filter code. Refresh the snapshots periodically when making releases.
