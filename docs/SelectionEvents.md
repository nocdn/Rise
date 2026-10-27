# Selected events on desktop and iOS

Selecting an event on a page (an invitation's "Date: / Time: / Location:", a ticket's
"Sat 14 Nov · 19:00–23:00", or "Dinner with Sam on Friday at 7pm") leads the right-click
menu, or the iPhone's selection menu, with its time: "Tue 3 Nov, 13:30 – 20:30". It opens to:

- **Add to Calendar…**: on the Mac, Rise's own editor in a popover from where the menu opened.
  It has the title, location, all-day, start and end, calendar (the last one used first), alert,
  and notes. Return adds it and Escape cancels. On iOS it's Calendar's own editor
  (`EKEventEditViewController`). Rise requests Calendar access to support Undo afterwards.
- **Add to Reminders…**: the Mac's popover, or iOS's title prompt, due at the start.
- **Add to Google Calendar** (Mac): Google Calendar's editor in a new tab, filled in, in the
  account of the Calendar tab the person keeps. **Show in Calendar** (iOS) opens the day.

The source page's full URL (including Gmail's message fragment) is saved in the Calendar or
Reminders item's **URL field**. Calendar uses a meeting URL only when there is no source page.
Google Calendar's web editor carries the source link in its description.

After a native save, the Mac's address bar says **Added to Calendar / Reminders** for ten
seconds. The underlined app name opens that specific saved item, and **Undo ⌘Z** removes it.
**Redo ⇧⌘Z** restores the fields, source URL and alarms, with another ten seconds to undo.
Redo creates a fresh EventKit object and updates the link to its new local identifier.
Repeated keys cannot save or delete it twice; failed writes leave the action available.
Keyboard interception leaves native text editing and the address palette's Undo alone.
The iPhone shows the same actions in a toast; tapping its message opens the item. Hardware
keyboard shortcuts also work while the page has focus. Calendar access is requested on iOS
because undoing a system-editor save requires full access, unlike saving alone.
If only write access is allowed (or Calendar access is denied on iOS), the item can still be
added, but Rise does not offer Undo until full access is granted.

## Reading the event (`SelectionEvents` in RiseCore)

The system's date detector (`NSDataDetector`) reads days well. It handles any order and
language the locale knows, "tomorrow" and "next Friday", day ranges such as "November 3–5",
and which year a yearless date means. It's weaker at clocks, so Rise reads days from the
detector, **one line at a time** (across lines it misses "When\nTue 3 Nov\n13:30 - 20:30"),
and reads the rest itself:

- **Labels**: "Date:", "When", "Time:", "Starts:"/"Ends:", "Location:", "Where", "Venue",
  "Event:", "What:", "Time zone:" and their kin. A label alone on its line labels the lines
  below it: one or two for a time, and a place up to a blank line or the next label. A line
  whose "label" is itself a date ("Tuesday: 10am–2pm") isn't labelled.
- **Clocks and ranges**: "13:30", "1:30 PM", "7.30pm", "19h00", "1400 hrs", noon and midnight.
  Ranges join with -, –, —, to, until, through, or "between … and". Am and pm carry across a
  range: "1:30-8:30pm", "11-1pm", "10am-2", and "9-5" for office hours. An end before its start
  runs past midnight. A dot or "h" counts only beside a date or in a time's field, and two bare
  numbers ("3–5") don't count, so versions, prices and chapters aren't read as times. A clock
  with no day needs the detector to agree ("John 3:16" isn't one).
- **Which time**: the day's own line first, then a time's field, then the lines just below
  (or above) the day. Of one moment written in several zones ("10:00 AM PT / 6:00 PM GMT"),
  the person's own.
- **Zones**: abbreviations, offsets and city zones as `SelectionTimes` reads them, plus written
  names ("Pacific Time", "(Greenwich Mean Time - London)", "(GMT) London"). A zone keeping the
  person's own offset at the time counts as theirs, so it isn't shown or saved.
- **Years**: a weekday beside a yearless date chooses the year: "Wednesday, November 3" is
  2027's. A weekday that disagrees with a numeric date ("Mon-Fri 9-5") means it's no date.
- **Place**: the labelled one, else an address the detector finds, with the venue's name before
  it ("at The Ivy, 1-5 West St…"), else a video call's link (Zoom, Meet, Teams…). "TBA",
  "(map)" and "Get directions" are dropped.
- **Title**: a labelled one, then the name a sentence gives ("seeing you next week at **OpenAI
  DevDay Exchange: London**", "reservation at **Dishoom Shoreditch**"), then a heading above
  the details, then what's left of a one-line selection without its date and place ("**Dinner
  with Sam**"). Failing those, the page's title without its site, account, folder, "Re:" or
  "Invitation:" (Gmail's "Subject - me@x.com - Gmail" is the subject). Generic headings
  ("Event details") and greetings ("Hi Sam,") are never titles.
- A day without a time is all day. A time without a day is today's, or tomorrow's once it's
  over. Without a written end, the event lasts an hour.

A time selected in another zone keeps its converted item ("Tomorrow at 07:00 · in 15 hours" on
iOS, its heading on the Mac). When that time is the event's start, the item takes the event's
actions. On iOS, Rise's event menu takes the place of Data Detectors' date section
(`SelectionTimeNativeMenu`), since its actions fill in the place and title. A section without
every known action is left as it is.

## Access

The Mac asks for full Calendar or Reminders access the first time, so the editor can list
calendars. Under write-only Calendar access it adds to the default calendar. When access is
refused, the popover says so and links to Privacy & Security. Hardened-runtime builds need
`com.apple.security.personal-information.calendars` (`scripts/sign-app.py`), and
`scripts/Info.plist` carries the usage strings. Without them macOS refuses without asking.
Launched from a shell rather than LaunchServices, macOS attributes the request to the shell,
and Rise sees a refusal.

## Validation

- `scripts/test.sh --filter "SelectionEvents|SelectionEventEditor"`: formats, ranges, zones,
  years, titles, places, text that isn't an event, labels, Google's link, the editor's fields,
  and the menu item.
- iOS: `SelectionTimeNativeMenuTests` (the event replaces the system's date section; a converted
  time keeps its item). They build with `build-for-testing`; the simulator's test service
  currently fails as described in `SelectionTimes.md`.
- On the Mac: select an invitation's details in Gmail, right-click, and check the submenu, the
  popover and Google Calendar's editor.
