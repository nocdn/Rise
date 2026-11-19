import XCTest
import AppKit
@testable import Rise

final class GoogleChatTests: XCTestCase {
    private func conversation(_ id: String, _ message: String, unread: Bool = false) -> ChatConversation {
        ChatConversation(id: id, name: "Matt Rothenberg", message: message, time: Date().timeIntervalSince1970*1000, unread: unread)
    }
    @MainActor func testRowsAreAsTallAsTheirMessageUpToThreeLinesWithADotWhenUnread() {
        let width = GoogleChatTooltip.width
        let rows = [conversation("dm/a", "no problem!", unread: true), conversation("dm/b", String(repeating: "A long message ", count: 40))]
            .map { item -> ChatConversationRow in
                let row = ChatConversationRow(item); row.applyTheme(.neutral, last: false)
                row.frame.size = NSSize(width: width, height: row.fittingHeight(width: width)); row.layoutSubtreeIfNeeded()
                return row
            }
        let line = ceil(NSLayoutManager().defaultLineHeight(for: rows[0].message.font!))
        XCTAssertEqual(rows[0].message.frame.height, line, "A one-line message leaves no space under it")
        XCTAssertEqual(rows[1].message.frame.height, 3*line, "A long message stops at three lines")
        for row in rows { XCTAssertEqual(row.message.frame.maxY+ChatConversationRow.bottom, row.bounds.height, accuracy: 0.5) }
        XCTAssertFalse(rows[0].unreadDot.isHidden)
        XCTAssertTrue(rows[1].unreadDot.isHidden)
        XCTAssertEqual(GoogleChatAccount(url: URL(string: "https://chat.google.com/u/1/app/chat/AAAA"))?.homeURL.absoluteString,
                       "https://chat.google.com/u/1/app/home", "The tab's account is kept")
    }
    @MainActor func testChatTabHoverShowsItsConversations() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); browser.showWindow(nil)
        defer {
            browser.tabPressed(); browser.chatInbox.tearDown(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        browser.chatInbox.loadPage = { _, _ in MailPage(emails: [self.conversation("dm/a", "Done!", unread: true)], hasMore: false) }
        let tab = browser.addTab()
        tab.requestedURL = URL(string: "https://chat.google.com/app/home"); browser.update()
        let deadline = Date().addingTimeInterval(5)
        while browser.chatInbox.emails.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        browser.tabHoverChanged(tab.id, hovering: true)
        while browser.tabHoverCards.shownID != tab.id, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(browser.tabHoverCards.chatCard.rows.map(\.item.id), ["dm/a"])
        XCTAssertFalse(browser.tabHoverCards.chatCard.isHidden)
        XCTAssertTrue(browser.tabHoverCards.gmailCard.isHidden)
        XCTAssertNotNil(browser.tabHoverCards.chatCard.layer?.animation(forKey: CardMotionAnimator.inKeys[0]))
    }
    @MainActor func testSettingsAskForEveryConversationAndTurnTheCardOff() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Rise.ChatSettingsTests.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); browser.showWindow(nil)
        defer {
            browser.tabPressed(); browser.chatInbox.tearDown(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder)
        }
        var asked: [GoogleChatPageReader.Request] = []
        browser.chatInbox.loadPage = { request, _ in asked.append(request); return MailPage(emails: [self.conversation("space/a", "Ship it", unread: false)], hasMore: false) }
        let tab = browser.addTab()
        tab.requestedURL = URL(string: "https://chat.google.com/app/home"); browser.update()
        let deadline = Date().addingTimeInterval(5)
        while asked.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(asked.last?.everything, false, "Direct messages unless asked")
        browser.setRiseSetting("googleChatContent", "everything")
        while asked.last?.everything != true, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(asked.last?.everything, true)

        let toggle = { browser.riseSettingRows("tabs").first { $0["key"] as? String == HoverCard.googleChat.settingKey }?["value"] as? Bool }
        XCTAssertEqual(toggle(), true, "On until turned off")
        browser.setRiseSetting(HoverCard.googleChat.settingKey, false)
        XCTAssertEqual(toggle(), false)
        XCTAssertNil(browser.chatInbox.request, "Its page isn't read")
        browser.tabHoverChanged(tab.id, hovering: true)
        while browser.tabHoverCards.shownID != tab.id, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(browser.tabHoverCards.chatCard.isHidden, "Its tab has the title card instead")
        XCTAssertFalse(browser.tabHoverCards.titleCard.isHidden)
    }
}
