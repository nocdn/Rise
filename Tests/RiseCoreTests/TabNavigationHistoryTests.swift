import XCTest
@testable import RiseCore

final class TabNavigationHistoryTests: XCTestCase {
    private func history(_ paths: [String] = ["a", "b", "c"], index: Int = 1) -> TabNavigationHistory {
        .init(entries: paths.map { .init(url: "https://example.com/\($0)", title: $0) }, index: index)
    }

    func testValidationPreservesRepeatedVisitsAndTheCursorWhileRemovingUnsafeEntries() {
        let value = history(["a", "a", "c"])
        XCTAssertEqual(value.validated(), value)
        var mixed = value
        mixed.entries.insert(.init(url: "file:///private/document"), at: 0); mixed.index += 1
        mixed.entries.append(.init(url: "javascript:alert(1)"))
        mixed.entries.append(.init(url: "https://user:password@example.com/"))
        XCTAssertEqual(mixed.validated(), value)
        mixed.index = 0
        XCTAssertNil(mixed.validated())
        mixed.index = Int.max
        XCTAssertNil(mixed.validated())
        XCTAssertNil(value.validated(for: "https://example.com/wrong"))
    }

    func testBoundedWindowRetainsBothDirectionsAroundTheSelectedPage() throws {
        let full = history((0..<300).map(String.init), index: 125)
        let value = try XCTUnwrap(full.validated())
        XCTAssertEqual(value.entries.count, 100)
        XCTAssertEqual(value.index, 50)
        XCTAssertEqual(value.current, full.current)
        XCTAssertEqual(value.entries.first?.url, "https://example.com/75")
        XCTAssertEqual(value.entries.last?.url, "https://example.com/174")
    }

    func testLargeEscapedHistoryStaysBelowTheCloudRecordBudget() throws {
        let url = "https://example.com/"+String(repeating: "/", count: 8000)
        let full = TabNavigationHistory(entries: (0..<100).map { .init(url: url+String($0), title: String(repeating: "\n", count: 512)) }, index: 50)
        let value = try XCTUnwrap(full.validated())
        XCTAssertEqual(value.current, full.current)
        XCTAssertGreaterThan(value.index, 0)
        XCTAssertLessThan(value.index, value.entries.count-1)
        XCTAssertLessThan(value.entries.count, full.entries.count)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(value).count, TabNavigationHistory.maximumEncodedBytes)
    }

    func testCombiningHeldPagesDropsTheirAbandonedBranchesAndRetainsForwardPages() throws {
        let back = history(["a", "b", "abandoned"], index: 1)
        let current = history(["c", "d", "e"], index: 1)
        let forward = history(["old", "f", "g"], index: 1)
        let value = try XCTUnwrap(TabNavigationHistory.combining(back: [back], current: current, forward: [forward]))
        XCTAssertEqual(value.entries.map(\.url), ["a", "b", "c", "d", "e", "f", "g"].map { "https://example.com/\($0)" })
        XCTAssertEqual(value.index, 3)
        XCTAssertNil(TabNavigationHistory.combining(back: [], current: .init(entries: [], index: Int.max)))
    }

    func testOldRecordsDecodeWithoutHistoryAndMalformedHistoryDoesNotLoseTheTab() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"url\":\"https://example.com/b\",\"title\":\"B\"}".utf8)
        let value = try JSONDecoder().decode(SharedBrowserTab.self, from: data)
        XCTAssertNil(value.navigationHistory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["navigationHistory"] = ["entries": [["url":"https://example.com/b"]], "index": 99]
        let restored = try JSONDecoder().decode(SharedBrowserTab.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, value)
    }

    func testHistoryChangesSyncEvenWhenTheCurrentURLDoesNotChangeAndFreshClientsRecoverTheCursor() throws {
        let id = UUID(), url = "https://example.com/a"
        let first = SharedBrowserTab(id: id, url: url, title: "A", navigationHistory: history(["a", "b", "a"], index: 0))
        var a = SharedTabsLedger(); _ = a.capture([first])
        var changed = first; changed.navigationHistory = history(["a", "b", "a"], index: 2)
        XCTAssertEqual(a.capture([changed]), [id])
        var fresh = SharedTabsLedger()
        for record in a.records.values { fresh.merge(record) }
        XCTAssertEqual(fresh.tabs, [changed])
        let decoded = try JSONDecoder().decode(SharedTabsLedger.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded.tabs.first?.navigationHistory?.index, 2)
        XCTAssertEqual(decoded.tabs.first?.navigationHistory?.entries.count, 3)
        fresh.observedTabs = fresh.tabs
        XCTAssertTrue(fresh.capture(fresh.tabs).isEmpty, "Receiving history must not create another navigation")
    }

    func testLegacyTitleUpdatesPreserveKnownHistoryInEitherMergeOrder() throws {
        let id = UUID()
        let tab = SharedBrowserTab(id: id, url: "https://example.com/b", title: "B", navigationHistory: history())
        var ledger = SharedTabsLedger(); _ = ledger.capture([tab])
        let original = try XCTUnwrap(ledger.records[id])
        var legacy = original
        legacy.tab.navigationHistory = nil; legacy.tab.title = "Updated title"
        legacy.contentVersion = .init(clock: original.contentVersion.clock+1, device: UUID())
        XCTAssertEqual(original.merging(legacy), legacy.merging(original))
        XCTAssertEqual(original.merging(legacy).tab.navigationHistory, tab.navigationHistory)
        legacy.tab.url = "https://example.com/elsewhere"
        XCTAssertNil(original.merging(legacy).tab.navigationHistory, "History from another destination must not be attached")
    }

    func testClosingATabStillWinsOverAnOfflineHistoryEdit() {
        let id = UUID(), first = SharedBrowserTab(id: id, url: "https://example.com/b", title: "B", navigationHistory: history())
        var a = SharedTabsLedger(); _ = a.capture([first])
        var b = a; b.deviceID = UUID()
        _ = a.capture([])
        var changed = first; changed.navigationHistory = history(["a", "b", "new"], index: 1)
        _ = b.capture([changed])
        for record in b.records.values { a.merge(record) }
        for record in a.records.values { b.merge(record) }
        XCTAssertTrue(a.tabs.isEmpty); XCTAssertTrue(b.tabs.isEmpty)
    }
    /// The bound that lets most histories skip being encoded is never below what encoding gives,
    /// whatever the text needs escaped.
    func testTheEncodedSizeBoundIsNeverBelowTheEncodedSize() throws {
        let awkward = "\u{01}\"\\/\n\t\u{1F}é漢😀<>&"
        let value = TabNavigationHistory(entries: (0..<40).map { .init(url: "https://e.example/\($0)?q=" + awkward, title: awkward + "\($0)") }, index: 3)
        XCTAssertGreaterThanOrEqual(value.mostEncodedBytes, try JSONEncoder().encode(value).count)
    }
}
