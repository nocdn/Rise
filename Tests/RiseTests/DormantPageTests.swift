import XCTest
import AppKit
import RiseCore
@testable import Rise

final class DormantPageTests: XCTestCase {
    @MainActor func testAWaitingTabWakesInPlaceWithItsHistoryAndTheBrowsersSetUp() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let dormant = DormantPage(), tab = BrowserTab(saved: SavedTab(url: "http://127.0.0.1/a", title: "A"), page: dormant)
        var woke = 0; tab.onWake = { woke += 1 }
        dormant.view.frame = NSRect(x: 10, y: 20, width: 300, height: 200); dormant.isCovered = true
        host.addSubview(NSView()); host.addSubview(dormant.view); host.addSubview(NSView())
        XCTAssertTrue(tab.isDormant); XCTAssertEqual(tab.url?.absoluteString, "http://127.0.0.1/a")

        tab.load(URL(string: "http://127.0.0.1/a")!)
        XCTAssertFalse(tab.isDormant); XCTAssertEqual(woke, 1)
        XCTAssertNil(dormant.view.superview)
        XCTAssertTrue(host.subviews[1] === tab.page.view, "The page takes the stand-in's place among its siblings")
        XCTAssertEqual(tab.page.view.frame, NSRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertTrue(tab.page.isCovered)
        XCTAssertEqual(tab.page.url?.absoluteString, "http://127.0.0.1/a")
        // A stand-in asked to go somewhere itself, as by a script, wakes its tab too.
        let other = DormantPage(), second = BrowserTab(saved: SavedTab(url: "http://127.0.0.1/b", title: "B"), page: other)
        other.load(URL(string: "http://127.0.0.1/c")!)
        XCTAssertFalse(second.isDormant); XCTAssertEqual(second.url?.absoluteString, "http://127.0.0.1/c")
    }

    @MainActor func testAnIdleHoverPageStaysClosedUntilTheNextHover() async throws {
        let inbox = GmailInbox(), host = NSView()
        defer { inbox.tearDown() }
        var loads = 0
        inbox.loadPage = { _, _ in loads += 1; return GmailPage(emails: [GmailEmail(id: "a", sender: "S", subject: "T", preview: "P", unread: true)], hasMore: false) }
        let account = try XCTUnwrap(GmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/#inbox")))
        let source = BlankPage()
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while inbox.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        }
        inbox.prepare(account: account, category: .primary, source: source, host: host, refreshAfter: 0, background: true)
        try await settle(); XCTAssertEqual(loads, 1)
        inbox.releasePage()
        inbox.prepare(account: account, category: .primary, source: source, host: host, refreshAfter: 0, background: true)
        try await settle()
        XCTAssertEqual(loads, 1, "A tab's changes don't bring a closed page back")
        XCTAssertEqual(inbox.emails.map(\.id), ["a"], "What it read stays for the card")
        inbox.prepare(account: account, category: .primary, source: source, host: host, refreshAfter: 0)
        try await settle()
        XCTAssertEqual(loads, 2, "A hover opens it again and reads")
    }
}
