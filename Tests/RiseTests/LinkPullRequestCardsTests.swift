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
        browser.presentLinkCard(.pullRequest(pr), title: "Fix the sidebar", link: NSRect(x: pageFrame.minX+80, y: pageFrame.minY+400, width: 420, height: 20), in: web, page: page)
        browser.showHoveredLink(nil, in: web)
        XCTAssertEqual(browser.linkPullRequests.card.key, pr.key)
        XCTAssertNil(browser.linkPullRequests.card.layer?.animation(forKey: "card.exit.opacity"), "It isn't on its way out")
        browser.hideLinkStatus()
        XCTAssertNil(browser.linkPullRequests.card.key, "A page change still closes it")
    }

    /// Clicking the link closes its card at once, with its motion, not when the page starts loading.
    @MainActor func testClickingTheLinkClosesItsCardAtOnce() throws {
        let browser = browser(); defer { clean(browser) }
        browser.addTab()
        let page = try XCTUnwrap(browser.selectedTab?.page), web = page.view
        let url = try XCTUnwrap(URL(string: "https://github.com/rise-tests/none/pull/1"))
        let pr = try XCTUnwrap(PullRequest(url: url))
        let frame = web.convert(web.bounds, to: browser.root), link = NSRect(x: frame.minX+80, y: frame.minY+400, width: 420, height: 20)
        browser.showHoveredLink(url, in: web)
        browser.presentLinkCard(.pullRequest(pr), title: "Fix the sidebar", link: link, in: web, page: page)
        func press(at point: NSPoint) {
            let window = try! XCTUnwrap(browser.window)
            browser.linkCardPagePressed(NSEvent.mouseEvent(with: .leftMouseDown, location: browser.root.convert(point, to: nil), modifierFlags: [],
                                                           timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        }
        let card = browser.linkPullRequests.card
        press(at: NSPoint(x: card.frame.midX, y: card.frame.midY))
        XCTAssertEqual(card.key, pr.key, "A press in the card leaves it")
        press(at: NSPoint(x: link.midX, y: link.midY))
        XCTAssertNil(card.key, "The link's press closes it")
        XCTAssertNotNil(card.layer?.animation(forKey: "card.exit.opacity"), "with its way out")
    }
    func testOnGitHubItsOwnPullRequestLinksCanWaitForOption() {
        let link = URL(string: "https://github.com/anomalyco/rift/pull/52"), github = URL(string: "https://github.com/anomalyco/rift/commits/main")
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: link, option: false, on: github), "Off by default: the card comes as ever")
        XCTAssertNil(LinkPullRequestCards.Subject(url: link, option: false, on: github, gitHubNeedsOption: true), "GitHub's own card shows instead")
        XCTAssertEqual(LinkPullRequestCards.Subject(url: link, option: true, on: github, gitHubNeedsOption: true)?.pullRequest?.number, 52,
                       "Option brings Rise's card, not a summary")
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: link, option: false, on: URL(string: "https://example.com/notes"), gitHubNeedsOption: true),
                        "Elsewhere, GitHub's links get the card as ever")
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: URL(string: "https://gitlab.example.com/fe/app/-/merge_requests/9"), option: false, on: github,
                                                     gitHubNeedsOption: true), "Only GitHub's own links wait")
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
        browser.presentLinkCard(.pullRequest(pr), title: "Fix the sidebar", link: wide, in: web, page: page)
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
        browser.presentLinkCard(.pullRequest(pr), title: "Fix the sidebar", link: narrow, in: web, page: page)
        XCTAssertEqual(card.frame.width, LinkPullRequestCards.minimumWidth)
        XCTAssertEqual(card.frame.midX, narrow.midX, accuracy: 0.5)

        let high = NSRect(x: pageFrame.minX+80, y: pageFrame.minY+40, width: 420, height: 20)
        browser.presentLinkCard(.pullRequest(pr), title: "Fix the sidebar", link: high, in: web, page: page)
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

    func testAPullRequestsLinkGetsItsCardAndOptionAsksAnyOtherPageForASummary() {
        func subject(_ text: String, option: Bool) -> LinkPullRequestCards.Subject? { .init(url: URL(string: text), option: option) }
        XCTAssertNotNil(subject("https://github.com/rise/app/pull/12", option: false)?.pullRequest)
        XCTAssertNotNil(subject("https://github.com/rise/app/pull/12", option: true)?.pullRequest, "Its own card, which already describes it")
        XCTAssertNil(subject("https://example.com/post", option: false))
        XCTAssertEqual(subject("https://example.com/post#comments", option: true), .summary(URL(string: "https://example.com/post")!), "One page whatever its fragment")
        XCTAssertNil(subject("mailto:someone@example.com", option: true))
    }
    /// While it's written, the summary's card is its skeleton line alone, as far from the top as
    /// from the bottom.
    @MainActor func testASummarysCardIsItsSkeletonLineAloneWhileItsWritten() throws {
        _ = NSApplication.shared
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)), card = PullRequestTooltip()
        host.addSubview(card)
        card.present(key: "link:https://example.com/", content: .init(title: "", reference: "", details: nil, summary: "", phase: .generating),
                     left: 40, placement: .above(bottom: 400, minTop: 8), theme: .neutral, width: 360)
        func skeletons(_ view: NSView) -> [SkeletonLine] { (view as? SkeletonLine).map { [$0] } ?? view.subviews.flatMap(skeletons) }
        let line = try XCTUnwrap(skeletons(card).first { !$0.isHidden }), frame = line.convert(line.bounds, to: card)
        XCTAssertEqual(frame.minY, card.bounds.height-frame.maxY, accuracy: 0.5)
        XCTAssertEqual(frame.minY, PullRequestTooltip.inset.height+(card.bounds.height-2*PullRequestTooltip.inset.height-SkeletonLine.height)/2, accuracy: 0.5,
                       "No title above it")
        XCTAssertTrue(card.titleLabel.isHidden)
    }

    func testTwentyPulsesToPickFromEachKnownByItsOwnNameStartingWithTheFirst() {
        XCTAssertEqual(LinkPulse.presets.count, 20)
        XCTAssertEqual(Set(LinkPulse.presets.map(\.name)).count, 20, "A pick is saved by name")
        XCTAssertEqual(LinkPulse.presets[0].name, "Breathe", "Where it started")
    }

    /// Settings ▸ Appearance turns each kind of link's highlight off on its own.
    @MainActor func testSummaryAndPullRequestLinksHighlightsTurnOffSeparately() throws {
        let suite = "link-highlight-tests-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: defaults)
        defer { clean(browser); defaults.removePersistentDomain(forName: suite) }
        browser.showWindow(nil); browser.window?.alphaValue = 0.01; browser.addTab()
        let page = try XCTUnwrap(browser.selectedTab?.page), web = page.view, frame = web.convert(web.bounds, to: browser.root)
        let summary = LinkPullRequestCards.Subject.summary(try XCTUnwrap(URL(string: "https://example.com/article")))
        let pr = LinkPullRequestCards.Subject.pullRequest(try XCTUnwrap(PullRequest(url: try XCTUnwrap(URL(string: "https://github.com/rise-tests/none/pull/1")))))
        XCTAssertTrue(browser.highlightsLink(for: summary) && browser.highlightsLink(for: pr), "Both on unless turned off")

        browser.setRiseSetting("highlightPullRequestLinks", false)
        XCTAssertTrue(browser.highlightsLink(for: summary))
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: NSRect(x: frame.minX+80, y: frame.minY+400, width: 420, height: 20), in: web, page: page)
        XCTAssertNil(browser.linkPullRequests.highlightedWeb, "Its card opens with its link unlit")

        browser.setRiseSetting("highlightPullRequestLinks", true); browser.setRiseSetting("highlightSummaryLinks", false)
        XCTAssertFalse(browser.highlightsLink(for: summary))
        browser.presentLinkCard(pr, title: "Fix the sidebar", link: NSRect(x: frame.minX+80, y: frame.minY+400, width: 420, height: 20), in: web, page: page)
        XCTAssertTrue(browser.linkPullRequests.highlightedWeb === web)
    }

    /// A merge request's own tabs and heading anchors lead back to the page they're on: no card.
    func testLinksBackToThePageTheyreOnGetNoCard() throws {
        let mr = "https://gitlab.example.com/cloudflare/fe/stratus/-/merge_requests/46980"
        let page = try XCTUnwrap(URL(string: mr))
        for own in [mr, mr + "/commits", mr + "#how-to-test-the-code"] {
            XCTAssertNil(LinkPullRequestCards.Subject(url: URL(string: own), option: false, on: page), own)
        }
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: URL(string: mr.replacingOccurrences(of: "46980", with: "46978")), option: false, on: page))
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: page, option: false, on: URL(string: "https://gitlab.example.com/cloudflare/fe/stratus/-/merge_requests")))
        let article = try XCTUnwrap(URL(string: "https://example.com/article"))
        XCTAssertNil(LinkPullRequestCards.Subject(url: URL(string: "https://example.com/article#part-2"), option: true, on: article))
        XCTAssertNotNil(LinkPullRequestCards.Subject(url: URL(string: "https://example.com/other"), option: true, on: article))
    }
}
