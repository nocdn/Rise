# Agent notes for Rise

- After changing the app, rebuild and relaunch it with `./scripts/restart.sh` so the user sees the change. Don't hand-roll build, quit, and open commands.
- Builds are signed with the local Apple Development identity (`scripts/sign-app.py`), which keeps macOS privacy grants (such as Downloads folder access) across rebuilds. Don't switch local builds back to ad-hoc signing (`RISE_SIGNING_IDENTITY=-`); every rebuild would then ask for folder access again.
- Unit tests: `scripts/test.sh` (`swift test` with the engine's framework found; it takes `swift test`'s arguments, such as `--filter`). Checks on real pages run in a real Rise window: `python3 scripts/test-chromium-live.py <check>` (see its docstring).
- Before changing the iOS app's Summarise or tab switcher motion, read `docs/Motion.md`: the measured values, the spring physics, what was tried and removed, and the user's preferences for motion.
