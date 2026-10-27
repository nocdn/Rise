# Selected times on desktop and iOS

`SelectionTimes` in RiseCore interprets explicit-zone selections. Each page's
`SelectionTimeMenu` tracks selection changes in an isolated WebKit world and adds
the local time as the first selection-menu item. Desktop's Chromium context menu
uses the same parser and labels.

A numeric zone selected without a clock, such as `UTC+14:00`, shows the current
time there and how far ahead of or behind the local clock it is. Tomorrow and
yesterday compare the two places' calendar dates. The difference uses the local
offset at that instant, including daylight saving. `UTC`/`GMT`, positive/negative
offsets, Unicode minus signs, colon or compact minutes, and fractional hours are
supported. Selecting prose containing several offsets shows up to three distinct
zones in text order. An offset belonging to an actual clock time is consumed by
that conversion, and malformed or out-of-range offsets are ignored.

On iOS a zone-only result offers Copy, capturing the date, time, and explicit zone
so the pasted value remains meaningful later. It does not create an appointment
or acquire the system's Calendar/Reminders actions.

The submenu offers Copy, Add to Calendar, Add to Reminders and Show in Calendar.
Calendar uses EventKitUI without requesting calendar read access. The direct
submenu's reminder action confirms a title and requests EventKit reminder access
only after Add. Its due date and alarm use the selected absolute instant. The
Calendar app link uses the same absolute instant with `calshow:`; failure to open
the app produces an alert.

UIKit appends its Data Detectors date section **after** `buildMenu(with:)` and
`UITextInput.editMenu(for:suggestedActions:)`. Removing `.lookup` in the builder
does not solve this and also removes Look Up and Translate. The finished hierarchy
is available through the public `UIContextMenuInteraction.updateVisibleMenu(_:)`
API on the page's interactions.

`SelectionTimeNativeMenu` waits for that hierarchy during the edit-menu lifecycle,
moves the existing date actions into Rise's submenu and removes their original
section, including the disabled date heading. Native action objects retain their
icons, localized titles and handlers. Match action identifier prefixes, never
English titles or private selectors. No system classes or delegates are patched.
If a future OS changes those identifiers or supplies an incomplete section, leave
its actions intact rather than silently losing functionality.

When the selection is an event (`SelectionEvents`, see [Selected events](SelectionEvents.md)), Rise's
own actions fill in its title and place, so they're kept and the system's date section is removed
instead, including a plain date's without a conversion heading.

The compact time item can open its submenu directly. UIKit exposes only that
submenu in this path, so it has its own complete set of working actions. Multiple
converted times also retain their individual captured dates instead of borrowing
one native action's opaque date payload. Stop the display-frame observer once the
menu is updated, the direct submenu opens, or the edit menu dismisses.

Validation:

- `scripts/test.sh --filter SelectionTimesTests`
- `RiseiOSTests/SelectionTimeMenuTests` and `SelectionTimeNativeMenuTests`
- Launch a simulator Debug build with `-RiseSelectionTimeMenuAudit`. This uses an
  isolated page and writes checks to `Library/Caches/SelectionTimeMenuAudit`.
  Long-press the selected time, test the direct item, then reopen and test the
  expand chevron. The latter writes `relocated-menu.json` with the real native
  hierarchy. Check Calendar and Reminders without saving test items on a phone.
  Add `-RiseSelectionTimeMenuAuditText 'UTC+14:00'` to exercise a standalone offset;
  `selection-menu.json` records its actual menu title and actions.

The local Xcode-beta simulator test service currently fails with
`DTServiceHubClient failed to bless service hub`. The test target can still compile
with `build-for-testing`; the in-app audit exercises menu relocation and retained
handlers without that service.

References: [Menu updates](https://developer.apple.com/documentation/uikit/uicontextmenuinteraction/updatevisiblemenu(_:)),
[WebKit edit-menu notifications](https://developer.apple.com/documentation/webkit/wkuidelegate),
[EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store).
