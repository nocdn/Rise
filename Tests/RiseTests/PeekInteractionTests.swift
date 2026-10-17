import XCTest
import AppKit
@testable import Rise

final class PeekInteractionTests: XCTestCase {
    func testPeekResistanceIsContinuousAndNeverHardStopsAfterThreshold() {
        func progress(_ travel: Double) -> Double {
            var swipe = HistorySwipeState(); swipe.begin()
            _ = swipe.move(dx: travel, dy: 0, canBack: true, canForward: true)
            return BrowserController.peekVisualProgress(for: swipe.arrowPull)
        }
        XCTAssertEqual(progress(60), 0.5)
        XCTAssertEqual(progress(120), 1)
        XCTAssertGreaterThan(progress(180), 1.24, "The first extra pull should remain responsive instead of quickly stiffening")
        XCTAssertLessThan(abs(progress(120.001)-progress(119.999)), 0.0001)
        let near = progress(140), further = progress(260), far = progress(1000), beyond = progress(2000)
        XCTAssertGreaterThan(near, 1); XCTAssertGreaterThan(further, near)
        XCTAssertGreaterThan(far, further); XCTAssertGreaterThan(beyond, far, "Long swipes still move; there is no hard cap")
        XCTAssertLessThan(beyond, 1.5)
        XCTAssertLessThan((further-near)/120, (near-1)/20)
        XCTAssertLessThan((beyond-far)/1000, (far-further)/740)
    }

    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        return BrowserController(sessionURL: file, restore: false)
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.closePeek(); browser.historySwipe.cancel(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.suggestionFavicons.cancel()
        browser.window?.orderOut(nil)
    }
    @MainActor private func event(_ phase: NSEvent.Phase, x: Int32 = 0, momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -x, wheel3: 0)!
        let raw: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: raw)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testCommandWClosesPeekBeforeClosingSelectedTab() throws {
        let browser = browser(); defer { clean(browser) }
        let oldMenu = NSApp.mainMenu; defer { NSApp.mainMenu = oldMenu }
        let delegate = AppDelegate(); delegate.browser = browser; delegate.buildMenu()
        let other = browser.addTab(), source = browser.addTab()
        let tabIDs = browser.tabs.map(\.id), closedTabIDs = browser.closedTabs.map(\.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        XCTAssertNotNil(browser.peekTab)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))

        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        XCTAssertNil(browser.peekTab)
        XCTAssertNil(browser.peekCard)
        XCTAssertEqual(browser.tabs.map(\.id), tabIDs)
        XCTAssertEqual(browser.closedTabs.map(\.id), closedTabIDs)
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.window?.firstResponder === source.page.view)
        XCTAssertFalse(source.page.isCovered)

        XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key))
        XCTAssertFalse(browser.tabs.contains { $0.id == source.id })
        XCTAssertEqual(browser.closedTabs.last?.id, source.id)
        XCTAssertEqual(browser.selectedID, other.id)
    }
    @MainActor func testAPeekLinkInsideThePeekShakesThePillAndHistoryMovesThroughThePeek() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.showWindow(nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["source", "first", "second"].map { folder.appendingPathComponent("\($0).html") }
        for url in urls { try "<title>\(url.lastPathComponent)</title>Page".write(to: url, atomically: true, encoding: .utf8) }
        let source = browser.addTab(url: urls[0])
        try await wait { !source.page.isLoading && source.page.title == "source.html" }
        browser.showPeek(url: urls[1], from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab), card = try XCTUnwrap(browser.peekCard)
        try await wait { !peek.page.isLoading && peek.page.title == "first.html" && card.alphaValue == 1 }
        XCTAssertTrue(source.page.isCovered, "The page under the Peek takes no hover")

        // Shift over a link inside the Peek: the pill says it can't open one.
        browser.hoveredWebView = peek.page.view
        browser.linkStatus.show(urls[2], theme: browser.theme, peek: true, blocked: true)
        // Pressing the link reports its hover ending first; the pill holds on through the press.
        browser.showHoveredLink(nil, in: peek.page.view)
        XCTAssertFalse(browser.linkStatus.isHidden, "No blink between the press and the refusal")
        browser.showPeek(url: urls[2], from: peek.page.view)
        XCTAssertFalse(browser.linkStatus.isHidden)
        XCTAssertEqual(browser.linkStatus.accessibilityLabel(), "Cannot open \(urls[2].absoluteString) in Peek")
        XCTAssertTrue(browser.peekTab === peek, "Only one Peek: the open one stays")
        XCTAssertNotNil(browser.linkStatus.layer?.animation(forKey: "shake"), "The pill shakes its \"Cannot open\" instead")
        // Without a click, the held-back hide still happens.
        browser.showHoveredLink(nil, in: peek.page.view)
        try await wait { browser.linkStatus.isHidden }
        XCTAssertFalse(browser.peekHasNavigated)

        peek.load(urls[2])
        try await wait { !peek.page.isLoading && peek.page.title == "second.html" }
        XCTAssertTrue(browser.peekHasNavigated)
        XCTAssertTrue(browser.toolbarButtons[1].isEnabled, "Back follows the Peek's own pages")
        browser.goBack()
        try await wait { !peek.page.isLoading && peek.page.title == "first.html" }
        XCTAssertEqual(source.page.title, "source.html", "The tab underneath stays where it was")
        XCTAssertTrue(browser.toolbarButtons[2].isEnabled)
        browser.goForward()
        try await wait { !peek.page.isLoading && peek.page.title == "second.html" }

        browser.closePeek()
        XCTAssertFalse(source.page.isCovered, "The page takes hovers again once the Peek closes")
    }
    @MainActor func testNormalExpandHandsTheLivePageToTheTabAndBackReturnsWithoutReloading() async throws {
        let browser = browser(); defer { clean(browser) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["source", "target", "other"].map { folder.appendingPathComponent("\($0).html") }
        for url in urls { try "<title>\(url.lastPathComponent)</title>Page".write(to: url, atomically: true, encoding: .utf8) }
        let source = browser.addTab(url: urls[0])
        try await wait { source.page.title == "source.html" && !source.page.isLoading }
        // Load counts tell a page moved from one loaded again.
        let sourcePage = source.page.view, sourceBlank = try XCTUnwrap(source.page as? BlankPage), sourceLoads = sourceBlank.loadCount
        let count = browser.tabs.count
        browser.showPeek(url: urls[1], from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab), peekPage = peek.page.view
        try await wait { peek.page.title == "target.html" && !peek.page.isLoading }
        let peekBlank = try XCTUnwrap(peek.page as? BlankPage), peekLoads = peekBlank.loadCount

        browser.expandPeek(modifiers: [])
        XCTAssertTrue(source.page.view === peekPage, "The Peek's own page moves into the tab")
        XCTAssertFalse(source.page.isLoading); XCTAssertEqual(peekBlank.loadCount, peekLoads, "Not loaded again")
        XCTAssertEqual(browser.tabs.count, count); XCTAssertEqual(browser.selectedID, source.id); XCTAssertNil(browser.peekTab)
        XCTAssertTrue(peekPage.superview === browser.pageClip); XCTAssertNil(sourcePage.superview, "The page from before is held off screen")
        XCTAssertTrue(browser.toolbarButtons[1].isEnabled, "Back reaches the page from before")

        browser.goBack()
        XCTAssertTrue(source.page.view === sourcePage); XCTAssertEqual(source.title, "source.html")
        XCTAssertEqual(sourceBlank.loadCount, sourceLoads, "Back shows the held page as it was, without reloading")
        XCTAssertTrue(browser.toolbarButtons[2].isEnabled)
        browser.goForward()
        XCTAssertTrue(source.page.view === peekPage)
        XCTAssertEqual(peekBlank.loadCount, peekLoads)

        // Somewhere new from the page from before leaves the expanded page behind, as forward history goes.
        browser.goBack()
        source.load(urls[2])
        try await wait { source.page.title == "other.html" && !source.page.isLoading }
        XCTAssertTrue(source.forwardPages.isEmpty)
        browser.closeTab(source.id)
        XCTAssertTrue(source.backPages.isEmpty, "A closing tab lets go of the pages it held")
    }
    @MainActor func testBackFromAPageASiteOpenedInANewTabReturnsToTheTabThatOpenedIt() async throws {
        let browser = browser(); defer { clean(browser) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.html"), other = folder.appendingPathComponent("other.html")
        try "<title>target</title>Target".write(to: target, atomically: true, encoding: .utf8)
        try "<title>other</title>Other".write(to: other, atomically: true, encoding: .utf8)
        let start = folder.appendingPathComponent("source.html")
        try "<title>source</title><a target=_blank href='target.html'>Open</a>".write(to: start, atomically: true, encoding: .utf8)
        let source = browser.addTab(url: start)
        try await wait { source.page.title == "source" && !source.page.isLoading }
        browser.update()
        XCTAssertFalse(browser.toolbarButtons[1].isEnabled, "Nowhere to go back to")
        let count = browser.tabs.count
        // The page's target=_blank link, as the engine reports it.
        _ = source.page.onOpenElsewhere?(target, false)
        try await wait { browser.tabs.count == count+1 && browser.selectedID != source.id }
        let opened = try XCTUnwrap(browser.selectedTab)
        XCTAssertEqual(opened.returnsTo, source.id)
        browser.update()
        XCTAssertTrue(browser.toolbarButtons[1].isEnabled, "Back returns to the tab that opened it")
        XCTAssertTrue(browser.canNavigate(opened.page, .back), "And so does the swipe")

        // The new tab's own history still comes first.
        try await wait { opened.page.url != nil && !opened.page.isLoading }
        opened.load(other)
        try await wait { opened.page.title == "other" && !opened.page.isLoading }
        browser.goBack()
        try await wait { opened.page.url?.lastPathComponent == "target.html" && !opened.page.isLoading }
        XCTAssertEqual(browser.selectedID, opened.id); XCTAssertEqual(browser.tabs.count, count+1)

        browser.goBack()
        XCTAssertEqual(browser.selectedID, source.id, "Back to the page it was opened from")
        XCTAssertFalse(browser.tabs.contains { $0.id == opened.id }, "The opened page closes")
        XCTAssertEqual(browser.closedTabs.last?.id, opened.id, "It can be reopened like any closed tab")
        browser.update()
        XCTAssertFalse(browser.toolbarButtons[1].isEnabled)
    }
    @MainActor func testCommandExpandInsertsLivePeekImmediatelyAboveItsSource() throws {
        let browser = browser(); defer { clean(browser) }
        let bottom = browser.addTab(), source = browser.addTab(), top = browser.addTab()
        browser.select(source.id)
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab), web = peek.page.view
        browser.expandPeek(modifiers: .command)
        XCTAssertEqual(browser.tabs.map(\.id), [top.id, peek.id, source.id, bottom.id])
        XCTAssertEqual(browser.selectedID, peek.id); XCTAssertTrue(browser.selectedTab?.page.view === web)
        XCTAssertNil(browser.peekCard)
    }
    @MainActor func testNewWindowLinkKeepsNormalNewTabSemanticsWhenExpanded() throws {
        let browser = browser(); defer { clean(browser) }
        let source = browser.addTab(), top = browser.addTab()
        browser.select(source.id)
        XCTAssertTrue(browser.openModifiedLink(URL(string: "about:blank")!, modifiers: .shift,
                                             from: source.page.view, opensNewTab: true))
        let peek = try XCTUnwrap(browser.peekTab)
        browser.expandPeek(modifiers: [])
        XCTAssertEqual(browser.tabs.map(\.id), [top.id, peek.id, source.id])
        XCTAssertEqual(browser.selectedID, peek.id)
    }
    @MainActor func testPeekSwipeWorksWithoutPageHistoryAndReversalCancellationAndMomentumAreSafe() async throws {
        let browser = browser(); defer { clean(browser) }
        let page = BlankPage()
        page.title = "Peek"
        // The swipe's probe finds nothing on the page that takes the swipe itself.
        page.scriptAnswer = { $0 == HistorySwipeController.scrollProbe ? true : nil }
        XCTAssertFalse(page.canGoBack)
        let router = HistorySwipeController(window: browser.window as! BrowserWindow, pageAt: { _ in page }, feedback: { _, _, _, _ in })
        defer { router.cancel() }
        router.isPeekPage = { $0 === page }
        var clicks = 0, pulls = [Double](), releases = [Bool](), cancellations = 0
        router.thresholdClick = { clicks += 1 }
        router.dragPeek = { pulls.append($0) }; router.releasePeek = { releases.append($0) }
        router.cancelPeek = { cancellations += 1 }
        XCTAssertTrue(router.handle(event(.began, x: 60)))
        try await wait { router.gesture.consumesScroll }
        XCTAssertEqual(pulls.last, 0.5)
        XCTAssertTrue(router.handle(event(.changed, x: 65))); XCTAssertEqual(clicks, 1)
        XCTAssertTrue(router.handle(event(.changed, x: -20))); XCTAssertFalse(router.gesture.isArmed)
        XCTAssertTrue(router.handle(event(.ended))); XCTAssertEqual(releases, [false])
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        XCTAssertTrue(router.handle(event(.cancelled))); XCTAssertEqual(releases, [false, false])
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        router.cancel(); XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(router.handle(event(.began, x: 130)))
        try await wait { router.gesture.isArmed }
        XCTAssertTrue(router.handle(event(.ended))); XCTAssertEqual(releases, [false, false, true])
        XCTAssertTrue(router.handle(event([], x: 300, momentum: 1)))
        XCTAssertTrue(router.handle(event([], x: 300, momentum: 3)))
        XCTAssertEqual(releases.count, 3); XCTAssertEqual(clicks, 4)
        XCTAssertEqual(page.title, "Peek"); XCTAssertFalse(page.canGoBack)
    }

    @MainActor private func commandZEvent(_ browser: BrowserController) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                         windowNumber: browser.window!.windowNumber, context: nil, characters: "z",
                         charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)!
    }
    /// ⌘Z through the window, as a real key press goes.
    @MainActor private func commandZ(_ browser: BrowserController) -> Bool {
        (browser.window as! BrowserWindow).performKeyEquivalent(with: commandZEvent(browser))
    }
    /// Whether Rise takes ⌘Z for a Peek rather than leaving it to the page.
    @MainActor private func takesCommandZ(_ browser: BrowserController) -> Bool { browser.handlePeekUndoKey(commandZEvent(browser)) }
    @MainActor func testCommandZPutsAnExpandedPeekBackLiveAndReturnsTheTabToItsPage() async throws {
        let browser = browser(); defer { clean(browser) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("source.html"), targetURL = folder.appendingPathComponent("target.html")
        try "<title>Source</title>Source".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "<title>Target</title>Target".write(to: targetURL, atomically: true, encoding: .utf8)
        let source = browser.addTab(url: sourceURL)
        try await wait { source.page.title == "Source" && !source.page.isLoading }
        browser.showPeek(url: targetURL, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab)
        try await wait { peek.page.title == "Target" && !peek.page.isLoading }
        let sourcePage = source.page.view, peekPage = peek.page.view
        // Load counts tell a page moved from one loaded again.
        let sourceBlank = try XCTUnwrap(source.page as? BlankPage), peekBlank = try XCTUnwrap(peek.page as? BlankPage)
        let sourceLoads = sourceBlank.loadCount, peekLoads = peekBlank.loadCount
        browser.expandPeek(modifiers: [])
        XCTAssertTrue(source.page.view === peekPage); XCTAssertNil(browser.peekTab)

        XCTAssertTrue(commandZ(browser))
        XCTAssertTrue(browser.peekTab === peek && peek.page.view === peekPage, "The Peek comes back")
        XCTAssertEqual(peekBlank.loadCount, peekLoads, "It's the same page, not loaded again")
        XCTAssertTrue(source.page.view === sourcePage); XCTAssertEqual(source.title, "Source")
        XCTAssertEqual(sourceBlank.loadCount, sourceLoads, "The tab is back on its page at once, not reloaded")
        XCTAssertTrue(source.backPages.isEmpty && source.forwardPages.isEmpty, "Nothing is left held")
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertFalse(takesCommandZ(browser), "There's only one step to undo")
    }
    @MainActor func testCommandZUndoesANewTabExpandAndASplitOnlyForAShortWhile() async throws {
        let browser = browser(); defer { clean(browser); BrowserController.peekUndoDuration = 30 }
        _ = browser.addTab(); let source = browser.addTab()
        browser.select(source.id)
        let ids = browser.tabs.map(\.id)
        XCTAssertFalse(takesCommandZ(browser), "Nothing to undo yet, so ⌘Z goes on to the page")
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab)

        browser.expandPeek(modifiers: .command)
        XCTAssertEqual(browser.selectedID, peek.id)
        XCTAssertTrue(commandZ(browser))
        XCTAssertEqual(browser.tabs.map(\.id), ids); XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.peekTab === peek); XCTAssertNotNil(browser.peekCard)

        browser.splitPeek()
        XCTAssertEqual(browser.splitGroups.count, 1)
        XCTAssertTrue(commandZ(browser))
        XCTAssertTrue(browser.splitGroups.isEmpty); XCTAssertEqual(browser.tabs.map(\.id), ids)
        XCTAssertTrue(browser.peekTab === peek)

        BrowserController.peekUndoDuration = 0.05
        browser.splitPeek()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(takesCommandZ(browser), "The chance to undo runs out")
        XCTAssertEqual(browser.splitGroups.count, 1)
    }
    @MainActor func testSplitHandleMenuReturnsTheSameLivePeekAfterKeyboardUndoExpires() async throws {
        let browser = browser(); defer { clean(browser); BrowserController.peekUndoDuration = 30 }
        let source = browser.addTab()
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        let peek = try XCTUnwrap(browser.peekTab), page = peek.page.view
        BrowserController.peekUndoDuration = 0.03
        browser.splitPeek()
        let menu = browser.splitHandle.makeContextMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Return to Peek state"])
        XCTAssertTrue(menu.items[0].isEnabled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(browser.peekUndo, "The keyboard shortcut remains time-limited")
        XCTAssertTrue(browser.splitHandle.makeContextMenu().items[0].isEnabled)
        menu.performActionForItem(at: 0)
        XCTAssertTrue(browser.peekTab === peek && browser.peekTab?.page.view === page)
        XCTAssertTrue(browser.splitGroups.isEmpty)
        XCTAssertEqual(browser.tabs.map(\.id), [source.id]); XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.splitPeekReturns.isEmpty)
        XCTAssertFalse(browser.splitHandle.makeContextMenu().items[0].isEnabled)
    }
    @MainActor func testSplitHandleMenuRestoresOnlyItsOwnPairAndForgetsSeparatedPairs() throws {
        let browser = browser(); defer { clean(browser) }
        let source = browser.addTab()
        browser.showPeek(url: URL(string: "about:blank")!, from: source.page.view)
        browser.splitPeek()
        XCTAssertTrue(browser.canReturnSplitToPeek)
        let other = browser.addTab(), extra = browser.addTab()
        browser.showSplit(other)
        XCTAssertTrue(browser.splitHandle.makeContextMenu().items[0].isEnabled)
        XCTAssertTrue(browser.returnSplitToPeek())
        XCTAssertTrue(browser.peekTab === other, "A split without a promotion record returns its own right page")
        XCTAssertEqual(browser.selectedID, extra.id)
        browser.closePeek()
        browser.select(source.id)
        XCTAssertTrue(browser.canReturnSplitToPeek)
        browser.separateSplit(containing: source.id)
        XCTAssertTrue(browser.splitPeekReturns.isEmpty)
        XCTAssertTrue(browser.tabs.contains { $0 === extra })
    }
    @MainActor func testPeekControlsHoverSubtlyShrinkOnPressAndSlideOutFromBehindTheCard() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)); window.contentView = content
        let split = PeekControl(glyph: .split, title: "Split"), arrows = PeekControl(glyph: .arrows, title: "Expand")
        var pressed = 0; split.action = { pressed += 1 }
        for (index, control) in [split, arrows].enumerated() {
            control.frame = PeekControl.frame(cardMaxX: 50, top: 20+CGFloat(index)*44); control.applyTheme(.neutral)
            content.addSubview(control)
        }
        content.layoutSubtreeIfNeeded()
        let center = NSPoint(x: split.frame.minX+PeekControl.gap+PeekControl.side/2, y: split.frame.midY)
        XCTAssertTrue(split.hitTest(center) === split)
        XCTAssertNil(split.hitTest(NSPoint(x: split.frame.minX+4, y: split.frame.midY)), "The room beside the button takes no clicks")

        split.mouseEntered(with: NSEvent())
        XCTAssertEqual(split.washAlpha, 0.04, accuracy: 0.001, "A faint hover wash")
        XCTAssertTrue(split.isSwaying, "The divider sways on hover")
        arrows.mouseEntered(with: NSEvent())
        XCTAssertEqual(arrows.arrowSpread, 1.5, accuracy: 0.01, "The arrows spread like Picture in Picture's")

        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: content.convert(center, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        split.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertEqual(split.pressScale, PeekControl.pressedScale, accuracy: 0.001)
        split.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertEqual(split.pressScale, 1, accuracy: 0.001); XCTAssertEqual(pressed, 1)

        split.tuckBehindCard()
        XCTAssertTrue(split.isTucked)
        split.slideOut(after: 0.02)
        XCTAssertFalse(split.isTucked)
    }

    @MainActor func testTuckedControlsHideTheirShadowAndAlwaysComeBackWhereTheyRest() throws {
        let control = PeekControl(glyph: .cross, title: "Close")
        control.frame = PeekControl.frame(cardMaxX: 0, top: 20); control.layoutSubtreeIfNeeded()
        let rest = control.restingCenter
        XCTAssertEqual(rest.x, PeekControl.gap+PeekControl.side/2, accuracy: 0.01)
        control.tuckBehindCard()
        XCTAssertLessThan(PeekControl.gap+PeekControl.side+PeekControl.shadowReach+PeekControl.tuckedOffset, 0,
                          "Tucked, the shadow is past the clipping edge too, so no sliver of it shows")
        // Laying out mid-slide used to move where the button rests, leaving it out of sight once out.
        control.frame = PeekControl.frame(cardMaxX: 10, top: 20); control.needsLayout = true; control.layoutSubtreeIfNeeded()
        control.slideOut(after: 0)
        XCTAssertEqual(control.restingCenter.x, rest.x, accuracy: 0.01)
        XCTAssertFalse(control.isTucked)
        control.slideIn(after: 0)
        XCTAssertTrue(control.isTucked); XCTAssertNil(control.action, "A control going away takes no more clicks")
    }

    @MainActor func testLiveResizeFollowsTheSameBouncySpring() {
        let spring = BrowserController.peekPromoteSpring
        let samples = stride(from: 0.0, through: spring.perceptualDuration*1.5, by: 0.004).map { PeekLiveMotion.progress(at: $0, along: spring) }
        XCTAssertEqual(samples.first!, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(samples.max()!, 1.01, "It carries a little past the end")
        XCTAssertLessThan(samples.max()!, 1.06, "Only a little")
        XCTAssertEqual(samples.last!, 1, accuracy: 0.002, "And has all but settled when the motion ends")
    }

    @MainActor func testClosingPeekRestoresBackgroundWithoutBounceAndKeepsItsDuration() throws {
        let browser = browser(); defer { clean(browser) }
        let original = CASpringAnimation(perceptualDuration: 0.28, bounce: 0.38)
        let spring = BrowserController.peekPageReturnSpring
        browser.recedePage(true, along: nil)
        XCTAssertEqual(browser.pageShadow.layer!.transform.m11, BrowserController.peekPageScale, accuracy: 0.0001)
        browser.recedePage(false, along: spring)
        let animation = try XCTUnwrap(browser.pageShadow.layer?.animation(forKey: "peek.recede") as? CASpringAnimation)
        XCTAssertEqual(animation.duration, original.duration, accuracy: 0.000001)
        XCTAssertEqual(animation.perceptualDuration, original.perceptualDuration, accuracy: 0.000001)
        XCTAssertTrue(CATransform3DIsIdentity(browser.pageShadow.layer!.transform))
        let samples = stride(from: 0.0, through: animation.duration, by: 1.0/240).map {
            PeekLiveMotion.progress(at: $0, along: animation)
        }
        XCTAssertTrue(samples.allSatisfy { $0 >= 0 && $0 <= 1 }, "Never overshoots full size")
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "Never reverses into a bounce")
        XCTAssertEqual(samples.last!, 1, accuracy: 0.0001)
    }

    func testABounceNeverCarriesPastTheWindowsEdgesOnlyTowardTheSidebar() {
        let page = NSRect(x: 200, y: 6, width: 800, height: 600)
        // Overshooting by 4 on every side: only the left, beside the sidebar, may go past.
        let bounced = page.insetBy(dx: -4, dy: -4).limited(to: page, edges: .windowSides)
        XCTAssertEqual(bounced, NSRect(x: 196, y: 6, width: 804, height: 600))
        XCTAssertEqual(page.insetBy(dx: -4, dy: -4).limited(to: page, edges: [.windowSides, .left]), page, "With no sidebar beside it, the left stops too")
        XCTAssertEqual(page.insetBy(dx: 50, dy: 50).limited(to: page, edges: .windowSides), page.insetBy(dx: 50, dy: 50), "Anything inside is left alone")
    }
}
