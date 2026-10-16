import XCTest
import AppKit
@testable import Rise

final class GmailTooltipTests: XCTestCase {
    private func account(_ number: Int = 0) -> GmailAccount {
        GmailAccount(url: URL(string: "https://mail.google.com/mail/u/\(number)/#inbox"))!
    }
    private func email(_ id: String, preview: String = "The beginning of the email.") -> GmailEmail {
        GmailEmail(id: id, sender: "Google", subject: "Account notification", preview: preview)
    }
    @MainActor private func wait(until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    func testAccountAndCategoryURLsNeverMixAccounts() {
        XCTAssertNil(GmailAccount(url: URL(string: "https://mail.google.com.evil.test/mail/u/0/")))
        XCTAssertNil(GmailAccount(url: URL(string: "https://mail.google.com/chat/")))
        XCTAssertEqual(account(2).baseURL.absoluteString, "https://mail.google.com/mail/u/2/")
        XCTAssertEqual(account(2).searchURL(category: .updates, page: 2).fragment?.removingPercentEncoding, "search/in:inbox category:updates/p2")
        XCTAssertEqual(account().searchURL(category: .all, page: 1).fragment?.removingPercentEncoding, "search/in:inbox")
        let auth = GmailAccount(url: URL(string: "https://mail.google.com/mail/?authuser=person@example.com#inbox"))!
        XCTAssertEqual(URLComponents(url: auth.searchURL(category: .primary, page: 1), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "person@example.com")
        XCTAssertEqual(account(2).messageURL(id: "abcdef")?.absoluteString, "https://mail.google.com/mail/u/2/#inbox/abcdef")
        XCTAssertNil(account().messageURL(id: "x/compose"))
        XCTAssertEqual(account(1).listURL(category: .updates).absoluteString, "https://mail.google.com/mail/u/1/#category/updates")
        XCTAssertEqual(account().listURL(category: .primary).fragment, "inbox")
        XCTAssertEqual(account().listURL(category: .all).fragment, "inbox")
        XCTAssertEqual(account().listURL(category: .updates, page: 3).fragment, "category/updates/p3")
        XCTAssertTrue(GmailAccount.isPopout(URL(string: "https://mail.google.com/mail/u/0/popout?ver=1&th=%23thread-f%3A1&cvid=1")))
        XCTAssertTrue(GmailAccount.isPopout(URL(string: "https://mail.google.com/mail/popout?th=x")))
        XCTAssertFalse(GmailAccount.isPopout(URL(string: "https://mail.google.com/mail/u/0/#inbox")))
        XCTAssertFalse(GmailAccount.isPopout(URL(string: "https://mail.google.com.evil.test/mail/u/0/popout")))
        XCTAssertEqual(GmailPageReader.route(URL(string: "https://mail.google.com/mail/u/0/#search/in%3Ainbox+category%3Aupdates")),
                       GmailPageReader.route(account().searchURL(category: .updates, page: 1)))
    }
    @MainActor func testPaginationDeduplicatesAndRejectsAnOldCategoryResponse() async throws {
        let inbox = GmailInbox()
        defer { inbox.tearDown() }
        var requests: [(GmailCategory, Int)] = []
        inbox.loadPage = { request, page in
            requests.append((request.category, page))
            try? await Task.sleep(for: .milliseconds(request.category == .promotions ? 150 : 30))
            if request.category == .promotions { return GmailPage(emails: [self.email("bad")], hasMore: false) }
            return GmailPage(emails: page == 1 ? [self.email("a")] : [self.email("a"), self.email("b")], hasMore: page == 1)
        }
        inbox.show(.init(account: account(), category: .updates))
        XCTAssertTrue(inbox.isLoading)
        inbox.loadMore()
        try await wait { !inbox.isLoading }
        XCTAssertEqual(requests.count, 1, "Loading is coalesced")
        XCTAssertEqual(inbox.emails.map(\.id), ["a"])
        inbox.loadMore(); try await wait { !inbox.isLoading }
        XCTAssertEqual(inbox.emails.map(\.id), ["a", "b"])
        XCTAssertFalse(inbox.hasMore)
        inbox.show(.init(account: account(), category: .promotions))
        try await Task.sleep(for: .milliseconds(20))
        inbox.show(.init(account: account(1), category: .social))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(inbox.request?.account, account(1))
        XCTAssertEqual(inbox.emails.map(\.id), ["a"], "Late mail from the old account/category is discarded")
    }
    @MainActor func testLoadingFooterScrollPaginationAndRetry() async throws {
        _ = NSApplication.shared
        let inbox = GmailInbox(), card = GmailTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(); inbox.tearDown(); window.orderOut(nil) }
        var failSecondPage = true
        inbox.loadPage = { _, page in
            try await Task.sleep(for: .milliseconds(80))
            if page == 2, failSecondPage { throw GmailPageReader.Failure.unavailable }
            return GmailPage(emails: page == 1 ? (0..<12).map { self.email(String($0, radix: 16)) } : [self.email("ff")], hasMore: page == 1)
        }
        inbox.onChange = { card.update(inbox) }
        card.onLoadMore = { inbox.loadMore() }
        inbox.show(.init(account: account(), category: .updates))
        card.present(key: "test", inbox: inbox, left: 10, anchorTop: 20, maxBottom: 580, theme: .neutral)
        XCTAssertEqual(card.footer.stringValue, "Loading emails")
        XCTAssertTrue(card.shimmer.isRunning)
        try await wait { !inbox.isLoading }
        XCTAssertEqual(card.rows.count, 12)
        XCTAssertEqual(card.scroll.contentView.bounds.minY, 0, accuracy: 0.1, "The first batch opens at the top")
        XCTAssertTrue(card.footer.isHidden)
        XCTAssertFalse(card.shimmer.isRunning)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertLessThanOrEqual(card.frame.height, GmailTooltip.maximumHeight+1)
        card.scroll.contentView.scroll(to: NSPoint(x: 0, y: 100000))
        card.scroll.reflectScrolledClipView(card.scroll.contentView)
        try await wait { inbox.isLoading }
        XCTAssertEqual(card.footer.stringValue, "Loading more emails")
        XCTAssertTrue(card.shimmer.isRunning)
        try await wait { !inbox.isLoading }
        XCTAssertNotNil(inbox.error); XCTAssertFalse(card.shimmer.isRunning)
        XCTAssertEqual(inbox.emails.count, 12, "Paging errors keep existing rows")
        failSecondPage = false; inbox.loadMore(); try await wait { !inbox.isLoading }
        XCTAssertNil(inbox.error); XCTAssertEqual(card.rows.count, 13)
        XCTAssertGreaterThan(card.scroll.contentView.bounds.minY, 0, "Appending keeps the reader's position")
        XCTAssertTrue(card.footer.isHidden)
        XCTAssertEqual(card.scroll.scrollerStyle, .overlay)
        XCTAssertTrue(card.scroll.autohidesScrollers)
        XCTAssertTrue(card.scroll.verticalScroller is GmailScroller)
        let row = card.rows[0]
        XCTAssertGreaterThan(row.sender.font!.pointSize, row.subject.font!.pointSize)
        XCTAssertGreaterThan(row.subject.font!.pointSize, row.preview.font!.pointSize)
        XCTAssertEqual(row.preview.maximumNumberOfLines, 3)
        XCTAssertLessThan(row.preview.textColor!.alphaComponent, 1)
        XCTAssertEqual(row.sender.font, .systemFont(ofSize: 14, weight: .medium))
        XCTAssertEqual(row.subject.font, .systemFont(ofSize: 13, weight: .medium))
        XCTAssertEqual(row.subject.maximumNumberOfLines, 1)
        XCTAssertEqual(row.subject.lineBreakMode, .byTruncatingTail)
        let long = GmailEmailRow(GmailEmail(id: "1", sender: "S", subject: String(repeating: "A long subject ", count: 20), preview: ""))
        long.frame.size = NSSize(width: GmailTooltip.width, height: long.fittingHeight(width: GmailTooltip.width)); long.layout()
        XCTAssertLessThan(long.subject.frame.height, 20, "A long subject stays on one line")
        let full = GmailEmailRow(GmailEmail(id: "2", sender: "Google", subject: "Subject", preview: String(repeating: "The start of a long email. ", count: 20)))
        full.frame.size = NSSize(width: GmailTooltip.width, height: full.fittingHeight(width: GmailTooltip.width)); full.layout()
        XCTAssertGreaterThan(full.preview.frame.height, 40, "A long email shows three lines")
        XCTAssertEqual(full.preview.frame.maxY+GmailEmailRow.bottom, full.bounds.height, accuracy: 0.5, "Rows fit their text")
    }
    @MainActor func testScrollingMovesTheHighlightWithThePointer() async throws {
        _ = NSApplication.shared
        let inbox = GmailInbox(), card = GmailTooltip()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(); inbox.tearDown(); window.orderOut(nil) }
        inbox.loadPage = { _, _ in GmailPage(emails: (0..<12).map { self.email(String($0, radix: 16)) }, hasMore: false) }
        inbox.onChange = { card.update(inbox) }
        inbox.show(.init(account: account(), category: .updates))
        card.present(key: "test", inbox: inbox, left: 10, anchorTop: 20, maxBottom: 580, theme: .neutral)
        try await wait { card.rows.count == 12 }
        // The card's rows only ever highlight the one under the pointer, whatever passed under it while scrolling.
        card.rows.forEach { $0.isHovered = true }
        card.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        card.scroll.reflectScrolledClipView(card.scroll.contentView)
        XCTAssertLessThanOrEqual(card.rows.filter(\.isHovered).count, 1)
    }
    @MainActor func testRefreshKeepsTheListAndHidesTheLoadingRow() async throws {
        let inbox = GmailInbox()
        defer { inbox.tearDown() }
        var round = 0, fail = false
        inbox.loadPage = { _, page in
            try await Task.sleep(for: .milliseconds(30))
            if fail { throw GmailPageReader.Failure.unavailable }
            return GmailPage(emails: page == 1 ? [self.email(round == 0 ? "a" : "new"), self.email("b")] : [self.email("c")], hasMore: true)
        }
        let request = GmailInbox.Request(account: account(), category: .updates)
        inbox.show(request); XCTAssertTrue(inbox.showsLoading)
        try await wait { !inbox.isLoading }
        inbox.loadMore(); XCTAssertTrue(inbox.showsLoading, "A next page shows its loading row")
        try await wait { !inbox.isLoading }
        XCTAssertEqual(inbox.emails.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(inbox.page(of: "c"), 2); XCTAssertEqual(inbox.page(of: "a"), 1)
        inbox.show(request); XCTAssertFalse(inbox.isLoading, "A fresh list isn't loaded again")
        round = 1; inbox.show(request, refreshAfter: 0)
        XCTAssertTrue(inbox.isLoading); XCTAssertFalse(inbox.showsLoading)
        XCTAssertEqual(inbox.emails.count, 3, "The old list stays while refreshing")
        try await wait { !inbox.isLoading }
        XCTAssertEqual(inbox.emails.map(\.id), ["new", "b"])
        fail = true; inbox.show(request, refreshAfter: 0); try await wait { !inbox.isLoading }
        XCTAssertNil(inbox.error); XCTAssertEqual(inbox.emails.map(\.id), ["new", "b"], "A failed refresh keeps the list")
    }
    @MainActor func testCategoryMenuPersistsSelectionWithAllInItsOwnSection() throws {
        _ = NSApplication.shared
        let suite = "Rise.GmailTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(suite).appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer {
            preferences.removePersistentDomain(forName: suite)
            browser.gmailInbox.tearDown(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        }
        XCTAssertEqual(browser.gmailCategory, .updates)
        let menu = try XCTUnwrap(browser.makeMoreSiteMenu().items.first { $0.title == "Gmail Preview Category" }?.submenu)
        XCTAssertEqual(menu.items.first { $0.title == "Updates" }?.state, .on)
        XCTAssertEqual(menu.items.last?.title, "All Categories")
        XCTAssertTrue(menu.items[menu.items.count-2].isSeparatorItem)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Social" })
        (item.representedObject as? MenuAction)?.invoke()
        XCTAssertEqual(browser.gmailCategory, .social)
        XCTAssertEqual(preferences.string(forKey: BrowserController.gmailCategoryKey), "social")
    }
    @MainActor func testGmailHoverUsesTheSharedCardAndClosesOnNavigationAndPress() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); browser.showWindow(nil)
        defer {
            browser.tabPressed(); browser.gmailInbox.tearDown(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        var loads = 0
        browser.gmailInbox.loadPage = { _, _ in loads += 1; return GmailPage(emails: [self.email("abc")], hasMore: false) }
        let tab = browser.addTab()
        tab.requestedURL = account().baseURL; browser.update()
        try await wait { browser.gmailInbox.emails.count == 1 }
        XCTAssertEqual(loads, 1, "An open Gmail tab loads its emails before any hover")
        browser.tabHoverChanged(tab.id, hovering: true)
        try await wait { browser.tabHoverCards.shownID == tab.id }
        XCTAssertEqual(browser.tabHoverCards.gmailCard.rows.count, 1, "The card opens with the preloaded emails")
        XCTAssertTrue(browser.tabHoverCards.gmailCard.footer.isHidden)
        XCTAssertEqual(loads, 1)
        XCTAssertFalse(browser.tabHoverCards.gmailCard.isHidden)
        XCTAssertTrue(browser.tabHoverCards.pullRequestCard.isHidden)
        browser.cardPointerChanged(true)
        XCTAssertTrue(tab.page.isCovered)
        browser.tabPressed()
        XCTAssertNil(browser.tabHoverCards.shownID); XCTAssertTrue(browser.tabHoverCards.gmailCard.isHidden)
        browser.tabHoverChanged(tab.id, hovering: true)
        try await wait { browser.tabHoverCards.shownID == tab.id }
        tab.requestedURL = URL(string: "https://example.com/"); browser.refreshTabHoverCard()
        XCTAssertNil(browser.tabHoverCards.shownID)
    }
}
