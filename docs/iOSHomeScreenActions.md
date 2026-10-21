# iOS Home Screen actions

Holding Rise's Home Screen icon offers Downloads, History and New Private Tab. The static
`UIApplicationShortcutItems` in `Info.plist` are available before the first launch. `SceneDelegate`
handles both `connectionOptions.shortcutItem` and the warm scene callback. A shortcut suppresses
the ordinary first-launch search panel, and `BrowserQuickActions` waits for the browser's existing
panel, Peek and tab transitions before opening its destination.

History expands the bottom bar to 80% of the screen, with the shared panel heading and X.
Its newest-first local visits reuse address-suggestion rows, including their font, favicons,
spacing and press feedback, without URL subtitles or a search field. The scrollable list reuses
visible cells instead of building every visit. A selected entry opens in a new regular tab.
The History button in the tab switcher's More menu expands directly into this panel, without
closing More or waiting for a modal sheet. X or a swipe from the screen's left edge returns to
the previous surface, preserving the tab switcher; a Home Screen launch returns to the small bar.
The edge swipe starts closing as soon as it is recognized, without waiting for finger release.
Downloads, Site settings and App settings use that same edge recognizer and return handler.
Like their X buttons, they return one level: Downloads and Site settings to More, App settings
to Site settings. The gesture is accepted only from the leftmost 16 points of these panels.
Vertical panel drags rubber-band in both directions and spring back to the same height, even
after a strong downward flick. Tapping the page behind History does not dismiss it.

Swiping an individual visit horizontally removes it from local history and suggestion ranking.
Before detachment, the row follows a light resistance curve, `d*0.82/(1+abs(d)/320)`, and fades
with its displayed distance. Its immediate neighbours follow at 12% of the finger's distance,
and the next pair at 5%. At 23% of the list width (bounded to 64–96 points), a soft haptic
accompanies those neighbours springing home and the selected row catching up to the finger.
As with desktop tab detachment, the catch-up spring is an offset from the live finger target:
continued finger movement stays immediate, and crossing the threshold has no one-frame jump.
Reversing four points back inside the threshold reconnects the neighbours and springs the row
back onto its resistance curve; releasing there returns it without deleting. A fast
outward flick can also commit. Release preserves position and velocity, flies the row offscreen,
then closes the gap on a 0.32-second spring. Motion lives inside each cell's own container,
so the list's layout cannot put the row back in place while its opacity changes.
Only visible cells move, and a scoped
display link requests the device's maximum rate up to 120 Hz. The screen's left-edge gesture
takes priority over row deletion. VoiceOver offers a Delete from history action on each visit.

The dots beside History's heading reuse Downloads' menu button. Multi Select leaves a
check circle in each favicon's original column while the favicon and title slide 32 points
right, reducing the title's available width. The circles use Downloads' symbol transition
and blue selected fill; Done fades them out while the content slides home. Both panels use
the same `PanelSelectionList` for UIKit's native two-finger range selection, reversal and
edge autoscrolling. Starting a range enters selection automatically. Checks are keyed by
visit URL, retained through reuse and deferred refreshes, and exposed to VoiceOver. The menu
offers Select All, Done and Delete Selected. Bulk deletion saves once and animates surviving
rows into the gaps. Opening History starts in its normal browsing mode; row-swipe deletion
is suspended in selection mode, while the panel's X and edge-back still work normally.

New Private Tab opens the ordinary New Page panel already deep purple, on warm and cold
launches. There is no separate private screen. The eye button to the left of X toggles the
pending page between regular and private browsing without changing its draft or completion.
Enabling it reveals purple from bottom to top over 0.28 seconds, then stretches the top edge
6 points and settles with a small rubber band; the bottom edge stays anchored. The shortcut
starts purple without playing that transition. Purple is identical in light and dark modes.

Private tabs appear alongside regular tabs in the main switcher. Their tabs and Peeks share
one nonpersistent `WKWebsiteDataStore`, separate from regular cookies and local storage.
Closing the last private tab discards that store and its in-memory protection preferences.
Private tabs never enter the closed-tab undo stack, including shake-to-restore; even the
last private tab can be swiped away, returning to an empty regular New Page panel.
They do not restore after termination, enter history, learn site searches, sync through
iCloud, save previews/favicons, or write Summarise performance logs. The shared history and
learned sites remain readable for suggestions. Remote suggestions use a separate ephemeral,
cookie-free client whose cache is discarded when leaving the private search; speculative
favicon requests and cache writes are suppressed. Private page, panel and deck content are
covered before the app-switcher snapshot. Explicit downloads still save files normally.

`PrivateTabsAudit` verifies real WebKit cookie/local-storage separation, background callbacks,
disk/session/sync exclusions, learned suggestions, rapid mode changes, the gradient and anchored
pulse, mixed-card swipes, no private undo, fresh cookies after the last close, and warm/cold
shortcut routing. It saves light/dark and intermediate transition screenshots.

`HomeScreenActionsAudit` exercises routing and isolation using temporary fixtures. Run it after
building with `scripts/restart.sh --ios --simulator <UDID>`:

```
python3 build/run-ios-motion-audit.py HomeScreenActionsAudit build/ios-home-screen-audit
```

`HistoryPanelAudit` additionally covers a full 2,000-entry history, immediate opening, row
composition, scrolling and dismissal, rapid swaps, light/dark appearance, and selecting a visit.
`HistoryRowSwipeAudit` covers following, threshold reversals, cancellation, both directions,
flicks, gap closure, persistence, accessible deletion and the last visit's empty state. It checks
actual icon positions after forced list layouts, rather than checking transforms alone.
It also checks resistance, detachment and recapture continuity, moving the finger during the
catch-up spring, and releasing before that spring has finished.
`HistorySelectionAudit` exercises native range callbacks, selection reversal, URL identity
through refreshes, offscreen reuse, rendered circle/row transitions, rapid toggles, bulk
deletion and persistence, and selection reset when reopening. Downloads' selection audit is
also rerun because both panels share the same controls and range-selection implementation.
