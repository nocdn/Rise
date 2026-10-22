import XCTest
import AppKit
@testable import Rise

final class TabDetachmentTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil)
        browser.sidebar.crossingClick = {}; browser.sidebar.detachmentClick = {}
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.sidebar.cancelTabInteractions(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func send(_ type: NSEvent.EventType, _ point: NSPoint, in view: NSView, browser: BrowserController) {
        let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        browser.window!.sendEvent(event)
    }
    @MainActor func testResistedPullReleasesOnceAndTracksBothAxesWithoutReorderingOrScrolling() throws {
        let browser = browser(); defer { clean(browser) }
        _ = browser.addTab()
        let tab = browser.addTab(), selected = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tab.id]!, original = row.frame, order = browser.tabs.map(\.id), web = tab.page.view
        let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        var releases = 0; browser.sidebar.detachmentClick = { releases += 1 }
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        let resisted = NSPoint(x: start.x+24, y: start.y+10)
        send(.leftMouseDragged, resisted, in: browser.sidebar.rowsHost, browser: browser)
        let held = row.convert(row.bounds, to: browser.sidebar.rowsHost)
        XCTAssertGreaterThan(held.minX, original.minX)
        XCTAssertLessThan(held.minX-original.minX, 24)
        XCTAssertEqual(held.minY-original.minY, 10, accuracy: 0.01, "Vertical movement has no resistance")
        XCTAssertFalse(try XCTUnwrap(browser.sidebar.drag).isDetached); XCTAssertEqual(releases, 0)
        send(.leftMouseDragged, NSPoint(x: start.x+48, y: start.y+10), in: browser.sidebar.rowsHost, browser: browser)
        let drag = try XCTUnwrap(browser.sidebar.drag)
        XCTAssertTrue(drag.isDetached); XCTAssertEqual(releases, 1)
        XCTAssertNotNil(row.layer?.animation(forKey: TabDragMotion.springKey), "The release bounces toward the cursor")
        let scroll = browser.sidebar.scroll.contentView.bounds
        let detachedOrder = browser.tabs.map(\.id)
        for point in [NSPoint(x: 700, y: 500), NSPoint(x: 500, y: -30)] {
            send(.leftMouseDragged, point, in: browser.sidebar.rowsHost, browser: browser)
            let floating = row.convert(row.bounds, to: browser.sidebar.rowsHost)
            XCTAssertEqual(floating.minX+drag.grabOffset.x, point.x, accuracy: 0.01)
            XCTAssertEqual(floating.minY+drag.grabOffset.y, point.y, accuracy: 0.01)
        }
        browser.update()
        XCTAssertTrue(row.superview === drag.overlay, "Page updates must not put a held tab back into the scroller")
        XCTAssertTrue(tab.page.view === web); XCTAssertEqual(browser.selectedID, selected.id)
        XCTAssertEqual(browser.tabs.map(\.id), detachedOrder); XCTAssertEqual(detachedOrder, order); XCTAssertEqual(releases, 1)
        XCTAssertEqual(browser.sidebar.scroll.contentView.bounds, scroll)
        send(.leftMouseUp, NSPoint(x: 500, y: -30), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertNil(browser.sidebar.drag); XCTAssertNil(browser.sidebar.dragScrollTimer)
        XCTAssertNotNil(browser.sidebar.returningDrag)
        browser.sidebar.finishReturningTab()
        XCTAssertTrue(row.superview === browser.sidebar.rowsHost); XCTAssertEqual(row.frame, original)
        XCTAssertNil(row.dragFill); XCTAssertNil(drag.overlay?.superview)
    }
    @MainActor func testVerticalDraggingFadesACardShadowAndOwnsTheCursorUntilRelease() throws {
        let browser = browser(); defer { clean(browser) }
        _ = browser.addTab(); let tab = browser.addTab(); _ = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tab.id]!
        let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        let window = try XCTUnwrap(browser.window as? BrowserWindow)
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        send(.leftMouseDragged, NSPoint(x: start.x, y: start.y+4), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertFalse(browser.sidebar.drag!.isDetached)
        XCTAssertTrue(window.isDraggingTab)
        let shadow = try XCTUnwrap(browser.sidebar.drag?.overlay?.shadowView)
        XCTAssertGreaterThan(shadow.layer?.shadowOpacity ?? 0, 0)
        XCTAssertEqual(shadow.layer?.shadowPath?.boundingBox, row.bounds, "Only the tab's rounded card casts a shadow")
        let fade = try XCTUnwrap(shadow.layer?.animation(forKey: TabDragMotion.shadowKey) as? CABasicAnimation)
        XCTAssertEqual(fade.fromValue as? Float, 0)
        XCTAssertGreaterThan(fade.duration, 0)
        NSCursor.resizeLeftRight.set()
        window.sendEvent(try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)))
        XCTAssertEqual(NSCursor.current, .arrow, "The sidebar resize region cannot take the cursor during a tab drag")
        send(.leftMouseUp, NSPoint(x: start.x, y: start.y+4), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertFalse(window.isDraggingTab)
        let out = try XCTUnwrap(shadow.layer?.animation(forKey: TabDragMotion.shadowKey) as? CABasicAnimation)
        XCTAssertEqual(out.toValue as? Float, 0)
        XCTAssertLessThan(out.duration, fade.duration)
        browser.sidebar.finishReturningTab()
        XCTAssertNil(shadow.superview?.superview)
    }
    @MainActor func testRedockingAtAnotherSlotResumesReorderingWithHysteresis() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(), c = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[b.id]!, start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        var releases = 0; browser.sidebar.detachmentClick = { releases += 1 }
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        send(.leftMouseDragged, NSPoint(x: start.x+60, y: start.y), in: browser.sidebar.rowsHost, browser: browser)
        send(.leftMouseDragged, NSPoint(x: start.x+25, y: start.y+40), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertTrue(browser.sidebar.drag!.isDetached, "A pull near the release edge does not immediately redock")
        let capture = NSPoint(x: start.x+9, y: start.y+40)
        send(.leftMouseDragged, capture, in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertFalse(browser.sidebar.drag!.isDetached)
        XCTAssertEqual(browser.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertNotNil(row.layer?.animation(forKey: TabDragMotion.springKey))
        send(.leftMouseDragged, NSPoint(x: start.x+25, y: capture.y), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertFalse(browser.sidebar.drag!.isDetached); XCTAssertEqual(releases, 1)
        send(.leftMouseUp, capture, in: browser.sidebar.rowsHost, browser: browser)
        browser.sidebar.finishReturningTab()
        XCTAssertEqual(browser.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(row.frame, browser.sidebar.targetFrames[b.id]); XCTAssertNil(row.dragFill)
    }
    @MainActor func testOutsideDropKeepsCrossingsAndEscapeRestoresAFloatingSplitPair() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let group = browser.splitGroups[0], pair = browser.sidebar.splitRows[group.id]!, original = browser.sidebar.orderedIDs
        let start = pair.right.convert(NSPoint(x: 20, y: 15), to: browser.sidebar.rowsHost)
        send(.leftMouseDown, NSPoint(x: 20, y: 15), in: pair.right, browser: browser)
        send(.leftMouseDragged, NSPoint(x: start.x, y: 8), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertNotEqual(browser.sidebar.orderedIDs, original)
        let reordered = browser.sidebar.orderedIDs
        send(.leftMouseDragged, NSPoint(x: start.x+60, y: 8), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertTrue(browser.sidebar.drag!.isDetached)
        send(.leftMouseUp, NSPoint(x: 600, y: 300), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertEqual(browser.sidebar.orderedIDs, reordered)
        XCTAssertEqual(browser.splitGroups, [group])
        browser.sidebar.finishReturningTab()
        send(.leftMouseDown, NSPoint(x: 20, y: 15), in: pair.right, browser: browser)
        let next = pair.right.convert(NSPoint(x: 20, y: 15), to: browser.sidebar.rowsHost)
        send(.leftMouseDragged, NSPoint(x: next.x, y: 80), in: browser.sidebar.rowsHost, browser: browser)
        send(.leftMouseDragged, NSPoint(x: next.x+60, y: 80), in: browser.sidebar.rowsHost, browser: browser)
        let overlay = browser.sidebar.drag!.overlay
        browser.window!.cancelOperation(nil)
        XCTAssertNil(browser.sidebar.drag); XCTAssertNil(browser.sidebar.returningDrag)
        XCTAssertNil(overlay?.superview); XCTAssertNil(pair.dragFill)
        XCTAssertTrue(pair.superview === browser.sidebar.rowsHost)
        XCTAssertEqual(browser.sidebar.orderedIDs, reordered, "Escape restores the order from the start of this drag")
        XCTAssertEqual(browser.splitGroups, [group]); XCTAssertEqual(browser.selectedID, left.id)
        XCTAssertTrue(browser.tabs.contains { $0.id == other.id })
    }
    @MainActor func testDetachedReturnUsesTheLastAcceptedSlotAfterTwoUpwardCrossings() throws {
        let browser = browser(); defer { clean(browser) }
        let tabs = (0..<5).map { _ in browser.addTab() }
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tabs[0].id]!
        let targetY = browser.sidebar.targetFrames[tabs[2].id]!.minY
        let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        var crossings = 0; browser.sidebar.crossingClick = { crossings += 1 }
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        let reorderedPoint = NSPoint(x: start.x, y: targetY+18)
        send(.leftMouseDragged, reorderedPoint, in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertEqual(crossings, 2)
        let order = browser.tabs.map(\.id), target = browser.sidebar.targetFrames[tabs[0].id]!
        XCTAssertEqual(order.firstIndex(of: tabs[0].id), 2)
        send(.leftMouseDragged, NSPoint(x: start.x+60, y: reorderedPoint.y), in: browser.sidebar.rowsHost, browser: browser)
        send(.leftMouseUp, NSPoint(x: 700, y: 400), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertEqual(browser.tabs.map(\.id), order)
        XCTAssertEqual(row.convert(row.bounds, to: browser.sidebar.rowsHost), target)
        browser.sidebar.finishReturningTab()
        XCTAssertEqual(row.frame, target)
    }
    @MainActor func testListEndsResistThenDetachAndRedockWithProgressiveShadow() throws {
        let browser = browser(); defer { clean(browser) }
        let bottom = browser.addTab(); _ = browser.addTab(); _ = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        var releases = 0; browser.sidebar.detachmentClick = { releases += 1 }
        // Only the bottom end: dragging the top row up pins it (PinnedTabsTests).
        for (tab, direction): (BrowserTab, CGFloat) in [(bottom, 1)] {
            let row = browser.sidebar.rows[tab.id]!, slot = row.frame
            let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
            let order = browser.tabs.map(\.id)
            send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
            var previousOpacity: Float = 0
            var shadow: NSView!
            for distance: CGFloat in [8, 24, 40] {
                send(.leftMouseDragged, NSPoint(x: start.x, y: start.y+direction*distance), in: browser.sidebar.rowsHost, browser: browser)
                let held = row.convert(row.bounds, to: browser.sidebar.rowsHost)
                XCTAssertGreaterThan((held.minY-slot.minY)*direction, 0, "List ends are elastic, not blocked")
                XCTAssertLessThan(abs(held.minY-slot.minY), distance)
                XCTAssertFalse(browser.sidebar.drag!.isDetached)
                shadow = try XCTUnwrap(browser.sidebar.drag?.overlay?.shadowView)
                let opacity = try XCTUnwrap(shadow.layer?.shadowOpacity)
                XCTAssertGreaterThan(opacity, previousOpacity); previousOpacity = opacity
                XCTAssertLessThan(opacity, TabDragMotion.detachedShadowOpacity)
            }
            let freed = NSPoint(x: start.x, y: start.y+direction*48)
            send(.leftMouseDragged, freed, in: browser.sidebar.rowsHost, browser: browser)
            XCTAssertTrue(browser.sidebar.drag!.isDetached)
            XCTAssertEqual(shadow.layer?.shadowOpacity, TabDragMotion.detachedShadowOpacity)
            XCTAssertNotNil(row.layer?.animation(forKey: TabDragMotion.springKey))
            let free = NSPoint(x: start.x+100, y: start.y+direction*90)
            send(.leftMouseDragged, free, in: browser.sidebar.rowsHost, browser: browser)
            XCTAssertEqual(row.convert(row.bounds, to: browser.sidebar.rowsHost).minY+18, free.y, accuracy: 0.01)
            send(.leftMouseDragged, start, in: browser.sidebar.rowsHost, browser: browser)
            XCTAssertFalse(browser.sidebar.drag!.isDetached)
            XCTAssertEqual(shadow.layer?.shadowOpacity, TabDragMotion.liftedShadowOpacity)
            send(.leftMouseUp, start, in: browser.sidebar.rowsHost, browser: browser)
            XCTAssertEqual(shadow.layer?.shadowOpacity, 0, "The lifted shadow goes as the row lands: Kero's chosen row draws its own")
            XCTAssertEqual(browser.tabs.map(\.id), order)
            browser.sidebar.finishReturningTab()
            XCTAssertEqual(row.frame, slot)
        }
        XCTAssertEqual(releases, 1)
    }
    @MainActor func testReleasedHoverClearsOnTheFirstPointerMoveBeforeTheSpringFinishes() throws {
        let browser = browser(); defer { clean(browser) }
        _ = browser.addTab(); let tab = browser.addTab(); _ = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tab.id]!, slot = row.frame
        let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        row.mouseEntered(with: NSEvent())
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        send(.leftMouseDragged, NSPoint(x: start.x, y: start.y+4), in: browser.sidebar.rowsHost, browser: browser)
        send(.leftMouseUp, NSPoint(x: start.x, y: start.y+4), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertNotNil(browser.sidebar.returningDrag)
        XCTAssertTrue(row.isHovered); XCTAssertNil(row.dragFill)
        send(.mouseMoved, NSPoint(x: slot.maxX+50, y: slot.midY), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertFalse(row.isHovered)
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0, "No drag fill masks the exit while the return spring is running")
        XCTAssertNotNil(browser.sidebar.returningDrag, "Hover does not wait for return cleanup")
    }
    @MainActor func testDetachedReturnFadesItsBackgroundToTheReleaseHoverStateBeforeLanding() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); _ = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tab.id]!
        let start = row.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
        row.mouseEntered(with: NSEvent())
        send(.leftMouseDown, NSPoint(x: 50, y: 18), in: row, browser: browser)
        // The last drag position is still inside the landing slot; release is outside it.
        send(.leftMouseDragged, NSPoint(x: start.x+60, y: start.y), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertNotNil(row.dragFill)
        send(.leftMouseUp, NSPoint(x: 600, y: start.y), in: browser.sidebar.rowsHost, browser: browser)
        XCTAssertNotNil(browser.sidebar.returningDrag)
        XCTAssertNil(row.dragFill); XCTAssertFalse(row.isHovered)
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0)
        let fade = try XCTUnwrap(row.layer?.animation(forKey: TabDragMotion.backgroundKey) as? CABasicAnimation)
        let from = try XCTUnwrap(fade.fromValue) as! CGColor
        let to = try XCTUnwrap(fade.toValue) as! CGColor
        XCTAssertGreaterThan(from.alpha, 0)
        XCTAssertEqual(to.alpha, 0)
        XCTAssertEqual(fade.duration, TabDragMotion.shadowOutDuration)
        browser.update()
        XCTAssertNotNil(row.layer?.animation(forKey: TabDragMotion.backgroundKey), "Page updates cannot interrupt the return's background fade")
        browser.sidebar.finishReturningTab()
        row.refreshHover(at: browser.sidebar.rowsHost.convert(NSPoint(x: 600, y: start.y), to: nil))
        XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0)
        XCTAssertNil(row.layer?.animation(forKey: TabDragMotion.backgroundKey))
    }
}
