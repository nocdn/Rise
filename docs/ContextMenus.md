# Website and browser context menus

Normal right-click keeps the website's context menu. **Shift–right-click** bypasses
the website menu and opens Rise's native menu for the actual clicked element, including
Download Video, Copy Link and the usual text-editing actions where applicable.

`NativeContextMenuOverride` is installed at document start in an isolated script world
on every Chromium page and frame, including cross-origin frames and popups. It stops
the website's trusted secondary-pointer/context-menu handlers for that gesture without
canceling Chromium's default action. Mouse-up remains covered if Shift is released
mid-click. Primary clicks, ordinary right-clicks and synthetic page events are unchanged.
The existing native context-menu/download bridge retains the clicked document's context.

This follows [Firefox's Shift–right-click convention](https://developer.mozilla.org/en-US/docs/Web/API/Element/contextmenu_event).

Validation: `python3 scripts/test-chromium-live.py Tests/Live/ChromiumContextMenuOverrideChecks.swift`.
