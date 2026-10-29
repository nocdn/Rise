# Agent notes for Rise

- After changing the app, rebuild and relaunch it with `./scripts/restart.sh` so the user sees the change. Don't hand-roll build, quit, and open commands.
- Builds are signed with the local Apple Development identity, or a Developer ID one where there's none (`scripts/sign-app.py`), which keeps macOS privacy grants (such as Downloads folder access) and the Keychain's "Always Allow" for Chromium Safe Storage across rebuilds. Don't switch local builds back to ad-hoc signing (`RISE_SIGNING_IDENTITY=-`); every rebuild would then ask for folder access again.
- Unit tests: `scripts/test.sh` (`swift test` with the engine's framework found; it takes `swift test`'s arguments, such as `--filter`). Checks on real pages run in a real Rise window: `python3 scripts/test-chromium-live.py <check>` (see its docstring).
- iOS popup reports: fetch local diagnostics with `python3 scripts/popup-log.py --device <name-or-UDID> --site <hostname> --last 200 --output build/popup-diagnostics`, then read them with `--read <folder>`. Regular traces survive relaunch; private traces remain in memory for that private session. Native decisions and matched filters are authoritative; page-world observations are unverified, and a null window handle alone does not prove blocking. See `docs/iOSPopups.md`.
- Before changing the iOS app's Summarise or tab switcher motion, read `docs/Motion.md`: the measured values, the spring physics, what was tried and removed, and the user's preferences for motion.
- Engine builds (the Chromium fork in `../rise-chromium`): after pulling changes to `Engine/` or `scripts/engine/`, read `docs/EngineRebuild.md` before building. In short:
  - If `Engine/chromium.json` or `scripts/engine/checkout.sh` changed, rerun `./scripts/engine/checkout.sh` first.
  - Always preview with `./scripts/engine/build.sh -n` and tell the user the step count before building. A full build is about 96,000 steps and takes many hours; an edit should only rebuild a few files and the link.
  - Build with at most 6 jobs (`RISE_CHROMIUM_JOBS`, 4 by default); 14 jobs caused a kernel panic. Check memory and swap before the link.
  - Only one build per out folder at a time. Stop builds gracefully (Ctrl-C or `kill -INT`), never `kill -9`.
