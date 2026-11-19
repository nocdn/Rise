# Rise

Rise is a web browser for the Mac. It has a native AppKit interface in the style of Arc and Dia: tabs in a sidebar, Peek, split view and smooth motion. Under the interface, Rise runs its own build of Chromium, so websites and Chrome extensions work as they do in Chrome.

The repository also has an iPhone app. It is in [`Apps/iOS`](Apps/iOS/README.md).

## Download

Get the latest version from [Releases](https://github.com/nocdn/Rise/releases).

1. Download Rise from the newest release.
2. Move `Rise.app` to your Applications folder.
3. Open Rise.

Rise needs macOS 14 or later on a Mac with Apple silicon.

## Build from source

You only need this if you want to change Rise. To use Rise, [download it](#download).

### What you need

- A Mac with Apple silicon.
- Xcode with the macOS 26.5 SDK, and its Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`.
- About 100 GB of free disk space for the Chromium engine.

### Steps

1. Get the pinned Chromium source. It goes into `../rise-chromium/fork` (about 30 GB):

   ```sh
   ./scripts/engine/checkout.sh
   ```

2. Apply Rise's patches and build the engine. The first build takes a long time:

   ```sh
   ./scripts/engine/build.sh
   ```

   If another Mac has already built the engine, copy it from there instead:

   ```sh
   ./scripts/engine/fetch.sh <ssh-host> [ssh-port]
   ```

3. Build Rise and open it:

   ```sh
   ./scripts/build.sh
   open build/Rise.app
   ```

   After a change, `./scripts/restart.sh` rebuilds Rise and opens it again.

4. Run the tests:

   ```sh
   ./scripts/test.sh                      # unit tests
   python3 scripts/test-chromium-live.py  # checks on real pages in a Rise window
   ```

For more about the engine, see [Engine/README.md](Engine/README.md). For passkeys and signing, see [docs/Passkeys.md](docs/Passkeys.md).

## Features

### Tabs and sidebar

- **Sidebar tabs**: your tabs are in a list at the left. Drag a tab to move it. Double-click a title to rename it. Middle-click a tab to close it.
- ⭐ **Pinned tabs**: drag a tab up into the tiles at the top to pin it. Drag a tile down to unpin it. Tiles take the color of the site's icon.
- ⭐ **Wide sidebar**: hold ⌃⌘ to make the sidebar wider, so you can see long titles.
- **Hidden sidebar**: press ⌘B to hide the sidebar. Move the pointer to the left edge of the window and the sidebar slides out.
- **Tab switcher**: press ⌃Tab to go to your recent tabs, with page pictures. Release ⌃ to switch. Set how many tabs it shows in Settings → Tabs.
- **Choose a tab by scrolling**: hold ⌥ and scroll on the trackpad. A highlight moves through your tabs. Release ⌥ to switch, or press Escape to cancel. Pinned tabs are not included. Change the key in Settings → Tabs.
- ⭐ **Search tabs**: press ⇧⌘A to search your open tabs by title, address and page content. Type a description and the AI finds the tabs that match it.
- **Smart Rename**: put the pointer on a tab and press ⌃R. The AI gives the tab a short name.
- **Sort tabs**: press ⇧⌘K to sort your tabs by website. Press ⌘Z to undo.
- **Open tabs are reused**: a link to a page that is already open goes to that tab. Links from other apps do this too. ⌘-click still opens a new tab. Turn this off in Settings → Tabs.
- **Tabs rest**: tabs that you don't use freeze, and after 30 minutes they sleep to save memory. Each tab keeps its place and history, and loads again when you open it.
- **Archived tabs**: tabs that you don't use for 48 hours move to History → Archived Tabs. Change the time in Settings → Tabs.
- **Reopen tabs**: press ⇧⌘T to reopen the last tab that you closed. Right-click the downloads button to see other tabs that you closed recently.
- **Pinned tab safety**: ⌘W on a pinned tab asks you to press ⌘W again.
- ⭐ **Notification counts**: counts such as "(3)" are removed from tab titles. Turn this off in Settings → Tabs.
- **Sessions**: Rise keeps your tabs, their history, Peeks and splits when you quit, and opens them again at the next launch.

### Peek and split view

- ⭐ **Peek**: Shift-click a link to open it in a card over the page. Press Escape or click outside to close it. Use the buttons on the card to make it a tab or a split.
- **Peek the current page**: press ⇧⌘P. Press ⌥⌘P to move a Peek into a new tab.
- **Split view**: drag a tab from the sidebar onto the page, then drop it on the left or right target. Or press ⇧⌘D to show the current page twice. Drag the handle between the pages to resize them. Right-click a split in the sidebar to separate it.

### Address bar and search

- **Address bar**: press ⌘T for a new tab or ⌘L to edit the address. Suggestions come from your open tabs, your history and Google.
- ⭐ **Search a site**: type a site's name and press Tab to search on that site. Rise learns this from the searches that you do on sites.
- **Ask an AI**: type a question to ask ChatGPT, Claude or Gemini on their own sites.
- **Commands**: type `/` to see browser commands, such as `/zoom` or `/settings`.
- ⭐ **Copy the link**: press ⇧⌘C or click the link button in the page bar.

### Reading and pages

- ⭐ **Find and Ask**: press ⌘F to find text. Type a question instead, and the AI answers it about the page.
- **Annotations**: select text and press ⌃⌘A to ask about it. The answer stays on the page as a numbered note, also after a reload.
- ⭐ **Link summaries**: hold ⌥ over a link to see a short summary of the page that it opens.
- **AI chat**: press ⌘E to open a chat beside the page. It can read and use your tabs, and you can mention a tab by its name. Choose the AI provider and model in Settings → AI.
- ⭐ **Local times**: select a time in another time zone, such as "3pm PST", and right-click it. The menu shows that time in your own time zone. Press ⌥⌘T to change all the times on a page to your time zone, and again to change them back.
- ⭐ **Currency conversion**: select a price in another currency and right-click it. The menu shows the price in your own currency, and can change all the prices on the page to your currency.
- ⭐ **Events**: select an event, such as "Dinner on Friday at 7pm at Dishoom", and right-click it. You can add it to Calendar, Reminders or Google Calendar, with its title, times and place. It also understands locations and complex layouts, such as invitations where the date, time and place are in different parts of the page.
- **History menu**: right-click (or ⌃-click) the Back or Forward button to go straight to an earlier page.
- **Page bar color**: the bar above the page takes the color of the top of the page.
- **Zoom**: press ⌘+, ⌘− or ⌘0. The page bar shows the zoom level and a reset button.
- **Captures and printing**: the File menu can save a screenshot, or the full page as an image or PDF. Press ⌘P to print.
- **Full screen in the window**: press ⇧⌘F so that pages which go full screen, such as videos, stay inside Rise's window. Press it again to use the normal full screen.
- **Rise's own right-click menu**: Shift–right-click to get Rise's menu on sites that have their own menu.

### Hover cards

Hover over these tabs in the sidebar to see a card:

- ⭐ **Gmail and Proton Mail**: your newest emails. Click one to open it. Choose the Gmail category in Settings → Tabs.
- ⭐ **Google Chat**: your direct messages, newest first. Unread ones have a blue dot.
- ⭐ **Google Calendar**: your day as a timeline. Swipe sideways to go to other days. Right-click empty space and choose Refresh to get the newest events. Pinch to make the card taller or shorter while it's open. Calendar tabs also show a countdown, such as "in 17m", before an event starts.
- ⭐ **GitHub pull requests and GitLab merge requests**: the title, status, checks and changed files. These cards also open from links to pull requests in pages.

### Media

- ⭐ **Floating video**: when you leave Rise while a video plays with sound, the video floats in its own small window. Drag or flick it into a corner, pinch to resize it, or flick it past the side of the screen to tuck it away.
- ⭐ **Now Playing**: when media plays in a tab that you left, a card at the bottom of the sidebar has its controls.
- **Tab audio**: a tab that plays sound has a button to pause or mute it.
- ⭐ **Meet's floating window**: move it with two fingers on its title bar, and flick it into a corner.
- **YouTube**: videos that you open wait for you to press play. Turn autoplay on in Settings → Tabs or the Page menu.

### Privacy, permissions and notifications

- ⭐ **Ad blocking**: Rise has uBlock Origin built in. Click the shield in the site controls to turn it off for a site.
- **Cookie banners**: Rise closes cookie banners for you. Turn this off in the Page menu.
- **Site permissions**: Rise asks before a site can use your camera, microphone or location. Your answer stays for that site. Press ⌥⌘Return to allow or ⌥⌘⌫ to deny.
- **Notifications**: allowed sites, such as Google Chat, show their notifications in Notification Centre.
- ⭐ **Passkeys**: use Touch ID, security keys such as YubiKeys, password manager extensions, or your phone.
- ⭐ **Link preloading**: turn on Page → Preload Links on Hover to load links before you click them. It is off by default.

### Downloads

- **Downloads**: files go to your Downloads folder. A small animation shows each download go into the downloads button.
- **Downloads list**: press ⌥⌘L or click the downloads button. Click a file to open it, or hover over it to preview it in Quick Look or remove it.

### Extensions

- **Chrome extensions**: install them from the Chrome Web Store with the Add to Rise button.
- **Pinned extensions**: pin an extension to put its button in the page bar. Press ⌥⇧1 to ⌥⇧9 to open the pinned extensions in order.

### For developers

- **Developer mode**: press ⌃D. The tab shows its address, and the page bar gets an address field that you can edit. It turns on by itself for `localhost`.
- **DevTools**: press ⌥⌘J for the elements, ⌥⌘K for the console, or ⌥⌘U for the page source.
- **Hard reload**: press ⇧⌘R to reload without the cache.
- ⭐ **Pull request tabs**: tabs for pull and merge requests show their state and repository.

### Settings and sync

- **Settings**: press ⌘, to open `rise://settings`. It has appearance, tabs, AI, system and keyboard shortcut settings.
- **Keyboard shortcuts**: change any shortcut in Settings → Keyboard shortcuts.
- **Flags**: open `rise://flags` for Chromium's experimental features.
- **Themes**: Light, Dark or Automatic. Change it with the paint roller button at the bottom of the sidebar, or in Settings.
- **iCloud sync**: your tabs and history sync with the iPhone app through iCloud. Turn this on or off with Rise → Sync Tabs with iCloud.

## Keyboard shortcuts

You can change all of these in Settings → Keyboard shortcuts.

| Shortcut | Action |
| --- | --- |
| ⌘T | New tab |
| ⌘L | Edit the address |
| ⌘O | Open a file |
| ⌘W | Close the tab |
| ⇧⌘W | Close the window |
| ⇧⌘T | Reopen the last closed tab |
| ⌘[ / ⌘] | Back / forward |
| ⇧⌘[ / ⇧⌘] | Previous / next tab |
| ⌘1 to ⌘9 | Go to a tab by its number |
| ⌃Tab / ⌃⇧Tab | Recent tabs switcher, forward / back |
| ⌥ + scroll | Choose a tab by scrolling |
| ⇧⌘A | Search tabs |
| ⌘Return | In the address bar, go to the open tab that is suggested |
| ⌥⌘↑ / ⌥⌘↓ | Move the tab up / down |
| ⌃⌥⌘↑ | Move the tab to the top |
| ⇧⌘K | Sort tabs by website |
| ⌃R | Smart Rename the tab under the pointer |
| ⌃⌘ (hold) | Wide sidebar |
| ⌘B | Show or hide the sidebar |
| ⇧⌘P | Peek the current page |
| ⌥⌘P | Move the Peek into a new tab |
| ⇧⌘D | Show the page in split view |
| ⌘R | Reload |
| ⇧⌘R | Reload without the cache |
| ⌘. | Stop loading |
| ⌘F | Find on the page, or ask about it |
| ⌘G / ⇧⌘G | Next / previous match |
| ⌥⌘G / ⌥⇧⌘G | Skip past the matches on the screen, down / up |
| ⌃⌘A | Annotate the selection |
| ⌥⌘T | Change times to your local time |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / actual size |
| ⇧⌘C | Copy the page's link |
| ⌘P | Print |
| ⌘E | AI chat |
| ⌥⌘L | Downloads list |
| ⌥⌘Return / ⌥⌘⌫ | Allow / deny a site's permission request |
| ⌥⇧1 to ⌥⇧9 | Open a pinned extension |
| ⇧⌘F | Full screen inside the window, on or off |
| ⌃⌘F | Full screen |
| ⌃D | Developer mode |
| ⌥⌘J / ⌥⌘K / ⌥⌘U | DevTools elements / console / page source |
| ⌘, | Settings |
| Escape | Close the address bar, Find or Peek |

## More information

- [Engine/README.md](Engine/README.md): how Rise uses Chromium, and its patches.
- [docs](docs): details about single features.
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md): licenses of the code that Rise includes from others.
