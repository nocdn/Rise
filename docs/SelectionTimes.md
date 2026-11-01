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

The submenu offers Copy, Replace on Page, Add to Calendar, Add to Reminders and Show in Calendar.
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

## Replace on Page

Desktop and iOS use `TimePageConversion`, the same `SelectionTimes` parser and the shared
`PageTextEdits` writer used by currencies. It replaces explicit-zone times throughout the
main document, preserving surrounding words, inline markup and the original date when a
conversion crosses midnight. The replacement includes the local zone at that instant;
daylight saving follows the named zone and the actual date. Unchecking Replace on Page,
the mobile toast's Revert tap, or the desktop information panel's Revert restores originals.
The desktop's recent replacement also supports ⌘Z. Currency and time replacements restore
independently, including when both change the same text node.
Local-time replacement and restoration notices stay for 1.25 seconds; on desktop, hovering
keeps the notice open until the pointer leaves.

Changes added by a live page are processed in batches; native parsing runs off the UI thread.
Form controls, editable content, code blocks and hidden content are untouched. Original
text is held in the page's isolated world, never saved to history or sent to a service.
Navigation clears replacement state. A page's own intervening edits are preserved.

View → Replace Times with Local Time defaults to **⌘⌥T**, configurable in shortcut settings.
Key-down previews the conversion immediately. Releasing within 300 ms commits it and shows
the usual information panel. Holding longer restores the previous state on release and
never announces a toast/panel. Key repeats are consumed; releasing a modifier, switching
tabs or losing window focus also ends a preview. An already-converted page stays converted
through a hold, while a quick press toggles it back.

Explicit-zone ISO/RFC 3339 and PostgreSQL timestamps are read directly, including `Z`,
`+00`, `+0000`, `+00:00`, fractional seconds, and named zones such as `Europe/Paris`.
Email/HTTP dates such as `Fri, 23 Oct 2026 10:05:06 +0000` / `GMT` and iCalendar UTC
values such as `20261023T100506Z` are also supported. These become readable local dates
and retain seconds when written. A timezone-less timestamp is not assumed to be UTC;
ordinary numbers and identifiers are not guessed to be Unix epochs.

Formats: [PostgreSQL date/time types](https://www.postgresql.org/docs/current/datatype-datetime.html),
[RFC 5322 email dates](https://www.rfc-editor.org/rfc/rfc5322),
[RFC 5545 iCalendar dates](https://www.rfc-editor.org/rfc/rfc5545).

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
