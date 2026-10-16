# Built-in blocking filters

Rise ships EasyList and EasyPrivacy from the EasyList authors (https://easylist.to/), and HaGeZi Multi PRO mini (https://github.com/hagezi/dns-blocklists). These source lists are licensed under GPL-3.0; see LICENSES/GPL-3.0.txt. EasyList also offers CC-BY-SA 3.0 as an alternative: https://easylist.to/pages/licence.html. The source snapshots are in Sources/.

On the Mac, Engine/adblock compiles these lists, with Rise's own general ad-slot selectors and ad-script and banner file name rules (Engine/adblock/rise.txt), into the engine when the app is built; it does not modify test results or contain benchmark-specific host allow/block rules. Each list keeps its own exceptions. The iPhone app's WebKit rules are in iOS/.

Refresh the snapshots with `python3 scripts/update-adblock.py`. The app uses bundled snapshots rather than downloading executable filter code. Refresh them periodically when making releases.
