# Archiving unused tabs

Tabs that go unused move to **Archived Tabs**, from where they reopen. Mac and iOS each do this on
their own, so either works without the other; with both, see [Two devices](#two-devices). The time
limit is set on each device: 48 hours unless changed, or Never.

| | Mac | iOS |
|---|---|---|
| Time limit | Settings → Tabs → Archive unused tabs | More → Site settings → App settings → Archive unused tabs |
| Archived Tabs | History → Archived Tabs…, the palette, or a right-click on the downloads button | More in the tab view |
| After archiving | A notice in the address bar, with Undo | A toast, which opens the list when tapped |

The list stays for 90 days and at most 500 tabs. A blank tab holds nothing to come back to, so it just
closes.

## What counts as used

**Mac:** a tab is used when it has been on screen for 5 seconds, or at each minute it stays on screen,
with Rise frontmost and input within the last 5 minutes. Passing through tabs doesn't count, and
neither does a window left open overnight. **iOS:** the tab showing while the app is active, as it
changes and each minute. Private tabs are never archived and have no part in this.

Each `SharedTabRecord` carries a `TabUse`, merged by taking the latest time and every day, so it needs
no version. A use travels at most once per tab in 15 minutes.

A tab with no record of use, as every tab has at first, starts counting from when a device first sees
it, so updating never archives anything straight away.

## How long a tab gets

From `TabArchiveRules`, where the limit is the one chosen:

| Tab | Time unused |
|---|---|
| Blank | 1 hour |
| A search engine's results, or an older copy of a tab open at the same address | ½ × limit |
| Anything else | limit |
| Used on 2 days in the last 30, or 8+ visits to its address | 2 × limit |
| Used on 3–4 days, 20+ visits, or a developer mode tab | 3½ × limit |
| Used on 5+ days | 7 × limit |

The longest that applies wins, and a search or a copy only goes sooner if nothing lengthens its time.
Visits come from browsing history, on every device, and aren't counted for search results, as each
search is its own address.

The visit levels come from the 69 tabs open when this was written: 3 had 20+ visits, including Gmail,
and 11 had 8+.

The 10 most recently used tabs always stay open on each device, and these never go, however long unused:

- **Mac:** pinned, renamed, developer mode and split tabs, tabs on screen, playing sound or in picture
  in picture, tabs loading, a tab with a Peek or an assistant answer under way, and pages with something
  part-filled. A page that's been frozen in the background can't answer, so it goes by what it held
  when it was left.
- **iOS:** the tab showing, the last regular tab while in private browsing, tabs loading, playing,
  using the camera or microphone, pages with something part-filled, and any tab a Mac has marked kept.

## Time away

Any stretch of 12 hours or more without the app in use doesn't count on that device, as `TabUseClock`
leaves it out. A night normally counts and a holiday doesn't. Nothing is archived while the app isn't in
use, only once it is again.

## Two devices

Neither device turns the other off, and neither is in charge. Each decides from the same synced uses,
and everything they share merges whichever order it arrives in, so there's nothing to conflict:

- **Before archiving,** a device fetches from iCloud, so a tab just used elsewhere is seen as used and
  one already archived elsewhere is already gone. If iCloud can't be reached it waits. With sync off or
  no account, there's nothing to wait for and it goes ahead.
- **One list.** An archived tab is its closed `SharedTabRecord` with a `TabArchiveMark`, so it needs no
  new CloudKit record type, and the record already holds its address, title and Back/Forward history.
  A record closed by anything else has no mark. Both archiving one tab leaves one entry, with the
  earlier time.
- **Reopening or deleting is final everywhere.** The mark's `isRemoved` wins over any archiving still on
  its way, and the reopened tab has a new identity, as the closure of the old one always wins. Reopening
  the same tab on both devices before either has heard of the other gives two tabs.
- **What a device can't see.** A pin stays on its Mac, so the Mac sends a `TabKeptMark` for pinned,
  renamed, developer mode and split tabs, those playing sound and pages left part-filled, and the phone
  leaves them alone. Only the device that set a mark can clear it.
- **The latest page is kept.** If the phone had moved a tab on when the Mac archived it, the list has
  the page the phone moved to.
- **Each device's limit is its own,** so the shorter one is the one that acts: with Never on the Mac and
  48 hours on the phone, the phone still archives, and those tabs close on the Mac too.
- **On Mac,** an entry also keeps what only that Mac has, such as the engine's session and icon, in
  `archived-tabs.json`. A tab archived elsewhere joins the list with them if it was open there. Local
  pages that don't sync stay in this file alone. **iOS** lists the shared records directly, one row to
  an address.
- **The page being read** closes on iOS if another device archives it, as any remote closure does, and
  stays open on Mac, out of the list until it's let go. A use on an offline phone can't reach the Mac in
  time, so a tab read there can still be archived.

The Chromium extension doesn't count as a use and leaves these marks out of what it writes, which the
merges make harmless.

## Verification

```sh
./scripts/test.sh --filter 'TabArchiv'
python3 scripts/test-chromium-live.py Tests/Live/ChromiumTabArchiveChecks.swift
# Two clients through real CloudKit, in a disposable zone:
build/cloudkit-signing/Build/Products/Debug/RiseSigning.app/Contents/MacOS/RiseSigning --test-tab-sync
# On iOS, in the app, with real WebKit pages. Results are in Caches/TabArchiveAudit:
xcrun simctl launch <simulator> dev.bartosz.Rise.iOS -RiseTabArchiveAudit
```
