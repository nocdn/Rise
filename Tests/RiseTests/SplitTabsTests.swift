import XCTest
import AppKit
import RiseCore
@testable import Rise

final class SplitTabsTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testPairStaysGroupedWhenInactiveAndEachHalfRestoresFixedPaneOrder() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let group = try XCTUnwrap(browser.splitGroups.first)
        let row = try XCTUnwrap(browser.sidebar.splitRows[group.id])
        XCTAssertEqual(browser.sidebar.orderedIDs, [other.id, left.id])
        XCTAssertTrue(row.left.superview === row && row.right.superview === row)
        XCTAssertTrue(row.divider.isHidden)
        let leftFrame = left.webView.frame, rightFrame = right.webView.frame
        browser.select(other.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.splitGroups, [group])
        XCTAssertFalse(row.divider.isHidden)
        XCTAssertFalse(row.left.selected); XCTAssertFalse(row.right.selected)
        XCTAssertNil(left.webView.superview); XCTAssertNil(right.webView.superview)
        row.right.performClick(nil); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.selectedID, right.id)
        XCTAssertEqual(browser.splitTab?.id, left.id)
        XCTAssertTrue(row.left.selected && row.right.selected)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
        XCTAssertTrue(left.webView.superview === browser.pageClip && right.webView.superview === browser.pageClip)
        XCTAssertEqual(browser.sidebar.selectedTabShadow.frame, row.convert(row.bounds, to: browser.sidebar))
        row.left.performClick(nil)
        XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
    }
    @MainActor func testClickingRightPageFocusesItWithoutReplacingEitherWebView() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let leftFrame = left.webView.frame, rightFrame = right.webView.frame
        let point = right.webView.convert(NSPoint(x: 100, y: 100), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        browser.window?.sendEvent(event)
        XCTAssertEqual(browser.selectedID, right.id)
        XCTAssertEqual(left.webView.frame, leftFrame); XCTAssertEqual(right.webView.frame, rightFrame)
        XCTAssertTrue(left.webView.superview === browser.pageClip && right.webView.superview === browser.pageClip)
        XCTAssertEqual(browser.activeSplitGroup?.rightID, right.id)
    }
    @MainActor func testClosingOrSeparatingPairLeavesUsableStandaloneTabs() {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        browser.closeTab(right.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertTrue(browser.splitGroups.isEmpty); XCTAssertTrue(browser.sidebar.splitRows.isEmpty)
        XCTAssertEqual(left.webView.frame, browser.pageClip.bounds)
        XCTAssertFalse(browser.sidebar.rows[left.id]!.isSplitMember)
        browser.showSplit(other); browser.select(other.id)
        browser.separateSplit(containing: left.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertTrue(browser.splitGroups.isEmpty)
        XCTAssertEqual(browser.selectedID, other.id)
        XCTAssertEqual(other.webView.frame, browser.pageClip.bounds)
        XCTAssertTrue(browser.sidebar.rows[left.id]?.superview === browser.sidebar.rowsHost)
        XCTAssertTrue(browser.sidebar.rows[other.id]?.superview === browser.sidebar.rowsHost)
    }
    @MainActor func testMultiplePairsRestoreAndRegroupWithoutDuplicateMembership() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(), c = browser.addTab(), d = browser.addTab(), other = browser.addTab()
        browser.select(a.id); browser.showSplit(b)
        browser.select(c.id); browser.showSplit(d)
        browser.select(other.id); browser.saveNow()
        let restored = BrowserController(sessionURL: browser.sessionURL)
        defer { restored.saveWork?.cancel(); restored.tabs.forEach { $0.webView.stopLoading() }; restored.window?.orderOut(nil) }
        XCTAssertEqual(restored.splitGroups, browser.splitGroups)
        XCTAssertEqual(restored.sidebar.splitRows.count, 2)
        XCTAssertNil(restored.activeSplitGroup)
        restored.select(d.id)
        XCTAssertEqual(restored.visibleTabIDs, [c.id, d.id])
        browser.select(a.id); browser.showSplit(c); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.splitGroups.count, 1)
        XCTAssertEqual(browser.visibleTabIDs, [a.id, c.id])
        XCTAssertEqual(browser.sidebar.orderedIDs.count, 4)
        XCTAssertFalse(browser.sidebar.rows[b.id]!.isSplitMember)
        XCTAssertFalse(browser.sidebar.rows[d.id]!.isSplitMember)
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at view: NSView, dx: CGFloat = 0, clicks: Int = 1) -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX+dx, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: view.window!.windowNumber,
                                  context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    @MainActor func testSplitPagesAreRoundedCardsWithTheHandleInTheGapBetweenThem() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let gap = BrowserController.splitGap, l = left.webView.frame, r = right.webView.frame
        XCTAssertEqual(r.minX-l.maxX, gap); XCTAssertEqual(l.width, r.width, accuracy: 1)
        let outline = try XCTUnwrap(browser.pageClip.restingOutline), height = browser.pageClip.bounds.height
        XCTAssertTrue(outline.contains(CGPoint(x: l.midX, y: height/2)) && outline.contains(CGPoint(x: r.midX, y: height/2)))
        XCTAssertFalse(outline.contains(CGPoint(x: l.maxX+gap/2, y: height/2)), "The window shows between the pages")
        for corner in [CGPoint(x: l.maxX-1, y: 1), CGPoint(x: l.maxX-1, y: height-1), CGPoint(x: r.minX+1, y: 1), CGPoint(x: r.minX+1, y: height-1)] {
            XCTAssertFalse(outline.contains(corner), "The inner corners are rounded too: \(corner)")
        }
        XCTAssertTrue(browser.pageShadow.restingOutline === outline, "Each page casts its own shadow")
        let handle = browser.splitHandle
        XCTAssertFalse(handle.isHidden); XCTAssertTrue(handle.superview === browser.pageShadow)
        XCTAssertEqual(handle.frame.minX, l.maxX); XCTAssertEqual(handle.frame.width, gap)

        // A history swipe on the right page squeezes only its card, then the split's shape comes back.
        browser.updateClothFrame(for: right.webView, pull: 1, forward: false)
        let swiped = try XCTUnwrap(browser.pageClip.clothOutline).boundingBoxOfPath
        XCTAssertEqual(swiped.minX, 0, accuracy: 0.5, "The left page stays put")
        XCTAssertTrue(browser.pageClip.clothOutline!.contains(CGPoint(x: l.midX, y: height/2)))
        XCTAssertFalse(browser.pageClip.clothOutline!.contains(CGPoint(x: r.minX+r.width*0.03, y: height/2)), "The right page gives way at its edge")
        browser.resetClothFrame()
        XCTAssertNil(browser.pageClip.clothOutline); XCTAssertTrue(browser.pageClip.restingOutline === outline)

        browser.separateSplit(containing: left.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertNil(browser.pageClip.restingOutline); XCTAssertTrue(handle.isHidden)
    }
    @MainActor func testDraggingTheHandleResizesBothPagesWithinLimitsAndADoubleClickCentersIt() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let handle = browser.splitHandle, room = browser.pageBody.width-BrowserController.splitGap, start = left.webView.frame.width
        handle.mouseDown(with: mouse(.leftMouseDown, at: handle))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: handle, dx: 100))
        XCTAssertEqual(left.webView.frame.width, start+100, accuracy: 1)
        XCTAssertEqual(right.webView.frame.minX, left.webView.frame.maxX+BrowserController.splitGap)
        XCTAssertEqual(handle.frame.minX, left.webView.frame.maxX, "The handle follows the split")
        XCTAssertEqual(browser.pageClip.restingOutline?.contains(CGPoint(x: start+BrowserController.splitGap/2, y: 50)), true, "So do the pages' corners")
        // Further than the limit, the right page keeps a fifth of the room.
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: handle, dx: 5000))
        handle.mouseUp(with: mouse(.leftMouseUp, at: handle))
        XCTAssertEqual(browser.activeSplitGroup?.fraction, SplitTabGroup.fractionRange.upperBound)
        XCTAssertEqual(right.webView.frame.width, (room*0.2).rounded(), accuracy: 1)
        handle.mouseDown(with: mouse(.leftMouseDown, at: handle, clicks: 2))
        XCTAssertEqual(browser.activeSplitGroup?.fraction, 0.5)
        XCTAssertEqual(left.webView.frame.width, start, accuracy: 1)
    }
    @MainActor func testTheHandleGrowsAndDarkensOnHoverAndDarkensAndShrinksWhilePressed() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let handle = browser.splitHandle
        let resting = (handle.pillLength, handle.pillAlpha)
        XCTAssertEqual(resting.0, SplitHandle.restingLength)
        handle.mouseEntered(with: NSEvent())
        XCTAssertEqual(handle.pillLength, SplitHandle.hoverLength); XCTAssertGreaterThan(handle.pillAlpha, resting.1)
        let spring = try XCTUnwrap(handle.lengthSpring)
        XCTAssertLessThan(spring.damping, 2*sqrt(spring.mass*spring.stiffness), "It springs a little past its new length")
        let hovered = handle.pillAlpha
        handle.mouseDown(with: mouse(.leftMouseDown, at: handle))
        XCTAssertGreaterThan(handle.pillAlpha, hovered); XCTAssertEqual(handle.pressScale, SplitHandle.pressedScale, accuracy: 0.001)
        handle.mouseUp(with: mouse(.leftMouseUp, at: handle))
        XCTAssertEqual(handle.pressScale, 1, accuracy: 0.001)
    }
    @MainActor func testSeparateTabsSitsJustAboveCloseTab() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        func lastSection(_ id: UUID) throws -> [String] {
            let items = try XCTUnwrap(browser.makeTabMenu(id)).items
            let separator = try XCTUnwrap(items.lastIndex { $0.isSeparatorItem })
            return items[(separator+1)...].map(\.title)
        }
        XCTAssertEqual(try lastSection(right.id), ["Separate Tabs", "Close Tab"])
        XCTAssertEqual(try lastSection(other.id), ["Close Tab"])
        XCTAssertFalse(try XCTUnwrap(browser.makeTabMenu(left.id)).items.contains { $0.title.contains("Split Tabs") })
    }

    @MainActor func testEachSplitHalfShowsItsOwnSmallerCloseButtonOnHover() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let half = try XCTUnwrap(browser.sidebar.rows[right.id]), whole = try XCTUnwrap(browser.sidebar.rows[other.id])
        XCTAssertTrue(half.close.isHidden)
        half.mouseEntered(with: NSEvent()); half.layoutSubtreeIfNeeded()
        whole.mouseEntered(with: NSEvent()); whole.layoutSubtreeIfNeeded()
        XCTAssertFalse(half.close.isHidden, "Hovering a half shows its close button")
        XCTAssertTrue(browser.sidebar.rows[left.id]!.close.isHidden, "Only on the half being hovered")
        XCTAssertLessThan(half.close.frame.width, whole.close.frame.width, "Smaller than a whole tab's")
        XCTAssertLessThanOrEqual(half.close.frame.maxX, half.bounds.width)
        XCTAssertLessThanOrEqual(half.titleField.frame.maxX, half.close.frame.minX, "The title makes room for it")
        XCTAssertTrue(half.playback.isHidden)
        half.close.performClick(nil)
        XCTAssertFalse(browser.tabs.contains { $0.id == right.id }, "It closes that half")
        XCTAssertTrue(browser.tabs.contains { $0.id == left.id }); XCTAssertTrue(browser.splitGroups.isEmpty)
    }
}
