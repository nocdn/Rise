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
    @MainActor func testTheMinimalNewTabPlusSitsByTheTrafficLightsInPlaceOfTheRow() throws {
        let suite = "minimal-new-tab-\(UUID())", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: preferences)
        browser.showWindow(nil); defer { clean(browser) }
        let tab = browser.addTab(); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar, plus = sidebar.titlebarNewTab, row = try XCTUnwrap(sidebar.rows[tab.id])
        func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        let lights = inWindow(try XCTUnwrap(browser.window?.standardWindowButton(.closeButton)))
        XCTAssertTrue(sidebar.newTab.isHidden)
        XCTAssertEqual(inWindow(plus).midX, inWindow(sidebar.archiveButton).midX)
        XCTAssertEqual(inWindow(plus).midY, lights.midY)
        XCTAssertEqual(row.convert(row.bounds, to: sidebar).minY, SidebarView.addresslessTop, "The tabs start where the row was")
        for theme in [RiseTheme.neutral, .dark] {
            browser.chooseTheme(theme); browser.navBar.setNeedsDisplay(browser.navBar.bounds)
            XCTAssertEqual(plus.contentTintColor, theme.newTabPlus, "Its ink is the sidebar's own, not the page bar's")
        }
        // The titlebar is over the sidebar there; the plus is in it, so a click reaches it.
        let middle = NSPoint(x: inWindow(plus).midX, y: inWindow(plus).midY)
        XCTAssertTrue(browser.window?.contentView?.superview?.hitTest(middle) === plus)
        plus.performClick(nil)
        XCTAssertTrue(browser.palette.isPresented, "It does what New Tab does")
        browser.hidePalette()

        browser.setRiseSetting("minimalNewTab", false)
        XCTAssertFalse(sidebar.newTab.isHidden); XCTAssertTrue(plus.isHidden)
        XCTAssertEqual(row.convert(row.bounds, to: sidebar).minY, sidebar.newTab.frame.maxY+TabAppearance.spacing)
        XCTAssertEqual(preferences.object(forKey: BrowserController.minimalNewTabKey) as? Bool, false)
    }
    @MainActor func testSearchingTabsLeavesTheMatchesAndChoosingOneShowsThemAllWithItSelected() throws {
        let browser = browser(); defer { clean(browser) }
        let titles = ["GitLab merge request", "Calendar", "GitHub pull request", "Mail"]
        let tabs = titles.map { title in let tab = browser.addTab(); tab.title = title; return tab }
        browser.reorderTabs(tabs.map(\.id)); browser.select(tabs[1].id); browser.update(); browser.root.layoutSubtreeIfNeeded()
        let sidebar: SidebarView = browser.sidebar, search = sidebar.searchRow
        let listTop = sidebar.scroll.frame.minY
        func shown() -> [UUID] { tabs.map(\.id).filter { sidebar.rows[$0]?.isHidden == false } }
        func press(_ command: Selector) { _ = search.control(search.field, textView: NSTextView(), doCommandBy: command) }

        browser.searchTabs()
        XCTAssertFalse(search.isHidden)
        XCTAssertEqual(search.frame, NSRect(x: TabAppearance.inset, y: listTop, width: sidebar.bounds.width-2*TabAppearance.inset, height: TabAppearance.height))
        XCTAssertEqual(sidebar.scroll.frame.minY, listTop+TabAppearance.height+TabSearchRow.gap, "The tabs make room, a little apart from it")
        XCTAssertTrue(browser.window?.firstResponder === search.field.currentEditor())

        search.field.stringValue = "git"; search.onChange?("git")
        XCTAssertEqual(shown(), [tabs[0].id, tabs[2].id])
        XCTAssertEqual(sidebar.rows[tabs[2].id]?.frame.minY, TabAppearance.height+TabAppearance.spacing, "The matches close up")
        press(#selector(NSResponder.moveDown(_:))); press(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(sidebar.rows[tabs[2].id]?.isKeyboardFocused, true)
        XCTAssertEqual(sidebar.rows[tabs[0].id]?.isKeyboardFocused, false)
        // One row is lit at a time: the one the pointer or the keys moved to last.
        let first = try XCTUnwrap(sidebar.rows[tabs[0].id]), second = try XCTUnwrap(sidebar.rows[tabs[2].id])
        let pointer = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: first.convert(NSPoint(x: 40, y: 17), to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        XCTAssertTrue(first.hoverFocuses, "Hovering alone doesn't light a row while searching")
        first.mouseEntered(with: pointer)
        XCTAssertEqual([first.isKeyboardFocused, second.isKeyboardFocused], [true, false], "The pointer takes over")
        press(#selector(NSResponder.moveDown(_:)))
        XCTAssertEqual([first.isKeyboardFocused, second.isKeyboardFocused], [false, true], "The keys go on from it")
        first.mouseMoved(with: pointer)
        XCTAssertEqual([first.isKeyboardFocused, second.isKeyboardFocused], [true, false], "Moving again, the pointer takes back over")
        first.mouseExited(with: pointer)
        XCTAssertEqual([first.isKeyboardFocused, second.isKeyboardFocused], [false, false], "Off the tabs, nothing is lit")
        press(#selector(NSResponder.moveDown(_:))); press(#selector(NSResponder.moveDown(_:)))
        press(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(browser.selectedTab?.id, tabs[2].id)
        XCTAssertFalse(sidebar.isSearchingTabs); XCTAssertTrue(search.isHidden)
        XCTAssertEqual(shown(), tabs.map(\.id), "Every tab is back")
        XCTAssertEqual(sidebar.rows[tabs[2].id]?.isKeyboardFocused, false)
        XCTAssertFalse(first.hoverFocuses, "Hovering lights rows again")
        XCTAssertEqual(sidebar.scroll.frame.minY, listTop)

        browser.searchTabs(); search.field.stringValue = "mail"; search.onChange?("mail")
        XCTAssertEqual(shown(), [tabs[3].id])
        press(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(shown(), tabs.map(\.id)); XCTAssertEqual(browser.selectedTab?.id, tabs[2].id, "Escape keeps the tab that was selected")
    }
    @MainActor func testTheSidebarsScrollBarIsAThinBarThatCanStillBeGrabbedAndDarkensOnHover() throws {
        let browser = browser(); defer { clean(browser) }
        for _ in 0..<40 { _ = browser.addTab() }
        browser.root.layoutSubtreeIfNeeded(); browser.sidebar.scroll.flashScrollers()
        let scroller = try XCTUnwrap(browser.sidebar.scroll.verticalScroller as? ThinScroller)
        XCTAssertEqual(scroller.bar.width, GmailScroller.thickness, "The hover cards' bar")
        XCTAssertEqual(scroller.controlSize, .small)
        XCTAssertTrue(scroller.rect(for: .knob).contains(scroller.bar), "Drawn inside the knob's place, nothing cut off")
        let middle = scroller.convert(NSPoint(x: scroller.bar.midX, y: scroller.bar.midY), to: nil)
        XCTAssertTrue(browser.window?.contentView?.superview?.hitTest(middle) === scroller, "Grabbing it reaches the scroller")
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: middle, modifierFlags: [], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        scroller.mouseMoved(with: move)
        XCTAssertTrue(scroller.hovered)
        XCTAssertGreaterThan(GmailScroller.color(hovered: true).alphaComponent, GmailScroller.color(hovered: false).alphaComponent)
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
    @MainActor func testMoveCurrentTabToTopPreservesSelectionSavesAndUndoes() throws {
        let browser = browser(); defer { clean(browser) }
        browser.window?.setContentSize(NSSize(width: 900, height: 600))
        let current = browser.addTab()
        for _ in 0..<30 { browser.addTab() }
        browser.select(current.id); browser.root.layoutSubtreeIfNeeded()
        let before = browser.tabs.map(\.id), page = current.page.view
        let row = try XCTUnwrap(browser.sidebar.rows[current.id])
        row.scrollToVisible(row.bounds)
        XCTAssertGreaterThan(browser.sidebar.scroll.contentView.bounds.minY, 0)

        browser.moveCurrentTabToTop()

        let moved = [current.id] + before.filter { $0 != current.id }
        XCTAssertEqual(browser.tabs.map(\.id), moved)
        XCTAssertEqual(browser.sidebar.orderedIDs, moved)
        XCTAssertEqual(browser.selectedID, current.id)
        XCTAssertTrue(current.page.view === page)
        XCTAssertTrue(browser.sidebar.rows[current.id] === row)
        XCTAssertEqual(browser.sidebar.scroll.contentView.bounds.minY, 0)
        browser.saveNow()
        XCTAssertEqual(SessionStorage.read(from: browser.sessionURL)?.tabs.map(\.id), moved)
        XCTAssertFalse(browser.canMoveCurrentTabToTop)
        browser.moveCurrentTabToTop()
        let undo = try XCTUnwrap(browser.window?.undoManager)
        undo.undo(); XCTAssertEqual(browser.tabs.map(\.id), before, "Repeating at the top adds no undo step")
        undo.redo(); XCTAssertEqual(browser.tabs.map(\.id), moved)
    }
    @MainActor func testMoveCurrentTabToTopKeepsPinnedTilesSeparate() {
        let browser = browser(); defer { clean(browser) }
        let current = browser.addTab(), other = browser.addTab(), pin = browser.addTab(), nextPin = browser.addTab()
        browser.pinTab(pin.id); browser.pinTab(nextPin.id)
        browser.select(current.id); browser.moveCurrentTabToTop()
        XCTAssertEqual(browser.tabs.map(\.id), [pin.id, nextPin.id, current.id, other.id])
        XCTAssertEqual(browser.sidebar.orderedIDs, [current.id, other.id])
        XCTAssertFalse(current.pinned)
        browser.select(nextPin.id); browser.moveCurrentTabToTop()
        XCTAssertEqual(browser.tabs.map(\.id), [nextPin.id, pin.id, current.id, other.id])
        XCTAssertTrue(nextPin.pinned)
        XCTAssertEqual(browser.selectedID, nextPin.id)
        XCTAssertFalse(browser.canMoveCurrentTabToTop)
    }
    @MainActor func testMoveCurrentTabToTopMovesEitherSplitHalfTogether() {
        let browser = browser(); defer { clean(browser) }
        let left = browser.addTab(), right = browser.addTab(), other = browser.addTab()
        browser.select(left.id); browser.showSplit(right)
        let groups = browser.splitGroups
        for tab in [left, right] {
            browser.reorderTabs([other.id, left.id], animated: false)
            browser.select(tab.id); browser.moveCurrentTabToTop()
            XCTAssertEqual(browser.tabs.map(\.id), [left.id, right.id, other.id])
            XCTAssertEqual(browser.sidebar.orderedIDs, [left.id, other.id])
            XCTAssertEqual(browser.splitGroups, groups)
            XCTAssertEqual(browser.selectedID, tab.id)
            XCTAssertFalse(browser.canMoveCurrentTabToTop)
        }
    }
    @MainActor func testMovingByOneRowKeepsSplitsTogetherAndPinnedTabsInTheirSection() {
        let browser = browser(); defer { clean(browser) }
        let first = browser.addTab(), left = browser.addTab(), right = browser.addTab(), last = browser.addTab()
        let pin = browser.addTab(), secondPin = browser.addTab()
        browser.pinTab(pin.id); browser.pinTab(secondPin.id)
        browser.select(left.id); browser.showSplit(right)
        browser.reorderTabs([first.id, left.id, last.id], animated: false)
        browser.select(right.id)
        browser.moveCurrentTabUp()
        XCTAssertEqual(browser.tabs.map(\.id), [pin.id, secondPin.id, left.id, right.id, first.id, last.id])
        XCTAssertFalse(browser.canMoveCurrentTab(by: -1))
        browser.moveCurrentTabUp()
        XCTAssertEqual(browser.sidebar.orderedIDs, [left.id, first.id, last.id])
        browser.moveCurrentTabDown(); browser.moveCurrentTabDown(); browser.moveCurrentTabDown()
        XCTAssertEqual(browser.sidebar.orderedIDs, [first.id, last.id, left.id])
        XCTAssertFalse(browser.canMoveCurrentTab(by: 1))
        XCTAssertEqual(browser.visibleTabIDs, [left.id, right.id])
        XCTAssertEqual(browser.selectedID, right.id)
        browser.select(pin.id); browser.moveCurrentTabDown(); browser.moveCurrentTabDown()
        XCTAssertEqual(browser.tabs.map(\.id), [secondPin.id, pin.id, first.id, last.id, left.id, right.id])
        XCTAssertTrue(pin.pinned)
        XCTAssertFalse(browser.canMoveCurrentTab(by: 1))
        browser.moveCurrentTabUp()
        XCTAssertEqual(browser.tabs.prefix(2).map(\.id), [pin.id, secondPin.id])
    }
    @MainActor func testMovingDownKeepsTheCurrentRowVisibleInAScrolledSidebar() throws {
        let browser = browser(); defer { clean(browser) }
        browser.window?.setContentSize(NSSize(width: 900, height: 600))
        for _ in 0..<30 { browser.addTab() }
        let current = browser.tabs[0]; browser.select(current.id)
        for _ in 0..<25 { browser.moveCurrentTabDown() }
        let row = try XCTUnwrap(browser.sidebar.displayedRow(for: current.id))
        XCTAssertTrue(browser.sidebar.scroll.contentView.bounds.contains(row.frame))
        XCTAssertGreaterThan(browser.sidebar.scroll.contentView.bounds.minY, 0)
        browser.saveNow()
        XCTAssertEqual(SessionStorage.read(from: browser.sessionURL)?.tabs.map(\.id), browser.tabs.map(\.id))
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
        XCTAssertEqual(firstFrame.minY, browser.sidebar.newTab.frame.minY, "The list starts where the New Tab row would be")
        XCTAssertEqual(firstFrame.width, browser.sidebar.newTab.frame.width)
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
        b.developer = true; b.favicon = NSImage(size:NSSize(width:16,height:16))
        browser.update(); browser.root.layoutSubtreeIfNeeded()
        let row = browser.sidebar.rows[b.id]!, web = b.page.view, icon = row.icon.image, background = row.plainBackground
        var clicks = 0; browser.sidebar.crossingClick = { clicks += 1 }
        browser.window!.sendEvent(event(.leftMouseDown,at:NSPoint(x:45,y:20),in:row))
        XCTAssertEqual(row.layer?.affineTransform().a,1)
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:45,y:10),in:browser.sidebar.rowsHost))
        XCTAssertEqual(browser.tabs.map(\.id),[b.id,d.id,c.id,a.id]); XCTAssertEqual(clicks,2)
        XCTAssertEqual(row.frame.minX,6); XCTAssertEqual(row.frame.height,TabAppearance.subtitleRowHeight)
        XCTAssertTrue(browser.sidebar.rows[b.id] === row); XCTAssertTrue(b.page.view === web); XCTAssertTrue(row.plainBackground === background)
        XCTAssertTrue(row.icon.image === icon); XCTAssertTrue(b.developer)
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
            row.pointerEnters()
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
        tab.open(URL(string: "https://example.com/")!, title: "New page title")
        let deadline = Date().addingTimeInterval(5)
        while tab.page.title != "New page title" && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
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
        XCTAssertEqual(row.layer?.affineTransform().a,1)
        browser.window!.sendEvent(event(.leftMouseDragged,at:NSPoint(x:700,y:18),in:row))
        XCTAssertTrue(browser.sidebar.drag?.isDetached == true)
        XCTAssertEqual(row.frame.size,frame.size); XCTAssertEqual(browser.tabs.map(\.id),[b.id,a.id])
        browser.window!.sendEvent(event(.leftMouseUp,at:NSPoint(x:700,y:18),in:row))
        XCTAssertNil(browser.sidebar.drag)
        browser.sidebar.finishReturningTab()
        XCTAssertEqual(row.frame,frame)
        XCTAssertEqual(row.layer?.affineTransform().a,1)
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
        XCTAssertGreaterThan(browser.sidebar.drag?.overlay?.shadowView.layer?.shadowOpacity ?? 0, 0)
        browser.sidebar.cancelTabInteractions()
        XCTAssertNil(browser.sidebar.dragScrollTimer); XCTAssertNil(browser.sidebar.drag)
    }
}
