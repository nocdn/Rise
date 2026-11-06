import XCTest
@testable import RiseCore

final class TabArchivingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hours(_ count: Double) -> TimeInterval { count*3600 }
    private func use(hoursAgo: Double, days: Int = 0) -> TabUse {
        let last = now.addingTimeInterval(-hours(hoursAgo)), today = TabUse.day(of: last)
        return TabUse(lastUsed: last, days: (0..<days).map { today-$0 })
    }
    private func tab(_ address: String? = "https://example.com/", hoursAgo: Double, days: Int = 0, visits: Int = 0,
                     developer: Bool = false, protected: Bool = false) -> TabArchiveRules.Tab {
        TabArchiveRules.Tab(id: UUID(), use: use(hoursAgo: hoursAgo, days: days), url: address.flatMap(URL.init(string:)),
                            visits: visits, isDeveloper: developer, isProtected: protected)
    }
    /// Enough recent tabs at their own addresses that the ones always kept open don't come into it.
    private var recentTabs: [TabArchiveRules.Tab] {
        (0..<TabArchiveRules.alwaysOpen).map { tab("https://recent.example/\($0)", hoursAgo: 0) }
    }
    private func due(_ tabs: [TabArchiveRules.Tab], clock: TabUseClock = TabUseClock()) -> [UUID] {
        TabArchiveRules().due(recentTabs+tabs, clock: clock, at: now)
    }
    private func limit(_ tab: TabArchiveRules.Tab) -> Double { TabArchiveRules().limit(for: tab, at: now)/3600 }

    func testAnOrdinaryTabGoesAfterTheLimit() {
        let old = tab(hoursAgo: 48), fresh = tab("https://example.org/", hoursAgo: 47.9)
        XCTAssertEqual(due([old, fresh]), [old.id])
    }
    func testUseLengthensTheLimit() {
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 1)), 48)
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 2)), 96)
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 3)), 168)
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 4)), 168)
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 5)), 336)
    }
    func testOldUseDoesNotCount() {
        let last = now.addingTimeInterval(-hours(1)), today = TabUse.day(of: last)
        let tab = TabArchiveRules.Tab(id: UUID(), use: TabUse(lastUsed: last, days: [today-40, today-35, today]), url: URL(string: "https://example.com/"))
        XCTAssertEqual(limit(tab), 48)
    }
    func testVisitsLengthenTheLimit() {
        XCTAssertEqual(limit(tab(hoursAgo: 1, visits: 7)), 48)
        XCTAssertEqual(limit(tab(hoursAgo: 1, visits: 8)), 96)
        XCTAssertEqual(limit(tab(hoursAgo: 1, visits: 20)), 168)
    }
    func testTheLongestLimitWins() {
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 5, visits: 20)), 336)
        XCTAssertEqual(limit(tab(hoursAgo: 1, days: 2, visits: 20)), 168)
    }
    func testDeveloperTabsGetLonger() { XCTAssertEqual(limit(tab(hoursAgo: 1, developer: true)), 168) }
    func testBlankTabsGoWithinTheHour() {
        XCTAssertEqual(limit(tab(nil, hoursAgo: 1)), 1)
        XCTAssertEqual(limit(tab("about:blank", hoursAgo: 1)), 1)
    }
    func testSearchesGoSoonerUnlessReturnedTo() {
        let search = "https://www.google.com/search?q=rise"
        XCTAssertEqual(limit(tab(search, hoursAgo: 1)), 24)
        XCTAssertEqual(limit(tab(search, hoursAgo: 1, visits: 50)), 24, "Each search is its own address, so visits say little")
        XCTAssertEqual(limit(tab(search, hoursAgo: 1, days: 2)), 96)
    }
    func testSearchPagesAreRecognised() {
        for address in ["https://www.google.com/search?q=a", "https://www.google.co.uk/search?q=a", "https://kagi.com/search?q=a",
                        "https://www.bing.com/search?q=a", "https://duckduckgo.com/?q=a", "https://search.brave.com/search?q=a",
                        "https://www.youtube.com/results?search_query=a"] {
            XCTAssertTrue(TabArchiveRules.isSearchResults(URL(string: address)!), address)
        }
        for address in ["https://www.google.com/", "https://docs.google.com/document/d/1/edit", "https://mail.google.com/mail/u/0/",
                        "https://duckduckgo.com/", "https://www.youtube.com/watch?v=a", "https://example.com/search?q=a"] {
            XCTAssertFalse(TabArchiveRules.isSearchResults(URL(string: address)!), address)
        }
    }
    func testAnOlderCopyGoesSoonerButTheLatestDoesNot() {
        let older = tab("https://example.com/page#one", hoursAgo: 30), latest = tab("https://example.com/page#two", hoursAgo: 28)
        XCTAssertEqual(due([older, latest]), [older.id])
    }
    func testProtectedTabsStay() { XCTAssertEqual(due([tab(hoursAgo: 1000, protected: true)]), []) }
    func testTheMostRecentlyUsedAlwaysStayOpen() {
        let old = (0..<12).map { tab("https://old.example/\($0)", hoursAgo: 100+Double($0)) }
        let result = TabArchiveRules().due(old, clock: TabUseClock(), at: now)
        XCTAssertEqual(result, [old[11].id, old[10].id], "With 12 open, the 2 longest unused go")
        XCTAssertEqual(TabArchiveRules().due(Array(old.prefix(10)), clock: TabUseClock(), at: now), [])
    }
    func testAProtectedTabCountsTowardsThoseOpen() {
        let old = (0..<10).map { tab("https://old.example/\($0)", hoursAgo: 100+Double($0)) }
        let result = TabArchiveRules().due(old+[tab(hoursAgo: 1, protected: true)], clock: TabUseClock(), at: now)
        XCTAssertEqual(result, [old[9].id])
    }
    func testTheChosenLimitScalesEverything() {
        let rules = TabArchiveRules(limit: hours(24))
        XCTAssertEqual(rules.limit(for: tab(hoursAgo: 1, days: 2), at: now)/3600, 48)
        XCTAssertEqual(rules.limit(for: tab("https://kagi.com/search?q=a", hoursAgo: 1), at: now)/3600, 12)
    }

    // MARK: Time away

    func testANightCounts() {
        var clock = TabUseClock()
        clock.noteActive(at: now.addingTimeInterval(-hours(11)))
        clock.noteActive(at: now)
        XCTAssertEqual(clock.unused(since: now.addingTimeInterval(-hours(20)), at: now), hours(20))
    }
    func testAHolidayDoesNotCount() {
        var clock = TabUseClock()
        let left = now.addingTimeInterval(-hours(24*7))
        clock.noteActive(at: left)
        clock.noteActive(at: now)
        XCTAssertEqual(clock.unused(since: left.addingTimeInterval(-hours(10)), at: now), hours(10))
        XCTAssertEqual(due([tab(hoursAgo: 24*7+10)], clock: clock), [])
        XCTAssertEqual(clock.unused(since: now, at: now.addingTimeInterval(hours(5))), hours(5), "A tab used on returning isn't affected")
    }
    func testTimeAwayIsCountedWhereItOverlaps() {
        var clock = TabUseClock()
        let left = now.addingTimeInterval(-hours(40))
        clock.noteActive(at: left)
        clock.noteActive(at: left.addingTimeInterval(hours(20)))
        // Used 10 hours into the 20 away, as on the phone, leaves those last 10 away.
        XCTAssertEqual(clock.unused(since: left.addingTimeInterval(hours(10)), at: now), hours(30)-hours(10))
    }
    func testAClockGoingBackwardsDoesNoHarm() {
        var clock = TabUseClock()
        clock.noteActive(at: now)
        clock.noteActive(at: now.addingTimeInterval(-hours(100)))
        XCTAssertEqual(clock.lastActive, now)
        XCTAssertEqual(clock.away, [])
        XCTAssertEqual(clock.unused(since: now, at: now.addingTimeInterval(-hours(1))), 0)
    }
    func testTheClockSurvivesSaving() throws {
        var clock = TabUseClock()
        clock.noteActive(at: now.addingTimeInterval(-hours(100)))
        clock.noteActive(at: now)
        XCTAssertEqual(try JSONDecoder().decode(TabUseClock.self, from: JSONEncoder().encode(clock)), clock)
    }

    // MARK: Use

    func testRecordingAUseWaitsForTheIntervalButNotANewDay() {
        var use = TabUse(lastUsed: now)
        XCTAssertTrue(use.record(at: now.addingTimeInterval(1), every: 300), "The first of its day")
        XCTAssertFalse(use.record(at: now.addingTimeInterval(2), every: 300))
        XCTAssertEqual(use.lastUsed, now.addingTimeInterval(1))
        XCTAssertTrue(use.record(at: now.addingTimeInterval(86400), every: 300))
        XCTAssertEqual(use.days.count, 2)
    }
    func testDaysAreKeptWithinBounds() {
        var use = TabUse(lastUsed: now)
        for day in 0..<30 { use.record(at: now.addingTimeInterval(Double(day)*86400)) }
        XCTAssertEqual(use.days.count, TabUse.maximumDays)
        XCTAssertEqual(use.days.last, TabUse.day(of: now.addingTimeInterval(29*86400)))
    }
    func testMergingTakesTheLatestAndEveryDay() {
        let a = TabUse(lastUsed: now, days: [1, 2]), b = TabUse(lastUsed: now.addingTimeInterval(9), days: [2, 3])
        XCTAssertEqual(a.merging(b), TabUse(lastUsed: now.addingTimeInterval(9), days: [1, 2, 3]))
        XCTAssertEqual(a.merging(b), b.merging(a))
        XCTAssertEqual(a.merging(nil), a)
    }

    // MARK: The ledger

    private func ledgerRecord() -> (SharedTabsLedger, UUID) {
        var ledger = SharedTabsLedger(), id = UUID()
        _ = ledger.capture([SharedBrowserTab(id: id, url: "https://example.com/", title: "A")])
        id = ledger.tabs[0].id
        return (ledger, id)
    }
    func testAUseFromAnotherDeviceIsKeptButIsNotAChangeToShow() {
        var (ledger, id) = ledgerRecord()
        var incoming = ledger.records[id]!
        incoming.use = TabUse(lastUsed: now)
        XCTAssertFalse(ledger.merge(incoming))
        XCTAssertEqual(ledger.records[id]?.use, TabUse(lastUsed: now))
    }
    func testAClientThatDoesNotKnowOfUseCannotLoseIt() {
        var (ledger, id) = ledgerRecord()
        XCTAssertTrue(ledger.recordUse(of: id, at: now, every: 0))
        let kept = ledger.records[id]?.use
        var incoming = ledger.records[id]!
        incoming.use = nil; incoming.tab.title = "New"; incoming.contentVersion = TabSyncVersion(clock: Int64.max/2, device: UUID())
        XCTAssertTrue(ledger.merge(incoming))
        XCTAssertEqual(ledger.records[id]?.use, kept)
        XCTAssertEqual(ledger.tabs[0].title, "New")
    }
    func testACloseStillWinsAndAClosedTabTakesNoUse() {
        var (ledger, id) = ledgerRecord()
        _ = ledger.capture([])
        XCTAssertFalse(ledger.recordUse(of: id, at: now, every: 0))
        XCTAssertEqual(ledger.tabs, [])
        var unknown = ledger
        XCTAssertFalse(unknown.recordUse(of: UUID(), at: now, every: 0))
    }
    func testARecordFromBeforeUseStillDecodes() throws {
        let (ledger, id) = ledgerRecord()
        let data = try JSONEncoder().encode(ledger.records[id]!)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"use\""), "Nothing extra for other clients until it's used")
        XCTAssertNil(try JSONDecoder().decode(SharedTabRecord.self, from: data).use)
    }

    // MARK: Two devices

    /// Two devices with the same open tab, as each has it after syncing.
    private func twoDevices() -> (mac: SharedTabsLedger, phone: SharedTabsLedger, id: UUID) {
        let id = UUID(), tab = SharedBrowserTab(id: id, url: "https://example.com/", title: "A")
        var mac = SharedTabsLedger(), phone = SharedTabsLedger()
        _ = mac.capture([tab])
        phone.merge(mac.records[id]!)
        phone.observedTabs = [tab]
        return (mac, phone, id)
    }
    private func sync(_ a: inout SharedTabsLedger, _ b: inout SharedTabsLedger, _ id: UUID) {
        let fromA = a.records[id]!, fromB = b.records[id]!
        a.merge(fromB); b.merge(fromA)
        XCTAssertEqual(a.records[id], b.records[id], "Both end up the same, whichever way round")
    }
    func testATabArchivedOnOneDeviceIsListedAndClosedOnTheOther() {
        var (mac, phone, id) = twoDevices()
        _ = mac.capture([])
        XCTAssertTrue(mac.markArchived(id, at: now))
        XCTAssertEqual(mac.archivedTabs(at: now).map(\.id), [id])
        phone.merge(mac.records[id]!)
        XCTAssertEqual(phone.tabs, [], "It closes on the phone")
        XCTAssertEqual(phone.archivedTabs(at: now).map(\.id), [id], "And is in the same list")
        XCTAssertEqual(phone.archivedTabs(at: now).first?.url, "https://example.com/")
    }
    func testBothArchivingTheSameTabLeavesOneEntry() {
        var (mac, phone, id) = twoDevices()
        _ = mac.capture([]); _ = phone.capture([])
        _ = mac.markArchived(id, at: now)
        _ = phone.markArchived(id, at: now.addingTimeInterval(30))
        sync(&mac, &phone, id)
        XCTAssertEqual(mac.archivedTabs(at: now).count, 1)
        XCTAssertEqual(phone.archivedTabs(at: now).first?.archivedAt, now, "Keeping the earlier time, which both agree on")
    }
    func testReopeningOnOneDeviceTakesItOffBoth() {
        var (mac, phone, id) = twoDevices()
        _ = mac.capture([]); _ = mac.markArchived(id, at: now)
        sync(&mac, &phone, id)
        XCTAssertTrue(phone.removeFromArchive(id))
        sync(&mac, &phone, id)
        XCTAssertEqual(mac.archivedTabs(at: now), [])
        XCTAssertEqual(phone.archivedTabs(at: now), [])
    }
    func testBeingTakenOutOfTheListWinsOverAnArchivingStillOnItsWay() {
        var (mac, phone, id) = twoDevices()
        _ = mac.capture([]); _ = phone.capture([])
        _ = mac.markArchived(id, at: now)
        _ = phone.markArchived(id, at: now)
        XCTAssertTrue(mac.removeFromArchive(id), "Reopened on the Mac, before it's heard from the phone")
        sync(&mac, &phone, id)
        XCTAssertEqual(mac.archivedTabs(at: now), [])
        XCTAssertEqual(phone.archivedTabs(at: now), [])
    }
    func testAnArchivedTabKeepsTheLatestPageFromEitherDevice() {
        var (mac, phone, id) = twoDevices()
        let moved = SharedBrowserTab(id: id, url: "https://example.com/later", title: "Later")
        _ = phone.capture([moved])
        _ = mac.capture([]); _ = mac.markArchived(id, at: now)
        sync(&mac, &phone, id)
        XCTAssertEqual(mac.archivedTabs(at: now).first?.url, "https://example.com/later", "So what the phone had moved on to isn't lost")
        XCTAssertEqual(mac.tabs, []); XCTAssertEqual(phone.tabs, [])
    }
    func testAnEntryOnlyShowsOnceItsTabHasClosed() {
        var (mac, _, id) = twoDevices()
        _ = mac.markArchived(id, at: now)
        XCTAssertEqual(mac.archivedTabs(at: now), [])
        _ = mac.capture([])
        XCTAssertEqual(mac.archivedTabs(at: now).count, 1)
        XCTAssertEqual(mac.archivedTabs(at: now.addingTimeInterval(ArchivedTabs.keptFor+1)), [], "And goes in time")
    }
    func testABlankTabIsNeverListed() {
        var ledger = SharedTabsLedger(), id = UUID()
        _ = ledger.capture([SharedBrowserTab(id: id, url: nil, title: nil)])
        id = ledger.tabs[0].id
        XCTAssertFalse(ledger.markArchived(id, at: now))
    }
    func testMarksChangeNothingToShow() {
        var (mac, phone, id) = twoDevices()
        _ = mac.setKept(id, true)
        XCTAssertFalse(phone.merge(mac.records[id]!))
        XCTAssertTrue(phone.records[id]?.kept?.isKept == true)
    }
    func testAPinOnTheMacProtectsTheTabOnThePhone() {
        var (mac, phone, id) = twoDevices()
        XCTAssertTrue(mac.setKept(id, true))
        XCTAssertFalse(mac.setKept(id, true), "Said once")
        sync(&mac, &phone, id)
        XCTAssertFalse(phone.setKept(id, false), "The phone has no pins, so it can't undo one")
        XCTAssertEqual(phone.records[id]?.kept?.isKept, true)
        XCTAssertTrue(mac.setKept(id, false), "The Mac can, once it's unpinned")
        sync(&mac, &phone, id)
        XCTAssertEqual(phone.records[id]?.kept?.isKept, false)
    }
    func testAnotherDevicesUseDelaysArchiving() {
        var (mac, phone, id) = twoDevices()
        let old = now.addingTimeInterval(-hours(72))
        XCTAssertTrue(mac.recordUse(of: id, at: old, every: 0))
        XCTAssertTrue(phone.recordUse(of: id, at: now.addingTimeInterval(-hours(1)), every: 0))
        sync(&mac, &phone, id)
        let tab = TabArchiveRules.Tab(id: id, use: mac.records[id]!.use!, url: URL(string: "https://example.com/"))
        XCTAssertEqual(due([tab]), [], "Used on the phone an hour ago, the Mac leaves it")
        XCTAssertEqual(mac.records[id]?.use?.days.count, 2, "And it was used on two days")
    }
    func testStartingATabsTimeDoesNotOverrideAUse() {
        var (mac, _, id) = twoDevices()
        XCTAssertTrue(mac.beginUse(of: id, at: now))
        XCTAssertFalse(mac.beginUse(of: id, at: now.addingTimeInterval(9)))
        XCTAssertEqual(mac.records[id]?.use?.lastUsed, now)
        XCTAssertEqual(mac.records[id]?.use?.days, [], "It hasn't been used yet")
    }
    func testARecordFromBeforeMarksStillDecodes() throws {
        let (mac, _, id) = twoDevices()
        let text = String(decoding: try JSONEncoder().encode(mac.records[id]!), as: UTF8.self)
        XCTAssertFalse(text.contains("\"archive\"") || text.contains("\"kept\""), "Nothing extra for other clients until it's needed")
    }

    // MARK: Following other devices

    func testTheMacsListFollowsOtherDevices() {
        let archive = ArchivedTabs(storageURL: archiveURL(), now: now)
        let mine = saved("Mine"), theirs = ArchivedTab(tab: saved("Theirs"), archivedAt: now), open = ArchivedTab(tab: saved("Open"), archivedAt: now)
        var rich = saved("Rich"); rich.sessionState = Data([1])
        archive.add([mine, rich], at: now)
        archive.reconcile(with: [theirs, open, ArchivedTab(tab: SavedTab(id: rich.id, url: rich.url, title: "Rich"), archivedAt: now)],
                          removed: { _ in false }, open: [open.id], at: now)
        XCTAssertEqual(Set(archive.entries.map(\.id)), [mine.id, rich.id, theirs.id], "Not the one still open here")
        XCTAssertEqual(archive.entries.first { $0.id == rich.id }?.tab.sessionState, Data([1]), "And what only this Mac has is kept")
        archive.reconcile(with: [theirs], removed: { $0 == theirs.id || $0 == mine.id }, open: [], at: now)
        XCTAssertEqual(archive.entries.map(\.id), [rich.id])
    }
    func testArchivingAgainReplacesRatherThanRepeats() {
        let archive = ArchivedTabs(storageURL: archiveURL(), now: now), tab = saved("One")
        archive.add([tab], at: now)
        archive.add([tab], at: now)
        XCTAssertEqual(archive.entries.count, 1)
    }

    // MARK: The archive

    private func archiveURL() -> URL {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseArchive-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("archived-tabs.json")
    }
    private func saved(_ title: String) -> SavedTab { SavedTab(url: "https://example.com/\(title.lowercased())", title: title) }

    func testTheArchiveSurvivesRelaunching() {
        let url = archiveURL(), archive = ArchivedTabs(storageURL: url, now: now), tab = saved("One")
        archive.add([tab], at: now)
        archive.flush()
        XCTAssertEqual(ArchivedTabs(storageURL: url, now: now).entries, [ArchivedTab(tab: tab, archivedAt: now)])
    }
    func testNewestComeFirstAndOldOnesGo() {
        let url = archiveURL(), archive = ArchivedTabs(storageURL: url, now: now), old = saved("Old"), new = saved("New")
        archive.add([old], at: now)
        archive.add([new], at: now.addingTimeInterval(60))
        XCTAssertEqual(archive.entries.map(\.tab.title), ["New", "Old"])
        archive.flush()
        let later = now.addingTimeInterval(ArchivedTabs.keptFor+1)
        XCTAssertEqual(ArchivedTabs(storageURL: url, now: later).entries.map(\.tab.title), ["New"])
    }
    func testTheArchiveHasALimit() {
        let archive = ArchivedTabs(storageURL: archiveURL(), now: now)
        archive.add((0..<ArchivedTabs.maximumCount+5).map { saved("\($0)") }, at: now)
        XCTAssertEqual(archive.entries.count, ArchivedTabs.maximumCount)
    }
    func testRemovingGivesTheTabBack() {
        let archive = ArchivedTabs(storageURL: archiveURL(), now: now), tab = saved("One")
        archive.add([tab], at: now)
        XCTAssertEqual(archive.remove(tab.id), tab)
        XCTAssertNil(archive.remove(tab.id))
        XCTAssertEqual(archive.entries, [])
    }
    func testSearchingLooksForEveryWordInTitleAndAddress() {
        let archive = ArchivedTabs(storageURL: archiveURL(), now: now)
        archive.add([SavedTab(url: "https://docs.google.com/a", title: "Housing 4th year"), SavedTab(url: "https://github.com/b", title: "Pull request")], at: now)
        XCTAssertEqual(archive.matching("").count, 2)
        XCTAssertEqual(archive.matching("HOUSING docs").map(\.tab.title), ["Housing 4th year"])
        XCTAssertEqual(archive.matching("github").map(\.tab.title), ["Pull request"])
        XCTAssertEqual(archive.matching("housing github"), [])
    }
    func testASessionFromBeforeUseStillDecodes() throws {
        let data = Data(#"{"id":"\#(UUID().uuidString)","url":"https://example.com/","title":"A","pinned":false,"developer":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SavedTab.self, from: data).use)
    }
}
