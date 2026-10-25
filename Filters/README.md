# Built-in blocking filters

Rise ships EasyList from the EasyList authors (https://easylist.to/) for ad blocking. It is licensed under GPL-3.0; see LICENSES/GPL-3.0.txt. EasyList also offers CC-BY-SA 3.0 as an alternative: https://easylist.to/pages/licence.html. The source snapshot is in Sources/.

On the Mac, Engine/adblock compiles these lists, with Rise's own general ad-slot selectors and ad-script and banner file name rules (Engine/adblock/rise.txt), into the engine when the app is built; it does not modify test results or contain benchmark-specific host allow/block rules. Each list keeps its own exceptions. The iPhone app's WebKit rules are in iOS/.

Neither app includes a separate tracker-blocking filter list or control. The Mac checks requests against EasyList and Rise's ad rules; the iPhone uses the ad lists described in iOS/.

Scoped site fixes in `Engine/adblock/compatibility.txt` are included in every engine. Sentry's dashboard loads an `ads.js` blocker probe from `s1.sentry-cdn.com`; that static asset host is exempted from ad rules only on Sentry's own sites.

Refresh the snapshots with `python3 scripts/update-adblock.py`. The app uses bundled snapshots rather than downloading executable filter code. Refresh them periodically when making releases.
