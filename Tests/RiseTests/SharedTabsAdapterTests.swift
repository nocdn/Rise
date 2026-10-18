import XCTest
import AppKit
import RiseCore
@testable import Rise

final class SharedTabsAdapterTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let folder = URL.temporaryDirectory.appendingPathComponent("RiseMacTabSync-\(UUID())")
        let suite = "RiseMacTabSync-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.tabSync = SharedTabsSync(cacheURL: folder.appendingPathComponent("sync.json"), preferences: preferences, cloudAvailable: false)
        addTeardownBlock { @MainActor in
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.window?.orderOut(nil); browser.tabSync?.flush()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }

    @MainActor func testRemoteInsertAndMovePreserveSelectionAndLocalMetadata() {
        let browser = browser(), a = browser.addTab(), b = browser.addTab()
        a.pinned = true; a.rename("Personal name"); a.developer = true
        let c = SharedBrowserTab(id: UUID(), url: nil, title: "From iPhone")
        browser.applySharedTabs([c, .init(id: b.id, url: nil, title: "B"), .init(id: a.id, url: nil, title: "Remote name")])
        // Pinned tabs stay first, wherever the other device has them.
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(browser.selectedID, b.id)
        XCTAssertTrue(browser.tabs[0] === a)
        XCTAssertTrue(a.pinned); XCTAssertTrue(a.developer)
        XCTAssertEqual(a.customTitle, "Personal name")
        XCTAssertEqual(a.title, "Personal name")
        XCTAssertNil(browser.tabs[1].page.url, "Unselected remote tabs stay unloaded")
    }

    @MainActor func testRemoteCloseKeepsTheActivePageAndLocalFiles() {
        let browser = browser(), a = browser.addTab(), b = browser.addTab()
        let file = browser.configure(BrowserTab(saved: .init(url: "file:///tmp/Rise-local-document.html", title: "Local file")))
        browser.tabs.append(file)
        browser.applySharedTabs([.init(id: a.id, url: nil, title: "A")])
        XCTAssertEqual(browser.tabs.map(\.id), [b.id, a.id, file.id])
        XCTAssertTrue(browser.tabs.contains { $0 === b })
        XCTAssertTrue(browser.tabs.contains { $0 === file })
        XCTAssertEqual(browser.selectedID, b.id)
        XCTAssertEqual(browser.sharedTabsSnapshot.map(\.id), [b.id, a.id])
        browser.select(a.id)
        browser.applySharedTabs([.init(id: a.id, url: nil, title: "A")])
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, file.id], "The previously active page can close once it is in the background")
    }

    @MainActor func testClosingAllRemoteTabsPreservesTheActivePageAcrossSyncAndRelaunch() throws {
        let browser = browser(), a = browser.addTab(), b = browser.addTab()
        browser.tabSync?.start(tabs: browser.sharedTabsSnapshot)
        let page = b.page
        browser.tabSync?.capture([])
        for _ in 0..<3 { browser.applySharedTabs([]) }
        XCTAssertEqual(browser.tabs.map(\.id), [b.id])
        XCTAssertEqual(browser.selectedID, b.id)
        XCTAssertTrue(browser.selectedTab?.page === page)
        XCTAssertTrue(browser.tabSync!.isClosed(a.id)); XCTAssertTrue(browser.tabSync!.isClosed(b.id))
        XCTAssertTrue(browser.tabSync!.tabs.isEmpty, "Keeping the page local must not reopen remotely closed tabs")
        browser.saveNow()
        let session = try XCTUnwrap(SessionStorage.read(from: browser.sessionURL))
        XCTAssertEqual(session.tabs.map(\.id), [b.id])
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.saveWork?.cancel(); restored.tabs.forEach { $0.cancelLoad() } }
        restored.applySharedTabs([])
        XCTAssertEqual(restored.selectedID, b.id)
        XCTAssertEqual(restored.tabs.map(\.id), [b.id])
        browser.closeTab(b.id)
        XCTAssertFalse(browser.tabs.contains { $0.id == b.id }, "A deliberate local close still works")
    }

    @MainActor func testDeferredUpdateUsesTheLatestListAndReopeningCreatesANewIdentity() {
        let browser = browser(), a = browser.addTab(), b = browser.addTab()
        browser.tabSync?.start(tabs: browser.sharedTabsSnapshot)
        browser.showPalette(text: "")
        let first = [SharedBrowserTab(id: a.id, url: nil, title: "First update")]
        browser.tabSync?.capture(first); browser.applySharedTabs(first)
        XCTAssertEqual(browser.tabs.map(\.id), [b.id, a.id])
        XCTAssertTrue(browser.hasPendingSharedTabs)
        let latest = [SharedBrowserTab(id: a.id, url: nil, title: "Latest update")]
        browser.tabSync?.capture(latest)
        browser.hidePalette(); browser.applyPendingSharedTabs()
        XCTAssertEqual(browser.tabs.map(\.id), [b.id, a.id])
        XCTAssertEqual(browser.tabs.first { $0.id == a.id }?.title, "Latest update")
        browser.closeTab(b.id)
        browser.closeTab(a.id)
        XCTAssertTrue(browser.tabSync!.isClosed(a.id))
        browser.reopenTab()
        XCTAssertNotEqual(browser.tabs[0].id, a.id)
        XCTAssertEqual(browser.tabs[0].title, "Latest update")
        XCTAssertEqual(browser.tabSync?.tabs.map(\.id), browser.tabs.map(\.id))
    }
}
