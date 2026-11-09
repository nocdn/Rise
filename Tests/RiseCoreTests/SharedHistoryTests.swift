import XCTest
@testable import RiseCore

final class SharedHistoryTests: XCTestCase {
    private let account = URL(string: "https://voxi.co.uk/account")!
    private let home = URL(string: "https://voxi.co.uk/")!
    private func history() -> BrowsingHistory {
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseVisits-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return BrowsingHistory(storageURL: folder.appendingPathComponent("history.json"))
    }
    private func exchange(_ a: BrowsingHistory, _ b: BrowsingHistory) {
        let left = a.snapshot, right = b.snapshot
        a.merge(right); b.merge(left)
    }
    func testRecordIDsKeepTheirSyncedFormat() {
        // Both devices and every saved zone name records by this ID: its text must never change.
        XCTAssertEqual(SharedHistoryRecord.id(for: "https://example.com/"),
                       "history-0f115db062b7c0dd030b16878c99dea5c354b49dc37b38eb8846179c7783e9d7")
    }
    func testConcurrentVisitsSumOnceAndBothDevicesPreferTheSameAccountPage() {
        let a = history(), b = history()
        for _ in 0..<8 { a.record(account, title: "Account") }
        for _ in 0..<5 { b.record(account, title: "Your account") }
        for _ in 0..<3 { b.record(home, title: "VOXI") }
        for _ in 0..<20 { b.record(URL(string: "https://voxi.co.uk/sign-in?returnTo=account")!, title: "Sign in") }
        exchange(a, b)
        XCTAssertEqual(a.snapshot, b.snapshot)
        XCTAssertEqual(a.entries.first { $0.url == account.absoluteString }?.visits, 13)
        for _ in 0..<10 { exchange(a, b) }
        XCTAssertEqual(a.entries.first { $0.url == account.absoluteString }?.visits, 13)
        for store in [a, b] {
            XCTAssertEqual(AddressSuggestionEngine.suggestions(for: "vox", history: store, tabs: []).first?.completion, "voxi.co.uk/account")
        }
        a.record(account, title: "Account"); b.record(account, title: "Account")
        exchange(a, b)
        XCTAssertEqual(a.entries.first { $0.url == account.absoluteString }?.visits, 15)
        let count = a.entries.first { $0.url == account.absoluteString }?.visits
        a.updateTitle("A new title", for: account); exchange(a, b)
        XCTAssertEqual(b.entries.first { $0.url == account.absoluteString }?.title, "A new title")
        XCTAssertEqual(b.entries.first { $0.url == account.absoluteString }?.visits, count)
    }
    func testCountersSurviveRelaunchAndOldSnapshotsNeverIncreaseThemTwice() throws {
        let a = history(), b = history()
        for _ in 0..<4 { a.record(account, title: "Account") }
        b.merge(a.snapshot); b.record(account, title: "Account"); exchange(a, b)
        let stale = a.snapshot
        try a.save()
        let restarted = BrowsingHistory(storageURL: a.storageURL)
        restarted.record(account, title: "Account")
        restarted.merge(stale); b.merge(restarted.snapshot); restarted.merge(b.snapshot)
        XCTAssertEqual(restarted.entries.first?.visits, 6)
        XCTAssertEqual(restarted.snapshot, b.snapshot)
    }
    func testLegacyArrayMigratesOnlyOnceWithItsExistingCounts() throws {
        let a = history(), b = history()
        try FileManager.default.createDirectory(at: a.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = HistoryEntry(url: account.absoluteString, title: "Account", visits: 25, lastVisited: Date())
        try JSONEncoder().encode([entry]).write(to: a.storageURL)
        let migrated = BrowsingHistory(storageURL: a.storageURL)
        b.merge(migrated.snapshot)
        let reopened = BrowsingHistory(storageURL: a.storageURL)
        XCTAssertEqual(reopened.snapshot, migrated.snapshot)
        b.merge(reopened.snapshot)
        XCTAssertEqual(b.entries.first?.visits, 25)
        reopened.record(account, title: "Account"); b.merge(reopened.snapshot)
        XCTAssertEqual(b.entries.first?.visits, 26)
    }
    func testClearWinsOverOfflineEditsAndNewVisitsStartFreshCounters() throws {
        let a = history(), b = history()
        a.record(account, title: "Account"); exchange(a, b)
        try a.clear()
        b.record(account, title: "Offline visit")
        let offline = b.snapshot
        exchange(a, b)
        XCTAssertTrue(a.entries.isEmpty); XCTAssertTrue(b.entries.isEmpty)
        a.merge(offline); XCTAssertTrue(a.entries.isEmpty)
        b.record(account, title: "A new visit"); exchange(a, b)
        XCTAssertEqual(a.entries.first?.visits, 1)
        try b.save()
        let reopened = BrowsingHistory(storageURL: b.storageURL)
        reopened.merge(offline)
        XCTAssertEqual(reopened.entries.first?.visits, 1)
    }
    func testIndividualRemovalKeepsOtherPagesAndCannotBeUndoneByAnOfflineDevice() {
        let a = history(), b = history()
        for _ in 0..<8 { a.record(account, title: "Account") }
        a.record(home, title: "Home"); exchange(a, b)
        XCTAssertTrue(a.remove(account))
        b.record(account, title: "Offline"); exchange(a, b)
        XCTAssertEqual(a.entries.map(\.url), [home.absoluteString])
        XCTAssertEqual(b.entries.map(\.url), [home.absoluteString])
        let deletion = a.snapshot
        b.record(account, title: "Opened again"); exchange(a, b)
        a.merge(deletion)
        XCTAssertEqual(a.entries.first { $0.url == account.absoluteString }?.visits, 1)
    }
    func testCloudConflictsAndLateAcknowledgementsKeepNewerVisitsPending() throws {
        let a = history(), b = history()
        a.record(account, title: "Account"); b.record(account, title: "Account")
        var cloudA = SharedHistorySyncState(), cloudB = SharedHistorySyncState()
        _ = cloudA.capture(a.snapshot); _ = cloudB.capture(b.snapshot)
        let id = SharedHistoryRecord.id(for: account.absoluteString)
        let firstSave = try XCTUnwrap(cloudA.payload(for: id))
        a.record(account, title: "Second local visit"); _ = cloudA.capture(a.snapshot)
        cloudA.receive(firstSave, id: id, fields: Data())
        XCTAssertTrue(cloudA.dirtyIDs.contains(id), "An older save cannot acknowledge the newer counter")
        let otherSave = try XCTUnwrap(cloudB.payload(for: id))
        cloudA.receive(otherSave, id: id, fields: Data())
        XCTAssertTrue(cloudA.dirtyIDs.contains(id))
        let mergedSave = try XCTUnwrap(cloudA.payload(for: id))
        cloudB.receive(mergedSave, id: id, fields: Data())
        cloudA.receive(mergedSave, id: id, fields: Data())
        XCTAssertFalse(cloudA.dirtyIDs.contains(id)); XCTAssertFalse(cloudB.dirtyIDs.contains(id))
        a.merge(cloudA.snapshot); b.merge(cloudB.snapshot)
        XCTAssertEqual(a.entries.first?.visits, 3); XCTAssertEqual(a.snapshot, b.snapshot)
    }
    func testClearAndPagePacketsConvergeInEitherArrivalOrder() throws {
        let a = history()
        a.record(account, title: "Old")
        var old = SharedHistorySyncState(); _ = old.capture(a.snapshot)
        let id = SharedHistoryRecord.id(for: account.absoluteString)
        let stale = try XCTUnwrap(old.payload(for: id))
        try a.clear(); a.record(account, title: "New")
        var current = SharedHistorySyncState(); _ = current.capture(a.snapshot)
        let clear = try XCTUnwrap(current.payload(for: SharedHistorySyncState.clearID))
        let page = try XCTUnwrap(current.payload(for: id))
        for packets in [[(id, stale), (SharedHistorySyncState.clearID, clear), (id, page)],
                        [(id, page), (id, stale), (SharedHistorySyncState.clearID, clear)]] {
            var receiver = SharedHistorySyncState()
            for (name, data) in packets { receiver.receive(data, id: name, fields: Data()) }
            XCTAssertEqual(receiver.snapshot, a.snapshot)
            XCTAssertEqual(receiver.snapshot.entries.first?.visits, 1)
        }
    }
    func testRemoteDataIsValidatedAndEachPageFitsCloudKitsRecordLimit() throws {
        let a = history()
        let long = URL(string: "https://example.com/"+String(repeating: "x", count: 15_000))!
        a.record(long, title: String(repeating: "🚀", count: 512))
        var state = SharedHistorySyncState(); _ = state.capture(a.snapshot)
        let id = try XCTUnwrap(state.snapshot.records.keys.first), original = state.snapshot
        XCTAssertLessThan(try XCTUnwrap(state.payload(for: id)).count, 200_000)
        for badURL in ["file:///private/data", "javascript:alert(1)", "https://user:password@example.com/", "https://EXAMPLE.com/"] {
            var bad = try XCTUnwrap(original.records[id]); bad.url = badURL
            XCTAssertFalse(state.receive(try JSONEncoder().encode(bad), id: bad.id, fields: Data()))
            XCTAssertEqual(state.snapshot, original)
        }
        var bad = try XCTUnwrap(original.records[id]); bad.counts = [UUID(): -1]
        XCTAssertFalse(state.receive(try JSONEncoder().encode(bad), id: id, fields: Data()))
        XCTAssertFalse(state.receive(Data(repeating: 0, count: 200_001), id: id, fields: Data()))
        XCTAssertEqual(state.snapshot, original)
    }
    @MainActor func testSyncSwitchPreservesLocalLearningAndCacheRestoresItWithoutNetwork() throws {
        let a = history(), b = history()
        let suite = "RiseVisitSync-\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let cache = a.storageURL.deletingLastPathComponent().appendingPathComponent("sync.json")
        let sync = SharedTabsSync(cacheURL: cache, preferences: preferences, cloudAvailable: false)
        sync.start(tabs: [], browsingHistory: a)
        a.record(account, title: "Account"); sync.flush()
        let restarted = SharedTabsSync(cacheURL: cache, preferences: preferences, cloudAvailable: false)
        restarted.start(tabs: [], browsingHistory: b)
        XCTAssertEqual(b.entries.first?.visits, 1)
        restarted.setEnabled(false)
        b.record(account, title: "Offline local visit"); restarted.flush()
        XCTAssertEqual(b.entries.first?.visits, 2)
        XCTAssertFalse(restarted.isEnabled)
        restarted.setEnabled(true)
        XCTAssertEqual(b.entries.first?.visits, 2)
        try b.clear(); restarted.flush()
        let cleared = history()
        let relaunched = SharedTabsSync(cacheURL: cache, preferences: preferences, cloudAvailable: false)
        relaunched.start(tabs: [], browsingHistory: cleared)
        XCTAssertTrue(cleared.entries.isEmpty)
        XCTAssertGreaterThan(cleared.snapshot.clearedAt.clock, 0)
    }
}
