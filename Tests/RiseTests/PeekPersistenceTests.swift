import XCTest
import AppKit
import RiseCore
@testable import Rise

final class PeekPersistenceTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let folder = URL.temporaryDirectory.appendingPathComponent("RisePeek-\(UUID())")
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        addTeardownBlock { @MainActor in
            browser.closePeek(); browser.finishPeekMotion()
            for owner in Array(browser.suspendedPeeks.keys) { browser.discardPeek(for: owner) }
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }
    @MainActor func testEachTabKeepsTheSameLivePeekAndItsHistoryAcrossSwitches() throws {
        let browser = browser(), first = browser.addTab(), second = browser.addTab()
        browser.select(first.id)
        browser.showPeek(url: URL(string: "about:blank?first")!, from: first.page.view)
        let firstPeek = try XCTUnwrap(browser.peekTab), page = try XCTUnwrap(firstPeek.page as? BlankPage)
        page.load(URL(string: "about:blank?navigated")!)
        let loads = page.loadCount
        browser.select(second.id)
        XCTAssertNil(browser.peekTab)
        XCTAssertTrue(browser.peek(for: first.id) === firstPeek)
        XCTAssertTrue(page.isCovered); XCTAssertNil(page.view.superview)
        XCTAssertFalse(second.page.isCovered)
        browser.showPeek(url: URL(string: "about:blank?second")!, from: second.page.view)
        let secondPeek = try XCTUnwrap(browser.peekTab)
        browser.select(first.id)
        XCTAssertTrue(browser.peekTab === firstPeek)
        XCTAssertTrue(browser.peek(for: second.id) === secondPeek)
        XCTAssertEqual(page.loadCount, loads, "The retained page doesn't reload")
        XCTAssertTrue(page.canGoBack)
        XCTAssertTrue(first.page.isCovered); XCTAssertFalse(page.isCovered)
        XCTAssertTrue(browser.window?.firstResponder === page.view)
        XCTAssertEqual(browser.peekCard?.alphaValue, 1)
        XCTAssertTrue(browser.peekGhosts.isEmpty, "Returning doesn't replay Peek's opening")
        browser.select(first.id)
        XCTAssertTrue(browser.peekTab === firstPeek, "Selecting its own tab doesn't dismiss Peek")
        browser.goBack(); XCTAssertEqual(page.url?.query, "first")
        browser.closeCurrentTab()
        XCTAssertNil(browser.peek(for: first.id)); XCTAssertTrue(browser.tabs.contains { $0 === first })
        browser.select(second.id); XCTAssertTrue(browser.peekTab === secondPeek)
    }

    @MainActor func testSwitchingMidOpenCannotRevealTheOldPeekOverAnotherTab() async throws {
        let browser = browser(); browser.showWindow(nil)
        let source = browser.addTab(), other = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab)
        browser.select(other.id)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(browser.peekTab); XCTAssertTrue(browser.peekGhosts.isEmpty)
        XCTAssertTrue(CATransform3DIsIdentity(browser.pageShadow.layer!.transform))
        browser.select(source.id)
        XCTAssertTrue(browser.peekTab === peek); XCTAssertEqual(browser.peekCard?.alphaValue, 1)
        XCTAssertNil(browser.pageShadow.layer?.animation(forKey: "peek.recede"))
        XCTAssertEqual(browser.pageShadow.layer!.transform.m11, BrowserController.peekPageScale, accuracy: 0.0001)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(browser.peekTab === peek); XCTAssertTrue(browser.peekGhosts.isEmpty)
    }

    @MainActor func testClosingAnOwnerOrItsBackgroundPeekReleasesOnlyThatPeek() throws {
        let browser = browser(), first = browser.addTab(), second = browser.addTab(), third = browser.addTab()
        browser.select(first.id); browser.showPeek(url: URL(string: "about:blank?one")!)
        let firstPeek = try XCTUnwrap(browser.peekTab)
        browser.select(second.id); browser.showPeek(url: URL(string: "about:blank?two")!)
        let secondPeek = try XCTUnwrap(browser.peekTab)
        browser.select(third.id)
        browser.closeTab(first.id)
        XCTAssertNil(browser.peek(for: first.id)); XCTAssertFalse(browser.suspendedPeeks.keys.contains(first.id))
        XCTAssertNil(firstPeek.page.view.superview)
        XCTAssertTrue(browser.peek(for: second.id) === secondPeek)
        browser.closePage(secondPeek.page.view)
        XCTAssertTrue(browser.suspendedPeeks.isEmpty)
        XCTAssertTrue(browser.tabs.contains { $0 === second })
        XCTAssertEqual(browser.selectedID, third.id)
    }

    @MainActor func testSwitchingAfterAnExplicitCloseCannotLeaveItsGhostOrScaleOnAnotherTab() async throws {
        let browser = browser(); browser.showWindow(nil)
        let source = browser.addTab(), other = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view, animated: false)
        browser.closePeek(animated: true)
        browser.select(other.id)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(browser.peekGhosts.isEmpty); XCTAssertTrue(browser.peekLeftovers.isEmpty)
        XCTAssertTrue(CATransform3DIsIdentity(browser.pageShadow.layer!.transform))
        browser.select(source.id)
        XCTAssertNil(browser.peekTab, "An explicitly closed Peek doesn't return")
    }

    @MainActor func testRestoredPeekCanExpandAndUndoThenBeRetainedAgain() throws {
        let browser = browser(), source = browser.addTab(), other = browser.addTab()
        browser.select(source.id); browser.showPeek(url: URL(string: "about:blank?peek")!, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab), livePage = peek.page
        browser.select(other.id); browser.select(source.id)
        browser.expandPeek(modifiers: [])
        XCTAssertNil(browser.peek(for: source.id)); XCTAssertTrue(source.page === livePage)
        XCTAssertTrue(browser.undoPeekPromotion())
        XCTAssertTrue(browser.peekTab?.page === livePage)
        browser.select(other.id); browser.select(source.id)
        XCTAssertTrue(browser.peekTab?.page === livePage)
        XCTAssertEqual(browser.peekSourceTabID, source.id)
    }

    @MainActor func testRemoteRemovalDiscardsTheOwnersRetainedPeek() {
        let browser = browser(), source = browser.addTab(), other = browser.addTab()
        browser.select(source.id); browser.showPeek(url: URL(string: "about:blank?peek")!)
        browser.select(other.id)
        browser.applySharedTabs([SharedBrowserTab(id: other.id, url: nil, title: "Other")])
        XCTAssertNil(browser.peek(for: source.id)); XCTAssertTrue(browser.suspendedPeeks.isEmpty)
        XCTAssertEqual(browser.tabs.map(\.id), [other.id])
    }

    @MainActor func testIndicatorStaysFixedAndCloseSlidesBackWhenPeekCloses() async throws {
        let browser = browser(); browser.showWindow(nil)
        let source = browser.addTab()
        browser.showPeek(url: URL(string: "about:blank?peek")!, from: source.page.view, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        peek.favicon = image; browser.update(); browser.root.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(browser.sidebar.rows[source.id])
        row.mouseExited(with: NSEvent()); row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.showsPeek); XCTAssertFalse(row.peekIndicator.isHidden)
        XCTAssertTrue(row.peekIndicator.favicon.image === image)
        XCTAssertEqual(row.peekIndicator.frame.minX, row.close.frame.maxX+2)
        XCTAssertEqual(row.peekIndicator.layer!.cornerRadius-row.peekIndicator.favicon.layer!.cornerRadius, PeekFaviconIndicator.inset)
        XCTAssertLessThanOrEqual(row.titleField.frame.maxX, row.peekIndicator.frame.minX)
        let close = row.close.frame, indicator = row.peekIndicator.frame
        row.mouseEntered(with: NSEvent()); row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.close.isHidden); XCTAssertEqual(row.close.frame, close)
        XCTAssertEqual(row.peekIndicator.frame, indicator, "Hovering leaves the Peek favicon in its usual slot")
        XCTAssertNil(row.peekIndicator.layer?.animation(forKey: TabListMotion.slideKey))
        row.setPlayback(paused: false); row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.playback.isHidden)
        XCTAssertEqual(row.peekIndicator.frame, indicator)
        XCTAssertLessThan(row.playback.frame.maxX, row.close.frame.minX)
        let point = NSPoint(x: close.midX, y: close.midY)
        XCTAssertTrue(row.hitTest(row.convert(point, to: row.superview)) === row.close)
        browser.closePeek()
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.showsPeek); XCTAssertEqual(row.peekIndicator.alphaValue, 0)
        XCTAssertEqual(row.close.frame, close.offsetBy(dx: 26, dy: 0))
        XCTAssertNotNil(row.close.layer?.animation(forKey: TabListMotion.slideKey), "The hovered X springs back into its normal slot")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(row.peekIndicator.isHidden)
    }
}
