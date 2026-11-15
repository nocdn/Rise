import XCTest
import AppKit
import RiseCore
@testable import Rise

final class SplitDropTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.window?.setContentSize(NSSize(width: 1500, height: 940))
        return browser
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.splitDrop.finish()
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.page.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func event(_ type: NSEvent.EventType, at point: NSPoint, in browser: BrowserController) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: browser.window!.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    /// A point across the page, `u` of the way along it and halfway down, in the window.
    @MainActor func page(_ u: CGFloat, _ browser: BrowserController, v: CGFloat = 0.5) -> NSPoint {
        let body = browser.splitDrop.host.frame
        return browser.root.convert(NSPoint(x: body.minX+body.width*u, y: body.minY+body.height*v), to: nil)
    }
    @MainActor func settle(_ browser: BrowserController) { for _ in 0..<180 { browser.splitDrop.step(1/120) } }
    @MainActor func startDrag(_ tab: BrowserTab, in browser: BrowserController) throws -> NSPoint {
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        browser.sidebar.beginTabDrag(tab.id, event: event(.leftMouseDown, at: start, in: browser))
        return start
    }
    @MainActor func move(to point: NSPoint, _ browser: BrowserController) {
        browser.sidebar.moveTabDrag(event(.leftMouseDragged, at: point, in: browser))
    }

    @MainActor func testTheTargetsWaitBesideTheSidebarOpenOverThePageAndTheNearerLights() throws {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), dragged = browser.addTab()
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        let start = try startDrag(dragged, in: browser)
        let drop = browser.splitDrop, left = drop.left, right = drop.right
        XCTAssertEqual(drop.phase, .waiting)
        XCTAssertEqual(left.opacity.value, 0, "They come in from nothing")
        settle(browser)
        let host = drop.host.bounds, unit = left.unit
        XCTAssertGreaterThan(unit, 0.5)
        let rest = NSSize(width: 313*unit, height: 517*unit), inset = 36*unit
        // Waiting, smaller, their outer edges where they'll be at rest, centred down the page.
        XCTAssertEqual(left.shownFrame.width, rest.width*0.62, accuracy: 1)
        XCTAssertEqual(left.shownFrame.minX, inset, accuracy: 1)
        XCTAssertEqual(right.shownFrame.maxX, host.width-inset, accuracy: 1)
        XCTAssertEqual(left.shownFrame.midY, host.midY, accuracy: 1)
        XCTAssertEqual(left.opacity.value, 1, accuracy: 0.01)

        // Just onto the page from the sidebar, the left one doesn't light yet; a little further in, it does.
        move(to: NSPoint(x: start.x+60, y: start.y), browser)
        move(to: page(0.02, browser), browser)
        XCTAssertEqual(drop.phase, .open); XCTAssertNil(drop.lit, "Not at once, coming from the sidebar")
        move(to: page(0.07, browser), browser); XCTAssertNil(drop.lit)
        move(to: page(0.15, browser), browser); XCTAssertEqual(drop.lit, .left, "Past the safe area")
        move(to: NSPoint(x: start.x+60, y: start.y), browser); XCTAssertNil(drop.lit)
        move(to: page(0.02, browser), browser); XCTAssertNil(drop.lit, "Again, each time it comes from the sidebar")

        // Over the middle of the page, they open out.
        move(to: page(0.5, browser), browser); settle(browser)
        XCTAssertEqual(drop.phase, .open); XCTAssertNil(drop.lit)
        XCTAssertEqual(left.shownFrame.size.width, rest.width, accuracy: 1)
        XCTAssertEqual(left.shownFrame.size.height, rest.height, accuracy: 1)
        XCTAssertEqual(left.shownFrame.minX, inset, accuracy: 1)

        // Coming its way, the left one's drawn toward the pointer, before it lights.
        move(to: page(0.36, browser), browser); settle(browser)
        XCTAssertNil(drop.lit)
        XCTAssertGreaterThan(left.shownFrame.minX, inset+10*unit); XCTAssertLessThan(left.shownFrame.minX, inset+25*unit+1)
        XCTAssertEqual(right.shownFrame.maxX, host.width-inset, accuracy: 1, "The far one stays")

        // A third of the way in, it lights: bigger, and 60% of the way to the pointer.
        let pointer = NSPoint(x: host.width*0.25, y: host.height*0.3)
        move(to: page(0.25, browser, v: 0.3), browser); settle(browser)
        XCTAssertEqual(drop.lit, .left); XCTAssertTrue(left.isLit); XCTAssertFalse(right.isLit)
        XCTAssertEqual(left.shownFrame.width, rest.width*1.145, accuracy: 1)
        let restCenter = NSPoint(x: inset+rest.width/2, y: host.midY)
        XCTAssertEqual(left.shownFrame.midX, restCenter.x+(pointer.x-restCenter.x)*0.6, accuracy: 1)
        XCTAssertEqual(left.shownFrame.midY, restCenter.y+(pointer.y-restCenter.y)*0.6, accuracy: 1)
        // It stays lit a little past where it lit, then goes out.
        move(to: page(0.35, browser), browser); XCTAssertEqual(drop.lit, .left)
        move(to: page(0.4, browser), browser); XCTAssertNil(drop.lit)
        move(to: page(0.7, browser), browser); XCTAssertEqual(drop.lit, .right)

        // Back over the sidebar, they wait again, and the row shows instead of its page's picture.
        move(to: start, browser); settle(browser)
        XCTAssertEqual(drop.phase, .waiting); XCTAssertNil(drop.lit)
        XCTAssertEqual(left.shownFrame.width, rest.width*0.62, accuracy: 1)

        // Let go there, they go, and nothing changes.
        browser.sidebar.endTabDrag(at: start)
        settle(browser)
        XCTAssertEqual(drop.phase, .hidden)
        XCTAssertTrue(browser.splitGroups.isEmpty)
        XCTAssertEqual(browser.selectedID, current.id)
        XCTAssertEqual(browser.sidebar.rows[dragged.id]?.alphaValue, 1)
    }

    @MainActor func testOverThePageTheRowBecomesItsPagesPicture() throws {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), dragged = browser.addTab()
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        let start = try startDrag(dragged, in: browser)
        move(to: NSPoint(x: start.x+60, y: start.y), browser)
        move(to: page(0.5, browser), browser); settle(browser)
        let row = try XCTUnwrap(browser.sidebar.rows[dragged.id])
        let overlay = try XCTUnwrap(row.superview)
        let picture = try XCTUnwrap(overlay.subviews.compactMap { $0 as? SplitDragPreview }.first)
        XCTAssertEqual(picture.alphaValue, 1, accuracy: 0.01); XCTAssertEqual(row.alphaValue, 0, accuracy: 0.01)
        let pointer = overlay.convert(page(0.5, browser), from: nil)
        XCTAssertEqual(picture.frame.midX, pointer.x, accuracy: 1); XCTAssertEqual(picture.frame.midY, pointer.y, accuracy: 1)
        XCTAssertEqual(picture.frame.width, SplitDragPreview.width, accuracy: 1)
        move(to: start, browser); settle(browser)
        XCTAssertEqual(picture.alphaValue, 0, accuracy: 0.01); XCTAssertEqual(row.alphaValue, 1, accuracy: 0.01)
        browser.sidebar.endTabDrag(at: start)
    }

    @MainActor func testLetGoOnATargetTheTabComesIntoThatHalfAndThePageStaysChosen() throws {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), dragged = browser.addTab(), other = browser.addTab()
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        let start = try startDrag(dragged, in: browser)
        move(to: NSPoint(x: start.x+60, y: start.y), browser)
        move(to: page(0.2, browser), browser); settle(browser)
        XCTAssertEqual(browser.splitDrop.lit, .left)
        browser.sidebar.endTabDrag(at: page(0.2, browser))
        let group = try XCTUnwrap(browser.splitGroups.first)
        XCTAssertEqual(group.leftID, dragged.id); XCTAssertEqual(group.rightID, current.id)
        XCTAssertEqual(browser.selectedID, current.id, "The page that was there stays chosen")
        XCTAssertNil(browser.pendingSplitDrop)
        let row = try XCTUnwrap(browser.sidebar.splitRows[group.id])
        XCTAssertTrue(row.left === browser.sidebar.rows[dragged.id] && row.right === browser.sidebar.rows[current.id])
        XCTAssertEqual(row.left.alphaValue, 1)
        XCTAssertTrue(dragged.page.view.superview === browser.pageClip && current.page.view.superview === browser.pageClip)
        XCTAssertLessThan(dragged.page.view.frame.minX, current.page.view.frame.minX)
        settle(browser)
        XCTAssertEqual(browser.splitDrop.phase, .hidden)
        XCTAssertEqual(browser.splitGroups.count, 1)
        _ = other

        // Undo takes it apart again, as after Split View.
        XCTAssertTrue(browser.undoSplit())
        XCTAssertTrue(browser.splitGroups.isEmpty); XCTAssertEqual(browser.selectedID, current.id)
    }

    @MainActor func testOnTheRightTheTabTakesTheRightHalf() throws {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), dragged = browser.addTab()
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        let start = try startDrag(dragged, in: browser)
        move(to: NSPoint(x: start.x+60, y: start.y), browser)
        move(to: page(0.85, browser), browser)
        browser.sidebar.endTabDrag(at: page(0.85, browser))
        let group = try XCTUnwrap(browser.splitGroups.first)
        XCTAssertEqual(group.leftID, current.id); XCTAssertEqual(group.rightID, dragged.id)
    }

    @MainActor func testLetGoInTheMiddleOrDraggingThePageItselfMakesNoSplit() throws {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), dragged = browser.addTab()
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        var start = try startDrag(dragged, in: browser)
        move(to: NSPoint(x: start.x+60, y: start.y), browser)
        move(to: page(0.5, browser), browser)
        browser.sidebar.endTabDrag(at: page(0.5, browser))
        XCTAssertTrue(browser.splitGroups.isEmpty); XCTAssertEqual(browser.selectedID, current.id)
        settle(browser)

        start = try startDrag(current, in: browser)
        XCTAssertEqual(browser.splitDrop.phase, .hidden, "The page can't go beside itself")
        browser.sidebar.endTabDrag(at: start)

        // Nor onto a split.
        let third = browser.addTab(); browser.select(current.id); browser.showSplit(dragged)
        start = try startDrag(third, in: browser)
        XCTAssertEqual(browser.splitDrop.phase, .hidden)
        browser.sidebar.endTabDrag(at: start)
    }

    @MainActor func testASplitsHalvesHaveNoFillUntilHovered() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(browser.sidebar.splitRows[try XCTUnwrap(browser.splitGroups.first).id])
        XCTAssertTrue(row.left.selected)
        XCTAssertEqual(row.left.layer?.backgroundColor, NSColor.clear.cgColor, "The chosen half isn't filled")
        XCTAssertEqual(row.right.layer?.backgroundColor, NSColor.clear.cgColor)
        let inside = row.left.convert(NSPoint(x: row.left.bounds.midX, y: row.left.bounds.midY), to: nil)
        row.left.mouseEntered(with: event(.mouseMoved, at: inside, in: browser))
        XCTAssertNotEqual(row.left.layer?.backgroundColor, NSColor.clear.cgColor, "Hovered, it's filled as other tabs are")
        XCTAssertFalse(row.left.close.isHidden)
    }
}
