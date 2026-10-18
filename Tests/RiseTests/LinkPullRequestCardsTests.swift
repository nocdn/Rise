import XCTest
import AppKit
@testable import Rise

final class LinkPullRequestCardsTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil)
        if ProcessInfo.processInfo.environment["RISE_LINK_SHOTS"] == nil { browser.window?.alphaValue = 0.01 }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.hideLinkCard(fades: false); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }

    /// Leaving the link ends the page's hover; the card stays so the pointer can move into it.
    @MainActor func testLeavingTheLinkKeepsItsCardForThePointer() throws {
        let browser = browser(); defer { clean(browser) }
        browser.addTab()
        let page = try XCTUnwrap(browser.selectedTab?.page), web = page.view
        let url = try XCTUnwrap(URL(string: "https://github.com/rise-tests/none/pull/1"))
        let pr = try XCTUnwrap(PullRequest(url: url))
        let pageFrame = web.convert(web.bounds, to: browser.root)
        browser.showHoveredLink(url, in: web)
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: NSRect(x: pageFrame.minX+80, y: pageFrame.minY+400, width: 420, height: 20), in: web, page: page)
        browser.showHoveredLink(nil, in: web)
        XCTAssertEqual(browser.linkPullRequests.card.key, pr.key)
        XCTAssertNil(browser.linkPullRequests.card.layer?.animation(forKey: "card.exit.opacity"), "It isn't on its way out")
        browser.hideLinkStatus()
        XCTAssertNil(browser.linkPullRequests.card.key, "A page change still closes it")
    }

    func testTheLinkNamesTheCardUntilTheDetailsArrive() {
        let pr = PullRequest(url: URL(string: "https://github.com/rise/app/pull/12"))!
        XCTAssertEqual(LinkPullRequestCards.title(fromLink: "Fix the sidebar\n#12 opened by someone", pr), "Fix the sidebar")
        XCTAssertEqual(LinkPullRequestCards.title(fromLink: "#12", pr), "rise/app #12")
        XCTAssertEqual(LinkPullRequestCards.title(fromLink: "https://github.com/rise/app/pull/12", pr), "rise/app #12")
    }

    /// As wide as the link, standing just above it, or under it with no room above; narrow links
    /// get a card wide enough to read, centred over them. It fades away rather than vanishing.
    @MainActor func testTheCardStandsOnItsLink() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.addTab()
        let page = try XCTUnwrap(browser.selectedTab?.page), web = page.view, root = browser.root
        let pr = try XCTUnwrap(PullRequest(url: URL(string: "https://github.com/rise-tests/none/pull/1")))
        let card = browser.linkPullRequests.card
        let pageFrame = web.convert(web.bounds, to: root)
        XCTAssertTrue(root.isFlipped)

        let wide = NSRect(x: pageFrame.minX+80, y: pageFrame.minY+400, width: 420, height: 20)
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: wide, in: web, page: page)
        XCTAssertFalse(card.isHidden)
        XCTAssertEqual(card.frame.width, 420)
        XCTAssertEqual(card.frame.minX, wide.minX)
        XCTAssertEqual(card.frame.maxY, wide.minY-LinkPullRequestCards.gap, accuracy: 0.5)
        XCTAssertNotNil(card.layer?.animation(forKey: "card.pop.transform"), "It unfolds")
        XCTAssertNil(card.layer?.animation(forKey: "card.pop.opacity"), "without fading")
        if let shots = ProcessInfo.processInfo.environment["RISE_LINK_SHOTS"], let number = browser.window?.windowNumber {
            for (index, delay) in [0, 30, 30, 30, 300].enumerated() {
                try await Task.sleep(for: .milliseconds(delay))
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(number)", "\(shots)/link-\(index).png"]
                try shot.run(); shot.waitUntilExit()
            }
        }

        let narrow = NSRect(x: pageFrame.minX+300, y: pageFrame.minY+400, width: 40, height: 18)
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: narrow, in: web, page: page)
        XCTAssertEqual(card.frame.width, LinkPullRequestCards.minimumWidth)
        XCTAssertEqual(card.frame.midX, narrow.midX, accuracy: 0.5)

        let high = NSRect(x: pageFrame.minX+80, y: pageFrame.minY+40, width: 420, height: 20)
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: high, in: web, page: page)
        XCTAssertEqual(card.frame.minY, high.maxY+LinkPullRequestCards.gap, accuracy: 0.5, "No room above, so under it")

        try await Task.sleep(for: .milliseconds(900))
        browser.hideLinkCard()
        XCTAssertFalse(card.isHidden, "It folds away")
        XCTAssertNotNil(card.layer?.animation(forKey: "card.exit.opacity"), "fading")
        XCTAssertNotNil(card.layer?.animation(forKey: "card.exit.transform"))
        if let shots = ProcessInfo.processInfo.environment["RISE_LINK_SHOTS"], let number = browser.window?.windowNumber {
            for index in 0..<3 {
                try await Task.sleep(for: .milliseconds(25))
                let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(number)", "\(shots)/fold-\(index).png"]
                try shot.run(); shot.waitUntilExit()
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(card.isHidden)
        XCTAssertNil(card.layer?.animation(forKey: "card.exit.opacity"))
    }
}
