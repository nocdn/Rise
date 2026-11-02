# Desktop keyboard shortcut editor

Settings → Keyboard shortcuts ports Helium's shortcut chips, recording dialog,
ranked search and reset controls. The upstream revision, original patch and GPL-3.0
license are retained in [`Engine/third_party/helium`](../Engine/third_party/helium/README.md).

`0023-rise-keyboard-shortcuts.patch` installs the settings route; the subsequent
`0028-helium-shortcut-editor.patch` replaces its editor. The port uses Chromium's
current Lit controls and Rise's existing `riseSettings` bridge instead of Helium's
Mojo command service. Changes to these resources require an engine rebuild, followed
by `./scripts/restart.sh` to package the framework and relaunch Rise.

The AppKit registry remains authoritative for command names, defaults, persistence,
menu shortcuts and dispatch. Saved user bindings retain their existing format.
Ordinary menu commands go through `NSMenu.performKeyEquivalent(with:)`, including
AppKit's validation and native menu-bar feedback. Extra user bindings receive
hidden native menu equivalents, refreshed without duplicates. Shifted punctuation
uses AppKit's character representation; saved bindings keep their existing format.
Recording, held shortcuts, browser undo and tab-switch gestures retain their early
handlers so they cannot be intercepted by a page or executed twice.

- Search ranks exact, prefix and substring matches across names, menu groups,
  displayed key symbols and serialized bindings; results are alphabetical within ranks.
- Add opens a modal recorder. Capturing a key never changes bindings or executes
  its action; Save or Enter commits it, and Cancel or Escape leaves bindings alone.
- A conflicting key shows which action will lose it. Explicit Save reassigns that
  key while preserving every other binding. Reset restores an action's defaults and
  reclaims their keys, matching Helium's behavior; reset-all asks for confirmation.
- Recorders cancel on reload, tab changes and window deactivation. Native capture
  intercepts destructive shortcuts before AppKit menus and Chromium see them.
- Rise requires Command, Control or Option, or a function key, so a saved shortcut
  cannot consume ordinary typing on web pages. OS-reserved keys remain managed by macOS.

Verification: `scripts/test.sh --filter KeyboardShortcutsTests`,
`python3 -m unittest discover -s scripts/engine/tests`, and
`python3 scripts/test-chromium-live.py Tests/Live/ChromiumShortcutSettingsChecks.swift`.
The live check exercises real key events, dialogs, persistence, conflicts, resets,
search, reload/tab cancellation and light/dark captures in an isolated profile.
