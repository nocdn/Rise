# iOS Home Screen actions

Holding Rise's Home Screen icon offers Downloads, History and New Private Tab. The static
`UIApplicationShortcutItems` in `Info.plist` are available before the first launch. `SceneDelegate`
handles both `connectionOptions.shortcutItem` and the warm scene callback. A shortcut suppresses
the ordinary first-launch search panel, and `BrowserQuickActions` waits for the browser's existing
panel, Peek and tab transitions before opening its destination.

History displays the same local visits used by address suggestions, newest first, with title/URL
search. A selected entry opens in a new regular tab. The History button in the tab switcher's More
menu opens this list too, preserving the tab switcher when History is dismissed.

New Private Tab opens a separate full-screen private session with a visible label and a close
button. Its tabs and Peeks share one nonpersistent `WKWebsiteDataStore`, separate from regular
cookies and storage. Repeating the shortcut adds a blank private tab; closing private browsing
ends that session. Private tabs do not restore after termination, enter history, learn site
searches, sync through iCloud, save previews/favicons, or write Summarise performance logs.
Typing does not send remote suggestions or speculative favicon requests. Protection preferences
are in memory for that session. Private page content is covered before the app-switcher snapshot.
Files explicitly downloaded in private browsing are still saved in the normal Downloads folder.

`HomeScreenActionsAudit` exercises routing and isolation using temporary fixtures. Run it after
building with `scripts/restart.sh --ios --simulator <UDID>`:

```
python3 build/run-ios-motion-audit.py HomeScreenActionsAudit build/ios-home-screen-audit
```
