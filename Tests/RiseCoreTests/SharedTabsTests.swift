import XCTest
@testable import RiseCore

final class SharedTabsTests: XCTestCase {
    private func tab(_ name: String) -> SharedBrowserTab {
        SharedBrowserTab(id: UUID(), url: "https://example.com/\(name)", title: name)
    }
    private func exchange(_ a: inout SharedTabsLedger, _ b: inout SharedTabsLedger) {
        let left = Array(a.records.values), right = Array(b.records.values)
        for record in right { a.merge(record) }
        for record in left { b.merge(record) }
    }

    func testConcurrentMoveAndNavigationMergeIndependently() {
        let one = tab("one"), two = tab("two")
        var a = SharedTabsLedger(); _ = a.capture([one, two])
        var b = a; b.deviceID = UUID()
        _ = a.capture([two, one])
        var changed = one; changed.url = "https://example.com/new"; changed.title = "New page"
        _ = b.capture([changed, two])
        exchange(&a, &b)
        XCTAssertEqual(a.tabs, b.tabs)
        XCTAssertEqual(a.tabs.map(\.id), [two.id, one.id])
        XCTAssertEqual(a.tabs.last?.url, changed.url)
    }

    func testCloseWinsOverLaterOfflineEditsAndSurvivesRelaunch() throws {
        let one = tab("one"), two = tab("two")
        var a = SharedTabsLedger(); _ = a.capture([one, two])
        var b = a; b.deviceID = UUID()
        _ = a.capture([two])
        b.clock += 100_000
        var edited = one; edited.title = "Offline edit"; _ = b.capture([edited, two])
        exchange(&a, &b)
        XCTAssertEqual(a.tabs, [two]); XCTAssertEqual(b.tabs, [two])
        var restored = try JSONDecoder().decode(SharedTabsLedger.self, from: JSONEncoder().encode(b))
        _ = restored.capture([edited, two])
        XCTAssertEqual(restored.tabs, [two], "A stale local session cannot resurrect a closed tab")
    }

    func testUnappliedRemoteInsertIsNotMistakenForALocalClose() {
        let one = tab("one"), remote = tab("remote")
        var local = SharedTabsLedger(); _ = local.capture([one])
        var other = local; other.deviceID = UUID(); _ = other.capture([one, remote])
        for record in other.records.values { local.merge(record) }
        var edit = one; edit.title = "Changed locally"
        _ = local.capture([edit])
        XCTAssertEqual(Set(local.tabs.map(\.id)), [one.id, remote.id])
        XCTAssertNil(local.records[remote.id]?.closedAt)
    }

    func testConcurrentInsertsConvergeAndAcknowledgmentDoesNotEcho() {
        let one = tab("one"), left = tab("left"), right = tab("right")
        var a = SharedTabsLedger(); _ = a.capture([one])
        var b = a; b.deviceID = UUID()
        _ = a.capture([one, left]); _ = b.capture([one, right]); exchange(&a, &b)
        XCTAssertEqual(a.tabs, b.tabs)
        XCTAssertEqual(Set(a.tabs.map(\.id)), [one.id, left.id, right.id])
        a.observedTabs = a.tabs
        XCTAssertTrue(a.capture(a.tabs).isEmpty)
    }

    func testEqualClockConflictsAreDeterministicAndMergeIsIdempotent() {
        var a = SharedTabsLedger(); let one = tab("one"); _ = a.capture([one])
        var first = a.records[one.id]!, second = first
        first.tab.title = "A"; second.tab.title = "B"
        first.contentVersion = .init(clock: 42, device: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        second.contentVersion = .init(clock: 42, device: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertEqual(first.merging(second), second.merging(first))
        XCTAssertEqual(first.merging(second).tab.title, "B")
        XCTAssertEqual(first.merging(first), first)
    }

    func testLocalFilesAndExecutableURLsDoNotEnterTheSharedList() {
        var ledger = SharedTabsLedger()
        let normal = tab("normal"), blank = SharedBrowserTab(id: UUID(), url: nil, title: nil)
        _ = ledger.capture([normal, blank, .init(id: UUID(), url: "file:///private/file", title: "File"),
                            .init(id: UUID(), url: "javascript:alert(1)", title: "Script")])
        XCTAssertEqual(ledger.tabs, [normal, blank])
    }

    func testRemoteClosureKeepsOnlyTheLocallyActiveTabWithoutResurrectingIt() throws {
        let one = tab("one"), active = tab("active"), three = tab("three"), added = tab("added")
        var local = SharedTabsLedger(); _ = local.capture([one, active, three])
        var remote = local; remote.deviceID = UUID()
        _ = remote.capture([added])
        exchange(&local, &remote)
        let displayed = SharedTabsReconciliation.preservingActiveTab(in: local.tabs, displayed: local.observedTabs, activeID: active.id)
        XCTAssertEqual(displayed, [added, active])
        local.observedTabs = displayed
        XCTAssertTrue(local.capture(displayed).isEmpty, "Retaining the active tab must not send an edit or new tab")
        exchange(&local, &remote)
        XCTAssertEqual(local.tabs, [added]); XCTAssertEqual(remote.tabs, [added])
        var restored = try JSONDecoder().decode(SharedTabsLedger.self, from: JSONEncoder().encode(local))
        let afterRelaunch = SharedTabsReconciliation.preservingActiveTab(in: restored.tabs, displayed: displayed, activeID: active.id)
        XCTAssertEqual(afterRelaunch, displayed)
        XCTAssertTrue(restored.capture(afterRelaunch).isEmpty)
        XCTAssertNotNil(restored.records[active.id]?.closedAt)
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: restored.tabs, displayed: displayed, activeID: added.id), [added])
    }

    func testRemoteCloseAllKeepsEachDevicesOwnActivePage() {
        let one = tab("one"), two = tab("two"), three = tab("three")
        let displayed = [one, two, three]
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: [], displayed: displayed, activeID: one.id), [one])
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: [], displayed: displayed, activeID: three.id), [three])
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: [two, one], displayed: displayed, activeID: one.id), [two, one], "An existing active tab keeps the incoming order without duplication")
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: [], displayed: displayed, activeID: nil), [])
        XCTAssertEqual(SharedTabsReconciliation.preservingActiveTab(in: [], displayed: [], activeID: UUID()), [])
    }
}
