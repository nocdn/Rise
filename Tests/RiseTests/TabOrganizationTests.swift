import XCTest
import AppKit
import WebKit
import RiseCore
@testable import Rise

final class TabOrganizationTests: XCTestCase {
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil); return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.sidebar.cancelTabInteractions(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }
    @MainActor func testCleanUpBringsEachSitesTabsTogetherAndUndoes() throws {
        let browser = browser(); defer { clean(browser) }
        let urls = ["https://gitlab.com/a", "https://jira.example.com/1", "", "https://www.gitlab.com/b", "https://jira.example.com/2", "https://gitlab.com/c"]
        let tabs = urls.map { url in
            let tab = browser.addTab(); tab.requestedURL = URL(string: url); return tab
        }
        browser.reorderTabs(tabs.map(\.id)); browser.root.layoutSubtreeIfNeeded()
        tabs.forEach { browser.sidebar.rows[$0.id]?.layer?.removeAllAnimations() }
        let moving = { tabs.filter { browser.sidebar.rows[$0.id]?.layer?.animation(forKey: TabListMotion.movementKey) != nil } }
        browser.cleanUpTabs()
        let cleaned = [0, 3, 5, 1, 4, 2].map { tabs[$0].id }
        XCTAssertEqual(browser.tabs.map(\.id), cleaned)
        XCTAssertTrue(moving().isEmpty, "Sorting lands at once")
        let undo = try XCTUnwrap(browser.window?.undoManager)
        undo.undo()
        XCTAssertEqual(browser.tabs.map(\.id), tabs.map(\.id), "Undo restores the order from before")
        XCTAssertTrue(moving().isEmpty, "Undoing lands at once")
        undo.redo()
        XCTAssertEqual(browser.tabs.map(\.id), cleaned, "Redo cleans up again")
    }
    @MainActor func testNewTabsAppearAtTopWhileExistingRowsMoveTogetherAndCloseCollapsesTogether() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab()
        b.developer = true; browser.update(); browser.root.layoutSubtreeIfNeeded()
        let aRow = browser.sidebar.rows[a.id]!, bRow = browser.sidebar.rows[b.id]!
        let aFrame = aRow.frame, bFrame = bRow.frame
        let c = browser.addTab(); browser.root.layoutSubtreeIfNeeded()
        let cRow = browser.sidebar.rows[c.id]!
        XCTAssertEqual(browser.tabs.map(\.id), [c.id,b.id,a.id])
        XCTAssertEqual(cRow.frame.minY,0); XCTAssertEqual(cRow.frame.height,34)
        let firstFrame = cRow.convert(cRow.bounds, to: browser.sidebar)
        XCTAssertEqual(firstFrame.minY-browser.sidebar.newTab.frame.maxY, TabAppearance.spacing)
        XCTAssertEqual(firstFrame.width, browser.sidebar.newTab.frame.width)
        XCTAssertEqual(firstFrame.height, browser.sidebar.newTab.frame.height)
        XCTAssertNil(cRow.layer?.animation(forKey:TabListMotion.movementKey), "The new row is immediately visible in its final position")
        XCTAssertEqual(aRow.frame.minY,aFrame.minY+37); XCTAssertEqual(bRow.frame.minY,bFrame.minY+37)
        let aMove = try XCTUnwrap(aRow.layer?.animation(forKey:TabListMotion.movementKey) as? CABasicAnimation)
        let bMove = try XCTUnwrap(bRow.layer?.animation(forKey:TabListMotion.movementKey) as? CABasicAnimation)
        XCTAssertEqual(aMove.beginTime,bMove.beginTime,accuracy:0.0001); XCTAssertEqual(aMove.duration,0.18)
        browser.closeTab(c.id); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(aRow.frame,aFrame); XCTAssertEqual(bRow.frame,bFrame)
        XCTAssertNotNil(aRow.layer?.animation(forKey:TabListMotion.movementKey)); XCTAssertNotNil(bRow.layer?.animation(forKey:TabListMotion.movementKey))
        XCTAssertEqual(bRow.frame.height,TabAppearance.subtitleRowHeight, "Developer tabs use the shared subtitle layout")
        XCTAssertTrue(browser.sidebar.rows[a.id] === aRow)
    }
    @MainActor func testVerticalDragCrossesBothWaysWithOneHapticPerNeighborAndPreservesEverything() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(), c = browser.addTab(), d = browser.addTab()
        b.developer = true; b.pinned = true; b.favicon = NSImage(size:NSSize(width:16,height:16))
        browser.update(); browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[b.id]!, web = b.webView, icon = row.icon.image, loading = row.loadingBackground
        var clicks = 0; browser.sidebar.crossingClick = { clicks += 1 }
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:45,y:20),in:row))
        XCTAssertEqual(row.layer?.affineTransform().a,1)
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:45,y:10),in:browser.sidebar.rowsHost))
        XCTAssertEqual(browser.tabs.map(\.id),[b.id,d.id,c.id,a.id]); XCTAssertEqual(clicks,2)
        XCTAssertEqual(row.frame.minX,6); XCTAssertEqual(row.frame.height,TabAppearance.subtitleRowHeight)
        XCTAssertTrue(browser.sidebar.rows[b.id] === row); XCTAssertTrue(b.webView === web); XCTAssertTrue(row.loadingBackground === loading)
        XCTAssertTrue(row.icon.image === icon); XCTAssertTrue(b.developer && b.pinned)
        XCTAssertEqual(browser.selectedID,d.id, "Dragging an inactive tab must preserve its selected styling")
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:45,y:500),in:browser.sidebar.rowsHost))
        XCTAssertEqual(browser.tabs.map(\.id),[d.id,c.id,a.id,b.id]); XCTAssertEqual(clicks,5)
        browser.window!.sendEvent(event(.leftMouseUp,at:NSPoint(x:45,y:500),in:browser.sidebar.rowsHost))
        XCTAssertNil(browser.sidebar.drag); XCTAssertNil(browser.sidebar.dragScrollTimer)
        browser.sidebar.finishReturningTab()
        XCTAssertEqual(row.layer?.affineTransform().a,1); XCTAssertEqual(row.frame,browser.sidebar.targetFrames[b.id])
        XCTAssertEqual(browser.selectedID,d.id)
    }
    @MainActor func testDroppingInsideTheHeldRowButOutsideItsFinalSlotClearsHover() throws {
        let browser = browser(); defer { clean(browser) }
        _ = browser.addTab()
        let dragged = browser.addTab(), selected = browser.addTab()
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[dragged.id]!, slot = row.frame
        for offset: CGFloat in [-20, 20] {
            row.layer?.removeAllAnimations()
            row.mouseEntered(with: NSEvent())
            browser.window!.sendEvent(event(.leftMouseDown, at: NSPoint(x: 45, y: 18), in: row))
            let release = NSPoint(x: 45, y: slot.minY + 18 + offset)
            browser.window!.sendEvent(event(.leftMouseDragged, at: release, in: browser.sidebar.rowsHost))
            XCTAssertTrue(row.isHovered)
            XCTAssertEqual(row.layer?.backgroundColor?.alpha, 1, "The held inactive row is opaque")
            XCTAssertTrue(row.convert(row.bounds, to: browser.sidebar.rowsHost).contains(release))
            XCTAssertFalse(slot.contains(release))
            browser.window!.sendEvent(event(.leftMouseUp, at: release, in: browser.sidebar.rowsHost))
            XCTAssertEqual(row.convert(row.bounds, to: browser.sidebar.rowsHost), slot)
            XCTAssertFalse(row.isHovered, "Hover follows the final slot, not the position before release")
            browser.sidebar.finishReturningTab()
            XCTAssertNil(row.dragFill)
            XCTAssertEqual(row.layer?.backgroundColor?.alpha, 0)
            XCTAssertEqual(browser.selectedID, selected.id)
        }
    }
    @MainActor func testSplitPairsDragAsOneAndEscapeRestoresTheirOriginalOrder() throws {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right); browser.root.layoutSubtreeIfNeeded()
        let group = browser.splitGroups[0], pair = browser.sidebar.splitRows[group.id]!
        let original = browser.sidebar.orderedIDs
        var clicks = 0; browser.sidebar.crossingClick = { clicks += 1 }
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:20,y:15),in:pair.right))
        XCTAssertEqual(pair.layer?.affineTransform().a,1)
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:45,y:8),in:browser.sidebar.rowsHost))
        XCTAssertEqual(browser.sidebar.orderedIDs,[left.id,other.id]); XCTAssertEqual(clicks,1)
        XCTAssertEqual(browser.splitGroups,[group]); XCTAssertTrue(pair.left === browser.sidebar.rows[left.id]); XCTAssertTrue(pair.right === browser.sidebar.rows[right.id])
        browser.window!.cancelOperation(nil)
        XCTAssertEqual(browser.sidebar.orderedIDs,original); XCTAssertNil(browser.sidebar.drag)
        XCTAssertEqual(browser.splitGroups,[group]); XCTAssertEqual(browser.visibleTabIDs,[left.id,right.id])
    }
    @MainActor func testInlineRenameSelectsAllKeepsGeometryAndCommitsImmediatelyWithoutLosingItOnReload() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.title = "Original title"; browser.update(); browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[tab.id]!, frame = row.frame, titleFrame = row.titleField.frame, font = row.titleField.font
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:50,y:18),in:row,clicks:2))
        XCTAssertTrue(row.isRenaming)
        let editor = try XCTUnwrap(row.titleField.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(),NSRange(location:0,length:"Original title".utf16.count))
        XCTAssertEqual(row.frame,frame); XCTAssertEqual(row.titleField.frame,titleFrame); XCTAssertEqual(row.titleField.font,font)
        XCTAssertNil(row.layer?.animation(forKey:"Rise.TabPress"))
        editor.string = "My workspace"
        browser.update(); XCTAssertEqual(editor.string,"My workspace", "Page updates cannot overwrite the in-progress name")
        XCTAssertTrue(row.control(row.titleField,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(row.isRenaming); XCTAssertEqual(tab.customTitle,"My workspace"); XCTAssertEqual(row.titleField.stringValue,"My workspace")
        XCTAssertEqual(row.frame,frame); XCTAssertEqual(row.titleField.frame,titleFrame); XCTAssertEqual(row.titleField.font,font)
        tab.webView.loadHTMLString("<title>New page title</title>",baseURL:nil)
        let deadline = Date().addingTimeInterval(5)
        while tab.webView.title != "New page title" && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        tab.changed(); XCTAssertEqual(tab.title,"My workspace")
        browser.saveNow(); let saved = try XCTUnwrap(SessionStorage.read(from:browser.sessionURL)?.tabs.first)
        XCTAssertEqual(saved.customTitle,"My workspace"); XCTAssertEqual(BrowserTab(saved:saved).title,"My workspace")
        row.beginRename(); let cancelEditor = try XCTUnwrap(row.titleField.currentEditor() as? NSTextView)
        cancelEditor.string = "Discard this"
        XCTAssertTrue(row.control(row.titleField,textView:cancelEditor,doCommandBy:#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(tab.title,"My workspace"); XCTAssertEqual(row.titleField.stringValue,"My workspace")
    }
    @MainActor func testPressHasNoScaleAndPullingRightDetachesWithoutReordering() throws {
        let browser = browser(); defer { clean(browser) }
        let a = browser.addTab(), b = browser.addTab(); browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[b.id]!, frame = row.frame
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:45,y:18),in:row))
        XCTAssertNil(row.layer?.animation(forKey:"Rise.TabPress"))
        XCTAssertEqual(row.layer?.affineTransform().a,1); XCTAssertEqual(browser.sidebar.selectedTabShadow.layer?.affineTransform().a,1)
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:700,y:18),in:row))
        XCTAssertTrue(browser.sidebar.drag?.isDetached == true)
        XCTAssertEqual(row.frame.size,frame.size); XCTAssertEqual(browser.tabs.map(\.id),[b.id,a.id])
        browser.window!.sendEvent(event(.leftMouseUp,at:NSPoint(x:700,y:18),in:row))
        XCTAssertNil(browser.sidebar.drag)
        browser.sidebar.finishReturningTab()
        XCTAssertEqual(row.frame,frame)
        XCTAssertEqual(row.layer?.affineTransform().a,1); XCTAssertEqual(browser.sidebar.selectedTabShadow.layer?.affineTransform().a,1)
    }
    @MainActor func testHoldingNearTheViewportEdgeAutoscrollsWithoutClippingTheHeldTab() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.window?.setContentSize(NSSize(width: 900, height: 600))
        for _ in 0..<30 { browser.addTab() }
        browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[browser.selectedID!]!
        browser.sidebar.crossingClick = {}
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:45,y:18),in:row))
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:45,y:browser.sidebar.scroll.contentView.bounds.maxY-6),in:browser.sidebar.rowsHost))
        let timer = try XCTUnwrap(browser.sidebar.dragScrollTimer)
        XCTAssertTrue(timer.isValid)
        timer.fire()
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertGreaterThan(browser.sidebar.scroll.contentView.bounds.minY,0)
        XCTAssertTrue(browser.sidebar.scroll.contentView.bounds.contains(row.convert(row.bounds, to: browser.sidebar.rowsHost)))
        XCTAssertTrue(browser.sidebar.selectedTabShadow.isHidden, "The held row supplies its own shadow above the scroller")
        XCTAssertGreaterThan(browser.sidebar.drag?.overlay?.shadowView.layer?.shadowOpacity ?? 0, 0)
        browser.sidebar.cancelTabInteractions()
        XCTAssertNil(browser.sidebar.dragScrollTimer); XCTAssertNil(browser.sidebar.drag)
    }
}
