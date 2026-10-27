import XCTest
import AppKit
@testable import Rise

final class OpenTabLinksTests: XCTestCase {
    @MainActor func testARequestOpenOnAnyOfItsPagesIsGoneToButNotFromItsOwnPages() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.page.stopLoading() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        }
        let mergeRequest = browser.addTab(url: URL(string: "https://gitlab.example.com/group/app/-/merge_requests/7/pipelines")!)
        let pullRequest = browser.addTab(url: URL(string: "https://github.com/owner/repo/pull/3/files")!)
        let source = browser.addTab(url: URL(string: "https://example.com/")!)
        browser.tabs.forEach { $0.page.stopLoading() }

        XCTAssertEqual(Set(browser.linksOpenElsewhere(than: source.page).requests),
                       ["https://gitlab.example.com/group/app/-/merge_requests/7", "https://github.com/owner/repo/pull/3"])
        browser.select(source.id)
        browser.goToOpenTab(URL(string: "https://gitlab.example.com/group/app/-/merge_requests/7")!, from: source.page)
        XCTAssertEqual(browser.selectedID, mergeRequest.id)
        XCTAssertEqual(mergeRequest.url?.lastPathComponent, "pipelines")
        browser.goToOpenTab(URL(string: "https://github.com/owner/repo/pull/3")!, from: source.page)
        XCTAssertEqual(browser.selectedID, pullRequest.id)

        // In another tab of the same request, its own pages' links behave as usual.
        let sameRequest = browser.addTab(url: URL(string: "https://github.com/owner/repo/pull/3")!)
        sameRequest.page.stopLoading()
        let open = browser.linksOpenElsewhere(than: sameRequest.page)
        XCTAssertFalse(open.requests.contains("https://github.com/owner/repo/pull/3"))
        XCTAssertFalse(open.links.contains("https://github.com/owner/repo/pull/3/files"))
    }
}
