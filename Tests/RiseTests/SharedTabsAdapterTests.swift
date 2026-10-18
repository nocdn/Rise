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

    @MainActor func testRemoteCloseKeepsFilesLocalAndChoosesASurvivingPage() {
        let browser = browser(), a = browser.addTab(), b = browser.addTab()
        let file = browser.configure(BrowserTab(saved: .init(url: "file:///tmp/Rise-local-document.html", title: "Local file")))
        browser.tabs.append(file)
        browser.applySharedTabs([.init(id: a.id, url: nil, title: "A")])
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, file.id])
        XCTAssertFalse(browser.tabs.contains { $0.id == b.id })
        XCTAssertTrue(browser.tabs.contains { $0 === file })
        XCTAssertNotEqual(browser.selectedID, b.id)
        XCTAssertEqual(browser.sharedTabsSnapshot.map(\.id), [a.id])
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
        XCTAssertEqual(browser.tabs.map(\.id), [a.id])
        XCTAssertEqual(browser.tabs[0].title, "Latest update")
        browser.closeTab(a.id)
        XCTAssertTrue(browser.tabSync!.isClosed(a.id))
        browser.reopenTab()
        XCTAssertNotEqual(browser.tabs[0].id, a.id)
        XCTAssertEqual(browser.tabs[0].title, "Latest update")
        XCTAssertEqual(browser.tabSync?.tabs.map(\.id), browser.tabs.map(\.id))
    }
}
