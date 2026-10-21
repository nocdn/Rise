import XCTest
import AppKit
@testable import Rise

final class TabTitleTooltipTests: XCTestCase {
    /// A title waits its full delay on every tab, even with another title open; it never hands
    /// over at once as previews do.
    @MainActor func testEachTitleWaitsItsDelay() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName(""); browser.window?.alphaValue = 0.01; browser.showWindow(nil)
        defer { browser.tabPressed(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let first = browser.addTab(), second = browser.addTab()
        first.requestedURL = URL(string: "https://example.com/a"); second.requestedURL = URL(string: "https://example.com/b"); browser.update()
        browser.root.layoutSubtreeIfNeeded()
        let hover = browser.tabHoverCards
        browser.tabHoverChanged(first.id, hovering: true)
        XCTAssertNil(hover.shownID, "Not at once")
        try await Task.sleep(for: .milliseconds(Int(TabHoverCards.delay*1000)+150))
        XCTAssertEqual(hover.shownID, first.id)
        XCTAssertFalse(hover.titleCard.isHidden)
        // Like the previews: just right of the sidebar, centred on the tab, out of the middle of its left edge.
        let card = hover.titleCard, row = try XCTUnwrap(browser.sidebar.anchor(for: first.id))
        let tab = row.convert(row.bounds, to: browser.root)
        XCTAssertEqual(card.frame.minX, browser.sidebar.frame.maxX+6)
        XCTAssertEqual(card.frame.midY, tab.midY, accuracy: 1)
        XCTAssertEqual(card.hint.stringValue, "Double-click to rename")
        if let shots = ProcessInfo.processInfo.environment["RISE_LINK_SHOTS"], let number = browser.window?.windowNumber {
            browser.window?.alphaValue = 1
            try await Task.sleep(for: .milliseconds(400))
            let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(number)", "\(shots)/title.png"]
            try shot.run(); shot.waitUntilExit()
        }
        // Straight on to the next tab, before the first reports leaving.
        browser.tabHoverChanged(second.id, hovering: true)
        XCTAssertNil(hover.shownID, "The next title waits too")
        XCTAssertFalse(hover.titleCard.isShown, "and the open one goes")
        try await Task.sleep(for: .milliseconds(Int(TabHoverCards.delay*1000)-200))
        XCTAssertNil(hover.shownID)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(hover.shownID, second.id)
    }
    /// A Peek opened after a card was first shown goes in above it; the card comes back over it.
    @MainActor func testCardsShowOverAPeekOpenedSince() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setFrameAutosaveName(""); browser.window?.alphaValue = 0.01; browser.showWindow(nil)
        defer { browser.tabPressed(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/a"); browser.update()
        browser.root.layoutSubtreeIfNeeded()
        let hover = browser.tabHoverCards, root = browser.root
        browser.tabHoverChanged(tab.id, hovering: true)
        try await Task.sleep(for: .milliseconds(Int(TabHoverCards.delay*1000)+150))
        XCTAssertEqual(hover.shownID, tab.id)
        // Its safe triangle sees every pointer move through a tracking area, which the focused
        // page isn't sent, so the page's cursor doesn't fight the card's links.
        XCTAssertFalse(browser.window!.acceptsMouseMovedEvents)
        XCTAssertTrue(root.trackingAreas.contains { $0.owner === PointerMovesSink.shared && $0.options.contains(.mouseMoved) })
        browser.tabHoverChanged(tab.id, hovering: false)
        // Where a Peek's card and controls go as it opens.
        let peek = Surface(); root.addSubview(peek, positioned: .below, relativeTo: browser.dismissArea)
        XCTAssertGreaterThan(root.subviews.firstIndex(of: peek)!, root.subviews.firstIndex(of: hover.titleCard)!)
        try await Task.sleep(for: .milliseconds(400))
        browser.tabHoverChanged(tab.id, hovering: true)
        try await Task.sleep(for: .milliseconds(Int(TabHoverCards.delay*1000)+150))
        XCTAssertEqual(hover.shownID, tab.id)
        XCTAssertGreaterThan(root.subviews.firstIndex(of: hover.titleCard)!, root.subviews.firstIndex(of: peek)!, "Over the Peek")
    }

    /// It grows out of the middle of its left edge, the point level with the tab's middle.
    @MainActor func testTheTitleGrowsFromTheMiddleOfItsLeftEdge() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 700, height: 500)); window.contentView = host
        let card = TabTitleTooltip(frame: .zero); host.addSubview(card); window.orderFront(nil)
        defer { card.dismiss(animated: false); window.orderOut(nil) }
        card.present(title: "vercel mercedes merch - Google Search", beside: NSRect(x: 6, y: 200, width: 260, height: 34), left: 280, pinned: false, theme: .neutral)
        XCTAssertEqual(card.frame.midY, 217, accuracy: 1)
        let spring = try XCTUnwrap(card.layer?.animation(forKey: CardMotionAnimator.inKeys[0]) as? CASpringAnimation)
        let from = try XCTUnwrap(spring.fromValue as? NSValue).caTransform3DValue, scale = from.m11
        XCTAssertEqual(from.m41/(1-scale), 0, accuracy: 0.01, "Its left edge")
        XCTAssertEqual(from.m42/(1-scale), 217-card.frame.minY, accuracy: 0.01, "level with the tab's middle")
    }
}
