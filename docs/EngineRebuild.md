# Rebuilding the engine after the 29 October 2026 changes

On 29 October 2026 the engine changed in ways that need a full rebuild on any Mac that last
built it before then. A small rebuild won't do it. Read this before building.

## What changed

- **The engine is now an official build** (`is_official_build=true`, with Chrome's PGO profile and
  ThinLTO), as Chrome's and Helium's are. Speedometer went from about 35 to about 55. The settings
  are in `Engine/chromium.json`, and the output folder moved from `out/Release` to `out/Official`
  (`scripts/engine/common.sh`). Nothing from `out/Release` is reused; delete it once the new build
  works, to free its space.
- **Ad blocking is uBlock Origin**, loaded as one of Chrome's own extensions (patch `0029`).
  `scripts/build.sh` downloads it once (`Engine/ublock.json` pins the version and checksum) into
  `../rise-chromium/ublock/`. Rise's own Rust blocker (`Engine/adblock/`) is gone, so `cargo` is no
  longer needed.
- **Background tabs rest** (patch `0030`). Pages start hidden until they're in the window, and
  Chrome's tab freezing is on. Rise also lets tabs sleep after 30 minutes (`TabSleep.swift`).

## Rebuilding, in order

1. **Pull, then rerun `./scripts/engine/checkout.sh`.** The official build needs Chrome's PGO
   profile, which only downloads with `checkout_pgo_profiles`, now set by `checkout.sh`. Without
   it the build fails. At the pinned Chromium version this mostly fetches the profile.
2. **Preview first:** `./scripts/engine/build.sh -n`. It applies the patches, then shows what it
   would build without building. Expect a full build of about 96,000 steps, which takes many hours.
   Tell the user the count before starting. On a Mac that already has `out/Official`, a few files
   and the link are normal; tens of thousands of steps mean something regenerated, so stop and
   find out why first.
3. **Build with at most 6 jobs:** `RISE_CHROMIUM_JOBS=6 ./scripts/engine/build.sh`. The default is
   4. More than 6 can run the Mac out of memory: 14 jobs caused a kernel panic on a 24 GB Mac.
   Before the final link, which uses a lot of memory, check `memory_pressure` and
   `sysctl vm.swapusage`.
4. **Then rebuild Rise:** `./scripts/restart.sh`.

## While it builds

- Only one build at a time per out folder. Builds started from different shells or sessions can
  produce different commands and turn into a full rebuild.
- Stop a build gracefully (Ctrl-C, or `kill -INT` on `siso`). Never use `kill -9` or a bare
  `pkill` on it.

## The shortcut

To skip building on a Mac, copy `../rise-chromium/fork/src/out/Official/Chromium.app` from a Mac
that has built it to the same path. `scripts/build.sh` only needs that, and works straight away.
Copy it again whenever the engine changes.
