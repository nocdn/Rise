import XCTest
import AppKit
import RiseCore
@testable import Rise

final class FaviconPersistenceTests: XCTestCase {
    @MainActor private func icon(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { bounds in
            color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).fill(); return true
        }
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad(); $0.iconTask?.cancel() }; browser.window?.orderOut(nil)
    }
    @MainActor func testSessionRestoresAllIconsIntoSidebarBeforeAnyPageLoadsAndReopenKeepsThem() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), restore: false)
        defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab()
        a.requestedURL = URL(string: "https://example.com/path")
        b.requestedURL = URL(string: "https://other.example:8443/page")
        for (tab, color) in [(a, NSColor.systemRed), (b, NSColor.systemBlue)] {
            tab.iconOrigin = SitePermissions.origin(tab.url); tab.favicon = icon(color)
        }
        browser.addTab(); browser.update(); browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { clean(restored) }
        XCTAssertEqual(restored.tabs.map(\.saved), browser.tabs.map(\.saved))
        for original in [a, b] {
            let tab = try XCTUnwrap(restored.tabs.first { $0.id == original.id })
            XCTAssertNotNil(tab.favicon)
            XCTAssertNil(tab.page.url); XCTAssertFalse(tab.hasAttemptedNavigation)
            XCTAssertNil(tab.iconTask, "A saved favicon requires no network fetch to appear")
            XCTAssertTrue(restored.sidebar.rows[tab.id]?.icon.image === tab.favicon)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tab.saved.faviconData!))
            XCTAssertEqual(bitmap.pixelsWide, 32); XCTAssertEqual(bitmap.pixelsHigh, 32)
        }
        restored.closeTab(a.id); restored.reopenTab()
        let reopened = restored.tabs.first { $0.id == a.id }
        XCTAssertEqual(reopened?.saved.faviconData, a.saved.faviconData)
        XCTAssertNotNil(reopened?.favicon)
    }
    @MainActor func testReloadPreservesTheCachedIconButOtherOriginsAndBlankPagesCannotReuseIt() throws {
        _ = NSApplication.shared
        let source = BrowserTab()
        source.requestedURL = URL(string: "https://example.com/page")
        source.iconOrigin = SitePermissions.origin(source.url); source.favicon = icon(.systemGreen)
        let saved = source.saved, restored = BrowserTab(saved: saved)
        restored.changed(); restored.changed()
        XCTAssertEqual(restored.saved.faviconData, saved.faviconData)
        XCTAssertNotNil(restored.favicon); XCTAssertNil(restored.iconTask)
        for address in ["http://example.com/page", "https://example.com:8443/page", "https://different.example/page", "about:blank"] {
            var other = saved; other.url = address
            XCTAssertNil(BrowserTab(saved: other).favicon)
        }
        restored.requestedURL = URL(string: "about:blank"); restored.updateIcon()
        XCTAssertNil(restored.favicon); XCTAssertNil(restored.saved.faviconData)
    }
    @MainActor func testInvalidOrOversizedIconsDoNotPreventRestoringTheTab() throws {
        _ = NSApplication.shared
        for data in [Data("not an image".utf8), Data(repeating: 0, count: FaviconSnapshot.maximumBytes+1)] {
            let tab = BrowserTab(saved: SavedTab(url: "https://example.com", title: "Saved title", faviconData: data, faviconOrigin: "https://example.com:443"))
            XCTAssertEqual(tab.title, "Saved title"); XCTAssertNil(tab.favicon); XCTAssertNil(tab.saved.faviconData)
        }
    }
}
