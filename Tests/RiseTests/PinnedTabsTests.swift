import XCTest
import AppKit
@testable import Rise

final class PinnedTabsTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil); return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.sidebar.cancelTabInteractions(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func testRowsOfThreeShareTheirWidth() {
        XCTAssertEqual(PinnedLayout.frames(count: 1, width: 200), [NSRect(x: 0, y: 0, width: 200, height: 48)])
        XCTAssertEqual(PinnedLayout.frames(count: 2, width: 200).map(\.width), [97, 97])
        XCTAssertEqual(PinnedLayout.frames(count: 2, width: 200).last?.minX, 103)
        let five = PinnedLayout.frames(count: 5, width: 200)
        XCTAssertEqual(five.map(\.minY), [0, 0, 0, 54, 54])
        XCTAssertEqual(five.prefix(3).map(\.width), [63, 63, 63], "A full row is three across")
        XCTAssertEqual(five.suffix(2).map(\.width), [97, 97], "The last row's two stretch to fill it")
        XCTAssertEqual(PinnedLayout.height(count: 0), 0)
        XCTAssertEqual(PinnedLayout.height(count: 3), 56)
        XCTAssertEqual(PinnedLayout.height(count: 4), 110)
        XCTAssertEqual(PinnedLayout.slot(nearest: NSPoint(x: 190, y: 10), count: 3, width: 200), 2)
        XCTAssertEqual(PinnedLayout.slot(nearest: NSPoint(x: 10, y: 80), count: 4, width: 200), 3)
    }

    @MainActor func testPinnedTabsBecomeTilesFirstAndAtMostSix() throws {
        let browser = browser(); defer { clean(browser) }
        let tabs = (0..<8).map { _ in browser.addTab() }
        browser.reorderTabs(tabs.map(\.id)); browser.root.layoutSubtreeIfNeeded()
        browser.pinTab(tabs[3].id)
        XCTAssertEqual(browser.tabs.first?.id, tabs[3].id, "Pinned tabs lead the window's tabs")
        XCTAssertNotNil(browser.sidebar.pinnedView.tiles[tabs[3].id])
        XCTAssertNil(browser.sidebar.rows[tabs[3].id]?.superview, "Its row leaves the list")
        XCTAssertFalse(browser.sidebar.orderedIDs.contains(tabs[3].id))
        browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.sidebar.newTab.frame.minY, PinnedLayout.top+PinnedLayout.height(count: 1)-SidebarView.pinnedLift)
        browser.pinTab(tabs[5].id, at: 0)
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [tabs[5].id, tabs[3].id])
        for tab in [tabs[0], tabs[1], tabs[2], tabs[4]] { browser.pinTab(tab.id) }
        XCTAssertFalse(browser.canPinTab)
        browser.pinTab(tabs[6].id)
        XCTAssertFalse(tabs[6].pinned, "Six is the most")
        let menu = try XCTUnwrap(browser.makeTabMenu(tabs[6].id))
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == "Pin Tab" }).isEnabled)
        browser.reorderTabs([tabs[7].id, tabs[6].id])
        XCTAssertEqual(browser.tabs.suffix(2).map(\.id), [tabs[7].id, tabs[6].id])
        XCTAssertTrue(browser.tabs.prefix(6).allSatisfy(\.pinned), "Reordering the list keeps pinned tabs first")
        browser.unpinTab(tabs[3].id, at: 1)
        XCTAssertEqual(browser.tabs.suffix(3).map(\.id), [tabs[7].id, tabs[3].id, tabs[6].id])
        XCTAssertNil(browser.sidebar.pinnedView.tiles[tabs[3].id])
        XCTAssertTrue(browser.sidebar.rows[tabs[3].id]?.superview === browser.sidebar.rowsHost)
        browser.reorderPinnedTabs([tabs[4].id, tabs[5].id])
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [tabs[4].id, tabs[5].id])
        XCTAssertEqual(browser.sidebar.pinnedView.order.prefix(2), [tabs[4].id, tabs[5].id])
    }

    @MainActor func testDraggingARowAboveNewTabPinsIt() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(); browser.reorderTabs([a.id, b.id]); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar
        sidebar.crossingClick = {}; sidebar.detachmentClick = {}
        let row = try XCTUnwrap(sidebar.rows[b.id])
        browser.window!.sendEvent(event(.leftMouseDown, at: NSPoint(x: 45, y: 17), in: row))
        browser.window!.sendEvent(event(.leftMouseDragged, at: NSPoint(x: 45, y: 40), in: row))
        let above = NSPoint(x: 60, y: sidebar.newTab.frame.minY-4)
        browser.window!.sendEvent(event(.leftMouseDragged, at: above, in: sidebar))
        XCTAssertEqual(sidebar.drag?.pinSlot, 0)
        XCTAssertNotNil(sidebar.drag?.ghost)
        XCTAssertEqual(sidebar.orderedIDs, [a.id], "The list closes up behind it")
        XCTAssertEqual(sidebar.pinnedView.count, 1, "The grid opens a slot")
        browser.window!.sendEvent(event(.leftMouseUp, at: above, in: sidebar))
        XCTAssertNil(sidebar.drag)
        XCTAssertTrue(b.pinned)
        XCTAssertEqual(browser.tabs.map(\.id), [b.id, a.id])
    }

    /// Changing its mind, a tab grows back into its row without a bounce, its shadow fading
    /// in as it does.
    @MainActor func testARowDraggedBackDownGrowsBackWithItsShadow() async throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(); browser.reorderTabs([a.id, b.id]); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar
        sidebar.crossingClick = {}; sidebar.detachmentClick = {}
        let row = try XCTUnwrap(sidebar.rows[b.id])
        browser.window!.sendEvent(event(.leftMouseDown, at: NSPoint(x: 45, y: 17), in: row))
        browser.window!.sendEvent(event(.leftMouseDragged, at: NSPoint(x: 45, y: 40), in: row))
        browser.window!.sendEvent(event(.leftMouseDragged, at: NSPoint(x: 60, y: sidebar.newTab.frame.minY-4), in: sidebar))
        let ghost = try XCTUnwrap(sidebar.drag?.ghost), shadow = try XCTUnwrap(sidebar.drag?.overlay?.shadowView)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(shadow.alphaValue, 0, accuracy: 0.01, "A tile has no drag shadow")
        let below = sidebar.rowsHost.convert(NSPoint(x: 45, y: 17), to: sidebar)
        browser.window!.sendEvent(event(.leftMouseDragged, at: below, in: sidebar))
        XCTAssertNil(sidebar.drag?.pinSlot)
        var widths: [CGFloat] = [], alphas: [CGFloat] = []
        while sidebar.drag?.ghost != nil, widths.count < 200 {
            try await Task.sleep(for: .milliseconds(8))
            widths.append(ghost.frame.width); alphas.append(shadow.alphaValue)
            XCTAssertEqual(shadow.frame, ghost.frame, "The shadow keeps the tile's shape")
        }
        XCTAssertNil(sidebar.drag?.ghost, "The row takes over once it has grown")
        XCTAssertLessThanOrEqual(widths.max() ?? 0, row.frame.width+0.01, "It doesn't overshoot")
        XCTAssertGreaterThan(alphas.filter { $0 > 0.05 && $0 < 0.95 }.count, 3, "The shadow fades in")
        XCTAssertEqual(shadow.alphaValue, 1); XCTAssertEqual(row.alphaValue, 1)
        browser.window!.sendEvent(event(.leftMouseUp, at: below, in: sidebar))
    }

    @MainActor func testDraggingATileDownToTheListUnpinsItThere() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(); browser.reorderTabs([a.id, b.id])
        browser.pinTab(b.id); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar
        sidebar.crossingClick = {}; sidebar.detachmentClick = {}

        let tile = try XCTUnwrap(sidebar.pinnedView.tiles[b.id])
        browser.window!.sendEvent(event(.leftMouseDown, at: NSPoint(x: 40, y: 20), in: tile))
        browser.window!.sendEvent(event(.leftMouseDragged, at: NSPoint(x: 40, y: 30), in: tile))
        XCTAssertNotNil(sidebar.pinnedDrag)
        let below = sidebar.rowsHost.convert(NSPoint(x: 60, y: 60), to: sidebar)
        browser.window!.sendEvent(event(.leftMouseDragged, at: below, in: sidebar))
        XCTAssertEqual(sidebar.pinnedDrag?.listIndex, 1)
        XCTAssertTrue(tile.rowStyle)
        XCTAssertEqual(sidebar.pinnedView.count, 0, "The grid closes behind it")
        browser.window!.sendEvent(event(.leftMouseUp, at: below, in: sidebar))
        XCTAssertNil(sidebar.pinnedDrag)
        XCTAssertFalse(b.pinned)
        XCTAssertEqual(browser.tabs.map(\.id), [a.id, b.id])
    }

    /// A tile springs to its new size with a slight overshoot, its favicon and countdown
    /// centred in it at every step.
    @MainActor func testTilesSpringToTheirSizeWithTheirContentsCentred() async throws {
        _ = NSApplication.shared
        // A display link only ticks for a window on a screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0.01; window.orderBack(nil); defer { window.orderOut(nil) }
        let tile = PinnedTabTile(tabID: UUID())
        window.contentView?.addSubview(tile)
        tile.frame = NSRect(x: 6, y: 0, width: 97, height: 48); tile.setBadge("in 17m"); tile.layoutSubtreeIfNeeded()
        var widths: [CGFloat] = [], done = false
        tile.move(to: NSRect(x: 6, y: 0, width: 63, height: 48)) { done = true }
        let deadline = Date().addingTimeInterval(2)
        while !done, Date() < deadline {
            try await Task.sleep(for: .milliseconds(8))
            widths.append(tile.frame.width)
            XCTAssertEqual(tile.icon.frame.midX, tile.bounds.midX, accuracy: 1, "The favicon stays centred as the tile narrows")
            XCTAssertEqual(tile.badge.frame.midX, tile.bounds.midX, accuracy: 1)
        }
        XCTAssertTrue(done)
        XCTAssertEqual(tile.frame.width, 63)
        XCTAssertLessThan(widths.min() ?? 63, 62.5, "It overshoots a little")
        XCTAssertGreaterThan(widths.min() ?? 0, 55, "but only a little")
        XCTAssertGreaterThan(widths.filter { $0 > 63.5 }.count, 3, "It takes a few frames, not one")
        done = false
        tile.rowStyle = true
        tile.move(to: NSRect(x: 6, y: 0, width: 203, height: 34)) { done = true }
        while !done, Date() < deadline.addingTimeInterval(2) { try await Task.sleep(for: .milliseconds(8)) }
        XCTAssertEqual(tile.icon.frame.minX, 8, "As a row, its favicon leads")
        XCTAssertEqual(tile.title.alphaValue, 1)

        // Tiles making room don't bounce.
        done = false; widths = []
        tile.rowStyle = false
        tile.move(to: NSRect(x: 6, y: 0, width: 97, height: 48), bouncy: false) { done = true }
        while !done, Date() < deadline.addingTimeInterval(4) { try await Task.sleep(for: .milliseconds(8)); widths.append(tile.frame.width) }
        XCTAssertTrue(done); XCTAssertGreaterThanOrEqual(widths.min() ?? 0, 97)

        // A row turning into a tile in hand, from rest, keeps its size on the way.
        done = false
        tile.frame = NSRect(x: 6, y: 0, width: 203, height: 34); tile.rowStyle = true
        try await Task.sleep(for: .milliseconds(400))
        tile.rowStyle = false
        tile.follow(size: NSSize(width: 63, height: 48)) { _ in NSPoint(x: 6, y: 0) }
        var sizes: [NSSize] = []
        for _ in 0..<60 { try await Task.sleep(for: .milliseconds(8)); sizes.append(tile.frame.size) }
        XCTAssertGreaterThan(sizes.map(\.width).min() ?? 0, 50, "It never collapses to nothing")
        XCTAssertEqual(tile.frame.width, 63, accuracy: 0.5); XCTAssertEqual(tile.frame.height, 48, accuracy: 0.5)
    }

    /// However tiles are dragged about, each comes to rest in its slot.
    @MainActor func testTilesGrowUpwardForACalendarCountdownAndBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); browser.pinTab(tab.id); browser.root.layoutSubtreeIfNeeded()
        let grid = browser.sidebar.pinnedView, tile = try XCTUnwrap(grid.tiles[tab.id])
        let bottom = grid.frame.maxY, newTab = browser.sidebar.newTab.frame.minY
        XCTAssertEqual(tile.frame.height, PinnedLayout.compactHeight, "Without a countdown, tiles are compact")
        for (badge, height) in [("in 15m", PinnedLayout.tileHeight), (nil, PinnedLayout.compactHeight)] {
            tile.setBadge(badge)
            let deadline = Date().addingTimeInterval(2)
            while tile.frame.height != height, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(tile.frame.height, height)
            XCTAssertEqual(grid.frame.maxY, bottom, "The grid keeps its bottom, growing upward")
            XCTAssertEqual(browser.sidebar.newTab.frame.minY, newTab, "What's below stays put")
        }
    }
    @MainActor func testTilesKeepUpWithTheSidebarWideningForControlCommand() async throws {
        let browser = browser(); defer { browser.endSidebarPeek(); clean(browser) }
        let tabs = (0..<3).map { _ in browser.addTab() }
        tabs.forEach { browser.pinTab($0.id) }; browser.root.layoutSubtreeIfNeeded()
        let grid = browser.sidebar.pinnedView
        func lag() -> CGFloat { grid.bounds.width-PinnedLayout.sideInset-(tabs.compactMap { grid.tiles[$0.id]?.frame.maxX }.max() ?? 0) }
        browser.beginSidebarPeek()
        var worst: CGFloat = 0
        let start = Date()
        while Date().timeIntervalSince(start) < 0.4 { worst = max(worst, abs(lag())); try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(browser.sidebar.bounds.width, SidebarWidth.ideal+20, "The sidebar widened")
        XCTAssertLessThan(worst, 2, "The tiles follow its width, rather than springing after it")
    }
    @MainActor func testTilesSettleInTheirSlotsAfterReordering() async throws {
        let browser = browser(); defer { clean(browser) }
        let tabs = (0..<5).map { _ in browser.addTab() }
        browser.reorderTabs(tabs.map(\.id))
        for tab in tabs { browser.pinTab(tab.id) }
        browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar, grid = sidebar.pinnedView
        sidebar.crossingClick = {}; sidebar.detachmentClick = {}
        func settled() -> [String] {
            let frames = grid.slotFrames(width: grid.bounds.width)
            return grid.order.enumerated().compactMap { index, id in
                let tile = grid.tiles[id]!
                return tile.superview === grid && tile.frame == frames[index] ? nil : "\(index): \(tile.frame) not \(frames[index]) moving \(tile.isMoving) in \(String(describing: tile.superview))"
            }
        }
        for (from, to) in [(0, 4), (4, 1), (3, 0), (2, 4), (1, 3)] {
            let frames = grid.slotFrames(width: grid.bounds.width)
            // Taken where it's shown, which may be on its way back into its slot.
            let tile = grid.tiles[grid.order[from]]!
            let start = grid.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), from: tile)
            browser.window!.sendEvent(event(.leftMouseDown, at: start, in: grid))
            var point = start
            for step in 1...12 {
                let t = CGFloat(step)/12
                point = NSPoint(x: start.x+(frames[to].midX-start.x)*t, y: start.y+(frames[to].midY-start.y)*t)
                browser.window!.sendEvent(event(.leftMouseDragged, at: point, in: grid))
                try await Task.sleep(for: .milliseconds(16))
            }
            XCTAssertTrue(sidebar.pinnedDrag?.tile === tile, "Drag \(from) to \(to)")
            XCTAssertEqual(tile.layer?.backgroundColor?.alpha, 1, "A tile in hand hides the tiles it crosses")
            browser.window!.sendEvent(event(.leftMouseUp, at: point, in: grid))
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(settled(), [])
        XCTAssertTrue(grid.tiles.values.filter { !$0.selected }.allSatisfy { ($0.layer?.backgroundColor?.alpha ?? 1) < 1 }, "At rest, the sidebar shows through")
    }

    /// Pin and Unpin from the menu carry the tab to its new place rather than jumping.
    @MainActor func testMenuPinningCarriesTheTabThereAndBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(); browser.reorderTabs([a.id, b.id]); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar
        func ghosts() -> [PinnedTabTile] {
            browser.window!.contentView!.subviews.compactMap { $0 as? TabDragOverlay }.flatMap { $0.subviews.compactMap { $0 as? PinnedTabTile } }
        }
        let row = try XCTUnwrap(sidebar.rows[b.id])
        let start = row.convert(row.bounds, to: nil)
        browser.togglePin(b.id)
        XCTAssertTrue(b.pinned)
        let ghost = try XCTUnwrap(ghosts().first, "A tile sets off from the row")
        XCTAssertEqual(ghost.convert(ghost.bounds, to: nil), start)
        let tile = try XCTUnwrap(sidebar.pinnedView.tiles[b.id])
        XCTAssertEqual(tile.alphaValue, 0, "The tile shows once it arrives")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(ghosts().isEmpty); XCTAssertEqual(tile.alphaValue, 1)

        browser.select(a.id); browser.root.layoutSubtreeIfNeeded()
        let tileFrame = tile.convert(tile.bounds, to: nil)
        browser.togglePin(b.id)
        XCTAssertFalse(b.pinned)
        let back = try XCTUnwrap(ghosts().first, "and back again")
        XCTAssertEqual(back.convert(back.bounds, to: nil), tileFrame)
        XCTAssertEqual(row.alphaValue, 0)
        // It lands looking like the row at rest, not one held under the pointer.
        var alphas: [CGFloat] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(8))
            if let color = back.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), back.shape > 0.99 { alphas.append(color.alphaComponent) }
        }
        XCTAssertLessThan(alphas.last ?? 1, 0.2, "The held fill fades away on the way")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertTrue(ghosts().isEmpty); XCTAssertEqual(row.alphaValue, 1)
        XCTAssertEqual(browser.tabs.map(\.id), [b.id, a.id], "Unpinned, it goes to the top of the list")
    }
}
