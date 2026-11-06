import XCTest
import AppKit
import RiseCore
@testable import Rise

final class TabArchiveTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseTabArchive-\(UUID())")
        let suite = "RiseTabArchive-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.stopTabSleep()
        addTeardownBlock { @MainActor in
            browser.saveWork?.cancel(); browser.tabUseWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.window?.orderOut(nil); browser.archivedTabs.flush()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }
    /// So many tabs open, with the first selected, the rest behind it, used `hoursAgo`.
    @MainActor @discardableResult private func fill(_ browser: BrowserController, count: Int, hoursAgo: Double) -> [BrowserTab] {
        let added = (0..<count).map { browser.addTab(url: URL(string: "https://example.com/\($0)"), background: true) }
        let used = TabUse(lastUsed: Date().addingTimeInterval(-hoursAgo*3600))
        for tab in added { tab.use = used; tab.page.stopLoading() }
        return added
    }

    @MainActor func testUnusedTabsAreDueAndUsedOnesAreNot() {
        let browser = browser()
        let old = fill(browser, count: 12, hoursAgo: 72), recent = fill(browser, count: 1, hoursAgo: 1)
        let due = browser.tabsDueForArchiving().map(\.id)
        XCTAssertFalse(due.isEmpty)
        XCTAssertTrue(due.allSatisfy { id in old.contains { $0.id == id } })
        XCTAssertFalse(due.contains(recent[0].id))
    }
    @MainActor func testTheTenMostRecentlyUsedStay() {
        let browser = browser()
        fill(browser, count: 8, hoursAgo: 72)
        XCTAssertEqual(browser.tabsDueForArchiving().count, 0, "Fewer than ten are open")
    }
    @MainActor func testPinnedRenamedAndSplitTabsStay() {
        let browser = browser()
        let tabs = fill(browser, count: 14, hoursAgo: 72)
        tabs[0].pinned = true; tabs[1].rename("Kept")
        browser.splitGroups = [SplitTabGroup(leftID: tabs[2].id, rightID: tabs[3].id)]
        let due = Set(browser.tabsDueForArchiving().map(\.id))
        XCTAssertFalse(due.contains(tabs[0].id)); XCTAssertFalse(due.contains(tabs[1].id))
        XCTAssertFalse(due.contains(tabs[2].id)); XCTAssertFalse(due.contains(tabs[3].id))
    }
    @MainActor func testNeverTurnsItOff() {
        let browser = browser()
        fill(browser, count: 14, hoursAgo: 1000)
        browser.setTabArchiveHours(0)
        XCTAssertEqual(browser.tabsDueForArchiving().count, 0)
    }
    @MainActor func testUseOnAnotherDeviceCounts() {
        let browser = browser()
        let folder = browser.sessionURL.deletingLastPathComponent()
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: browser.preferences, cloudAvailable: false)
        browser.tabSync = sync
        let tabs = fill(browser, count: 14, hoursAgo: 72)
        sync.start(tabs: browser.sharedTabsSnapshot)
        sync.recordUse(of: tabs[0].id)
        XCTAssertFalse(browser.tabsDueForArchiving().contains { $0 === tabs[0] })
        XCTAssertTrue(tabs[0].use.lastUsed > Date().addingTimeInterval(-60), "And it's kept with the tab")
        sync.flush()
    }
    @MainActor func testArchivingKeepsTheTabOutOfRecentlyClosedAndUndoPutsItBack() {
        let browser = browser()
        let first = browser.addTab(url: URL(string: "https://example.com/first"))
        let tabs = fill(browser, count: 3, hoursAgo: 72), order = browser.tabs.map(\.id)
        browser.archive([tabs[1]])
        XCTAssertFalse(browser.tabs.contains { $0 === tabs[1] })
        XCTAssertEqual(browser.archivedTabs.entries.map(\.id), [tabs[1].id])
        XCTAssertEqual(browser.closedTabs.count, 0)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertEqual(browser.selectedBar.notice?.actionLabel?.stringValue, "Undo")
        XCTAssertEqual(browser.selectedBar.notice?.actionLabel?.accessibilityPerformPress(), true)
        XCTAssertEqual(browser.tabs.map(\.id), order)
        XCTAssertEqual(browser.archivedTabs.entries.count, 0)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertTrue(browser.tabs.first { $0.id == tabs[1].id }!.use.lastUsed > Date().addingTimeInterval(-60), "Back, it starts its time over")
    }
    @MainActor func testReopeningShowsItAtTheTopAndClosedTabsGetANewIdentity() {
        let browser = browser()
        let folder = browser.sessionURL.deletingLastPathComponent()
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: browser.preferences, cloudAvailable: false)
        browser.tabSync = sync
        let tabs = fill(browser, count: 3, hoursAgo: 72)
        browser.select(tabs[0].id)
        sync.start(tabs: browser.sharedTabsSnapshot)
        let id = tabs[2].id
        browser.archive([tabs[2]])
        XCTAssertTrue(sync.isClosed(id))
        browser.reopenArchivedTab(id)
        XCTAssertEqual(browser.tabs.first?.url?.absoluteString ?? browser.tabs.first?.requestedURL?.absoluteString, "https://example.com/2")
        XCTAssertEqual(browser.selectedID, browser.tabs.first?.id)
        XCTAssertNotEqual(browser.tabs.first?.id, id, "So its closure can't close it again")
        XCTAssertEqual(browser.archivedTabs.entries.count, 0)
        sync.flush()
    }
    @MainActor func testUseIsSavedWithTheSessionAndBackInTheTab() {
        let browser = browser()
        let tab = browser.addTab(url: URL(string: "https://example.com/saved"))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        tab.use = TabUse(lastUsed: when, days: [5])
        XCTAssertEqual(tab.saved.use, TabUse(lastUsed: when, days: [5]))
        XCTAssertEqual(BrowserTab(saved: tab.saved).use, TabUse(lastUsed: when, days: [5]))
    }
    @MainActor func testATabFromBeforeUseStartsItsTimeNow() {
        let restored = BrowserTab(saved: SavedTab(url: "https://example.com/", title: "A"))
        XCTAssertTrue(restored.use.lastUsed > Date().addingTimeInterval(-60))
        XCTAssertEqual(restored.use.days, [])
    }
    @MainActor func testTheTickOnlyCountsWhileInUseAndNotesTimeAway() throws {
        let browser = browser()
        let tab = browser.addTab(url: URL(string: "https://example.com/"))
        let long = Date().addingTimeInterval(-86400*30)
        tab.use = TabUse(lastUsed: long)
        browser.tabUseClock = TabUseClock()
        browser.lastTabArchiveCheck = Date()
        browser.tabUseTick(using: false)
        XCTAssertEqual(tab.use.lastUsed, long, "Nothing while Rise isn't in use")
        XCTAssertNil(browser.tabUseClock.lastActive)
        browser.tabUseTick(using: true, now: Date().addingTimeInterval(-86400))
        browser.tabUseTick(using: true)
        XCTAssertEqual(browser.tabUseClock.away.count, 1)
        XCTAssertTrue(tab.use.lastUsed > Date().addingTimeInterval(-60), "The tab on screen is in use")
        let saved = try XCTUnwrap(browser.preferences.data(forKey: BrowserController.tabUseClockKey))
        XCTAssertEqual(try JSONDecoder().decode(TabUseClock.self, from: saved), browser.tabUseClock)
    }
    @MainActor private func syncing(_ browser: BrowserController) -> SharedTabsSync {
        let folder = browser.sessionURL.deletingLastPathComponent()
        let sync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: browser.preferences, cloudAvailable: false)
        browser.tabSync = sync
        return sync
    }
    @MainActor func testArchivingMarksItForOtherDevicesAndReopeningClearsIt() {
        let browser = browser(), sync = syncing(browser)
        let tabs = fill(browser, count: 2, hoursAgo: 72)
        browser.select(tabs[0].id)
        sync.start(tabs: browser.sharedTabsSnapshot)
        let id = tabs[1].id
        browser.archive([tabs[1]])
        XCTAssertEqual(sync.archivedTabs().map(\.id), [id])
        browser.reopenArchivedTab(id)
        XCTAssertEqual(sync.archivedTabs(), [])
        XCTAssertTrue(sync.isRemovedFromArchive(id))
        sync.flush()
    }
    @MainActor func testPinningTellsOtherDevicesToLeaveItAlone() {
        let browser = browser(), sync = syncing(browser)
        let tabs = fill(browser, count: 3, hoursAgo: 1)
        sync.start(tabs: browser.sharedTabsSnapshot)
        browser.shareKeptTabs()
        XCTAssertFalse(sync.isKept(tabs[0].id))
        tabs[0].pinned = true; tabs[1].rename("Mine")
        browser.shareKeptTabs()
        XCTAssertTrue(sync.isKept(tabs[0].id)); XCTAssertTrue(sync.isKept(tabs[1].id)); XCTAssertFalse(sync.isKept(tabs[2].id))
        tabs[0].pinned = false
        browser.shareKeptTabs()
        XCTAssertFalse(sync.isKept(tabs[0].id))
        sync.flush()
    }
    @MainActor func testATabArchivedElsewhereJoinsTheListWithWhatOnlyThisMacHas() {
        let browser = browser(), sync = syncing(browser)
        let tabs = fill(browser, count: 3, hoursAgo: 1), keep = tabs[0], gone = tabs[1]
        browser.select(keep.id)
        sync.start(tabs: browser.sharedTabsSnapshot)
        sync.archive([gone.id])
        browser.applySharedTabs(browser.sharedTabsSnapshot.filter { $0.id != gone.id })
        XCTAssertFalse(browser.tabs.contains { $0 === gone })
        XCTAssertEqual(browser.archivedTabs.entries.map(\.id), [gone.id])
        XCTAssertEqual(browser.closedTabs.count, 0)
        sync.flush()
    }
    @MainActor func testAPageBeingReadStaysOutOfTheListWhenArchivedElsewhere() {
        let browser = browser(), sync = syncing(browser)
        let tabs = fill(browser, count: 2, hoursAgo: 1)
        browser.select(tabs[0].id)
        sync.start(tabs: browser.sharedTabsSnapshot)
        sync.archive([tabs[0].id])
        browser.applySharedTabs(browser.sharedTabsSnapshot.filter { $0.id != tabs[0].id })
        XCTAssertTrue(browser.tabs.contains { $0 === tabs[0] }, "The Mac never takes away the page being read")
        browser.reconcileArchivedTabs()
        XCTAssertEqual(browser.archivedTabs.entries, [])
        sync.flush()
    }
    @MainActor func testABlankTabJustCloses() {
        let browser = browser(), first = browser.addTab(url: URL(string: "https://example.com/"))
        let blank = browser.addTab(background: true)
        browser.archive([blank])
        XCTAssertFalse(browser.tabs.contains { $0 === blank })
        XCTAssertEqual(browser.archivedTabs.entries, [])
        XCTAssertEqual(browser.selectedID, first.id)
    }
    @MainActor func testTheListSearchesAndRemoves() {
        let browser = browser()
        browser.archivedTabs.add([SavedTab(url: "https://a.example/", title: "Alpha"), SavedTab(url: "https://b.example/", title: "Beta")])
        let list = ArchivedTabsController(archive: browser.archivedTabs)
        list.loadViewIfNeeded()
        XCTAssertEqual(list.shown.count, 2)
        var reopened: UUID?
        list.reopen = { reopened = $0 }
        XCTAssertNil(reopened)
        browser.archivedTabs.remove(list.shown[0].id)
        list.reload()
        XCTAssertEqual(list.shown.count, 1)
    }
    @MainActor func testSettingsOfferTheLimitAndTheList() {
        let browser = browser()
        let rows = browser.riseSettingRows("tabs")
        let limit = rows.first { $0["key"] as? String == "tabArchiveHours" }
        XCTAssertEqual(limit?["value"] as? String, "48")
        XCTAssertNotNil(rows.first { $0["key"] as? String == "showArchivedTabs" })
        browser.setRiseSetting("tabArchiveHours", "168")
        XCTAssertEqual(browser.tabArchiveHours, 168)
    }
}
