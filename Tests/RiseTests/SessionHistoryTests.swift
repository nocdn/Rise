import XCTest
import AppKit
import WebKit
import RiseCore
@testable import Rise

/// Tabs come back after a relaunch with the pages they could go back and forward to.
final class SessionHistoryTests: XCTestCase {
    @MainActor func wait(_ condition: () -> Bool, _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), message)
    }
    @MainActor func testBackAndForwardHistorySurvivesRelaunch() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = try ["first", "second", "third"].map { name in
            let url = folder.appendingPathComponent("\(name).html")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "<title>\(name)</title><h1>\(name)</h1>".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let session = folder.appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false)
        let tab = browser.addTab(url: pages[0])
        wait({ tab.webView.url == pages[0] && !tab.webView.isLoading }, "The first page loads")
        for page in pages.dropFirst() {
            tab.webView.loadFileURL(page, allowingReadAccessTo: folder)
            wait({ tab.webView.url == page && !tab.webView.isLoading }, "\(page.lastPathComponent) loads")
        }
        tab.webView.goBack()
        wait({ tab.webView.url == pages[1] && !tab.webView.isLoading }, "Going back lands on the second page")
        browser.saveNow()
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
        XCTAssertNotNil(try SessionStorage.read(from: session)?.tabs.first?.sessionState)

        let relaunched = BrowserController(sessionURL: session, restore: true)
        defer { relaunched.saveWork?.cancel(); relaunched.tabs.forEach { $0.webView.stopLoading() }; relaunched.window?.orderOut(nil) }
        let restored = try XCTUnwrap(relaunched.tabs.first)
        wait({ restored.webView.url == pages[1] && !restored.webView.isLoading }, "The tab reopens on the page it was showing")
        XCTAssertEqual(restored.webView.backForwardList.backList.map(\.url), [pages[0]])
        XCTAssertEqual(restored.webView.backForwardList.forwardList.map(\.url), [pages[2]])
        restored.webView.goBack()
        wait({ restored.webView.url == pages[0] && !restored.webView.isLoading }, "Back still works after relaunch")
    }
}
