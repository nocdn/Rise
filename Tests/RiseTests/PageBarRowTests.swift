import XCTest
import AppKit
@testable import Rise

/// The page's buttons and the pinned extensions in one row at the page bar's end, the extensions'
/// shortcuts and their order by Control-dragging, and answering a site's prompt from the keyboard.
@MainActor final class PageBarRowTests: XCTestCase {
    private func browser() -> (BrowserController, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "Rise.PageBarRowTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        browser.window?.setContentSize(NSSize(width: 900, height: 650))
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com")
        browser.showWindow(nil); browser.update(); browser.root.layoutSubtreeIfNeeded()
        return (browser, defaults, suite)
    }
    private func clean(_ browser: BrowserController, _ defaults: UserDefaults, _ suite: String) {
        browser.permissionCoordinator.cancel(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
        browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite)
    }
    private func event(_ type: NSEvent.EventType, x: CGFloat, in bar: PlainNavBar, control: Bool = true) -> NSEvent {
        let point = bar.convert(NSPoint(x: x, y: PlainNavBar.Metrics.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: control ? .control : [], timestamp: 0,
                                  windowNumber: bar.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testThePagesButtonsSitLeftOfTheExtensionsAsTheyDoShowingWithoutHover() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        let bar = browser.navBar
        let extensions = ["a", "b"].map { SidebarExtensionButton(extensionID: $0, action: {}) }
        bar.extensionButtons = extensions; bar.layoutSubtreeIfNeeded()
        let row: [NSView] = [bar.settingsButton, bar.copyButton] + extensions
        XCTAssertTrue(row.allSatisfy { $0.frame.size == NSSize(width: 28, height: 28) }, "\(row.map(\.frame))")
        for (left, right) in zip(row, row.dropFirst()) {
            XCTAssertEqual(right.frame.midX-left.frame.midX, PlainNavBar.Metrics.extensionStride, accuracy: 0.01)
        }
        XCTAssertEqual(bar.bounds.width-extensions[1].frame.midX, PlainNavBar.Metrics.extensionInset, accuracy: 0.01)
        XCTAssertEqual(bar.settingsButton.frame.midX-bar.fieldRect.maxX, PlainNavBar.Metrics.fieldEndGap, accuracy: 0.01,
                       "The field ends before the row")
        // Hidden until the pointer's on the address or their own place, as they were in the field.
        func move(to x: CGFloat) {
            let point = bar.convert(NSPoint(x: x, y: PlainNavBar.Metrics.midY), to: nil)
            bar.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: bar.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        }
        XCTAssertFalse(bar.isHovered)
        XCTAssertEqual(bar.settingsButton.alphaValue, 0); XCTAssertEqual(bar.copyButton.alphaValue, 0)
        XCTAssertFalse(bar.settingsButton.allowsInteraction)
        move(to: bar.copyButton.frame.midX)
        XCTAssertTrue(bar.isHovered && bar.settingsButton.allowsInteraction && bar.copyButton.allowsInteraction, "Their own place shows them")
        move(to: bar.fieldRect.maxX+2)
        XCTAssertTrue(bar.isHovered, "And between the field and them, so they stay crossing over")
        move(to: extensions[0].frame.midX)
        XCTAssertFalse(bar.isHovered || bar.copyButton.allowsInteraction, "Not the extensions")
        move(to: bar.fieldRect.midX)
        XCTAssertTrue(bar.isHovered && bar.settingsButton.allowsInteraction)
        XCTAssertFalse(bar.settingsButton.frame.intersects(bar.fieldRect))
        XCTAssertTrue(bar.zoomButton.isHidden)
    }

    func testControlDraggingAnExtensionMovesItAlongTheRowAndKeepsTheOrder() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        let bar = browser.navBar
        let extensions = ["a", "b", "c"].map { id in SidebarExtensionButton(extensionID: id, action: {}) }
        for button in extensions {
            button.onDragStart = { [weak bar, weak button] event in if let button { bar?.beginExtensionDrag(button, event: event) } }
            button.onDragMove = { [weak bar] event in bar?.moveExtensionDrag(event) }
            button.onDragEnd = { [weak bar] in bar?.endExtensionDrag() }
        }
        bar.extensionButtons = extensions; bar.layoutSubtreeIfNeeded()
        var crossings = 0, saved: [String]?
        bar.crossingClick = { crossings += 1 }
        bar.onReorderExtensions = { saved = $0 }
        let first = extensions[0], start = first.frame.midX
        // Without Control it opens, as a click does, and doesn't move.
        var opened = 0
        first.actionBlock = { opened += 1 }
        first.mouseDown(with: event(.leftMouseDown, x: start, in: bar, control: false))
        XCTAssertEqual(opened, 1)
        first.mouseDown(with: event(.leftMouseDown, x: start, in: bar))
        first.mouseDragged(with: event(.leftMouseDragged, x: start+2, in: bar))
        XCTAssertFalse(bar.isDraggingExtension, "Not until it has moved 3 pt")
        first.mouseDragged(with: event(.leftMouseDragged, x: start+10, in: bar))
        XCTAssertTrue(bar.isDraggingExtension); XCTAssertEqual(opened, 1, "Dragging doesn't open it")
        XCTAssertEqual(first.frame.midX, start+10, accuracy: 0.01, "It stays under the pointer")
        XCTAssertEqual(first.frame.minY, extensions[1].frame.minY, "Only along the row")
        first.mouseDragged(with: event(.leftMouseDragged, x: start+2*PlainNavBar.Metrics.extensionStride, in: bar))
        XCTAssertEqual(bar.extensionButtons.map(\.extensionID), ["b", "c", "a"])
        XCTAssertEqual(crossings, 1, "One tick for the slot it crossed into")
        first.mouseDragged(with: event(.leftMouseDragged, x: start+400, in: bar))
        XCTAssertEqual(first.frame.minX, bar.bounds.width-PlainNavBar.Metrics.extensionInset-14, accuracy: 0.01, "No further than the row's end")
        XCTAssertNil(saved, "Kept once let go")
        first.mouseUp(with: event(.leftMouseUp, x: start+400, in: bar))
        XCTAssertFalse(bar.isDraggingExtension)
        XCTAssertEqual(saved, ["b", "c", "a"])
        // The others make room on a spring and it springs into its place; all land there.
        let end = Date().addingTimeInterval(2)
        while Date() < end, bar.extensionButtons.enumerated().contains(where: { abs($0.element.frame.midX-(bar.bounds.width-PlainNavBar.Metrics.extensionInset-PlainNavBar.Metrics.extensionStride*CGFloat(2-$0.offset))) > 0.01 }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        for (index, button) in bar.extensionButtons.enumerated() {
            XCTAssertEqual(button.frame.midX, bar.bounds.width-PlainNavBar.Metrics.extensionInset-PlainNavBar.Metrics.extensionStride*CGFloat(2-index), accuracy: 0.01)
        }
    }

    func testTheShownOrderIsSavedAroundPinnedExtensionsThatArentShowing() {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        defaults.set(["a", "gone", "b", "c"], forKey: BrowserController.pinnedExtensionsKey)
        browser.setPinnedExtensionOrder(["c", "a", "b"])
        XCTAssertEqual(browser.pinnedExtensions, ["c", "gone", "a", "b"])
    }

    func testOptionShiftNumbersAreThePinnedExtensionsFromTheLeft() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        var opened: [String] = []
        browser.navBar.extensionButtons = ["a", "b"].map { id in SidebarExtensionButton(extensionID: id) { opened.append(id) } }
        func key(_ number: Int) -> NSEvent {
            // ⌥⇧ on the number row types the shifted character, as a keyboard does.
            let shifted = Array("!@#$%^&*(")[number-1]
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
                                    windowNumber: browser.window!.windowNumber, context: nil, characters: "⁄", charactersIgnoringModifiers: String(shifted),
                                    isARepeat: false, keyCode: [18, 19, 20, 21, 23, 22, 26, 28, 25][number-1])!
        }
        XCTAssertTrue(browser.handleTabSwitchEvent(key(1))); XCTAssertTrue(browser.handleTabSwitchEvent(key(2)))
        XCTAssertEqual(opened, ["a", "b"])
        XCTAssertFalse(browser.handleTabSwitchEvent(key(3)), "With no third, the key goes on to the page")
        XCTAssertEqual(browser.keyboardShortcuts.bindings("openPinnedExtension1").first?.display, "⌥⇧1")
    }

    func testThePromptsAllowAndDontAllowHaveKeys() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        let tab = try XCTUnwrap(browser.selectedTab), origin = try XCTUnwrap(SitePermissions.origin(tab.url))
        let coordinator = browser.permissionCoordinator
        var replies: [Bool] = []
        func wait(_ done: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func key(_ shortcut: String) -> NSEvent {
            let binding = KeyboardShortcut(shortcut)!
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: binding.modifiers, timestamp: 0, windowNumber: browser.window!.windowNumber,
                                    context: nil, characters: binding.key, charactersIgnoringModifiers: binding.key, isARepeat: false,
                                    keyCode: binding.key == "\r" ? 36 : 51)!
        }
        XCTAssertFalse(browser.handleTabSwitchEvent(key("Command+Alt+Enter")), "Nothing asking, the keys are the page's")
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        wait { coordinator.isShowingPrompt }
        XCTAssertEqual(coordinator.panel.allowButton.hoverHint?.shortcut, "⌘⌥↩")
        XCTAssertEqual(coordinator.panel.denyButton.hoverHint?.shortcut, "⌘⌥⌫")
        XCTAssertTrue(browser.handleTabSwitchEvent(key("Command+Alt+Backspace")))
        XCTAssertEqual(replies, [false])
        wait { !coordinator.panel.isLeaving }
        coordinator.request(in: tab.page.view, origin: origin, capabilities: [.camera]) { replies.append($0) }
        wait { coordinator.isShowingPrompt }
        XCTAssertTrue(browser.handleTabSwitchEvent(key("Command+Alt+Enter")))
        XCTAssertEqual(replies, [false, true])
        XCTAssertEqual(browser.sitePermissions.permission(.camera, origin: origin), .allow)
    }
}
