import XCTest
import AppKit
@testable import Rise

final class DeveloperChromeTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.developerMotion.cancel(); browser.siteInfoPopover.close(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.page.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testPageBarMorphsIntoTheDeveloperBarInPlaceAndReversesWithoutJumping() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "http://localhost:3000")
        browser.showWindow(nil); browser.update(); browser.root.layoutSubtreeIfNeeded()
        browser.developerMotion.reduceMotion = { false }
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id]), titleY = row.titleField.frame.minY
        let bar = PlainNavBar.Metrics.height, viewport = tab.page.view.frame
        browser.toggleDeveloper()
        XCTAssertEqual(browser.navBar.developerProgress, 0, "Opening starts from the page bar")
        // The address is exchanged for developer mode's as a notice is.
        XCTAssertTrue(browser.navBar.showsDeveloperAddress)
        XCTAssertEqual(browser.navBar.text.alphaValue, 0); XCTAssertEqual(browser.developerAddress.alphaValue, 1)
        XCTAssertNotNil(browser.navBar.text.layer?.animation(forKey: "notice"))
        XCTAssertNotNil(browser.developerAddress.layer?.animation(forKey: "notice"))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(row.titleField.layer?.animation(forKey: TabListMotion.movementKey))
            XCTAssertNotNil(row.subtitle.layer?.animation(forKey: DeveloperModeMotion.subtitleFadeKey))
        }
        XCTAssertLessThan(row.titleField.frame.minY, titleY)
        try await Task.sleep(for: .milliseconds(80))
        let opening = browser.navBar.developerProgress
        XCTAssertGreaterThan(opening, 0); XCTAssertLessThan(opening, 1)
        // The developer bar is under the page bar, in its place, and the page doesn't move.
        XCTAssertFalse(browser.developerBar.isHidden)
        XCTAssertEqual(browser.developerBar.frame, browser.navBar.frame)
        XCTAssertEqual(tab.page.view.frame, viewport)
        browser.update()
        XCTAssertEqual(browser.navBar.developerProgress, opening, "Loading updates do not snap the ongoing motion")
        browser.toggleDeveloper()
        XCTAssertEqual(browser.navBar.developerProgress, opening, "Reversing continues from the visible position")
        let reversing = Date().addingTimeInterval(0.2)
        while browser.navBar.developerProgress >= opening && Date() < reversing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertLessThan(browser.navBar.developerProgress, opening)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.navBar.developerProgress, 0)
        XCTAssertFalse(browser.navBar.showsDeveloperAddress); XCTAssertEqual(browser.navBar.text.alphaValue, 1)
        XCTAssertEqual(tab.page.view.frame, browser.pageClip.bounds.divided(atDistance: bar, from: .minYEdge).remainder)
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertTrue(row.subtitle.isHidden)
        XCTAssertEqual(row.titleField.frame.minY, titleY)
    }
    @MainActor func testDeveloperBarTakesClicksTheStayingButtonsDoNot() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.developer = true
        tab.requestedURL = URL(string: "https://example.com/page")
        browser.update(); browser.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(browser.navBar.developerProgress, 1)
        func hit(_ view: NSView) -> NSView? {
            browser.pageClip.hitTest(browser.pageClip.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view))
        }
        XCTAssertTrue(hit(browser.developerAddress)?.isDescendant(of: browser.developerAddress) == true)
        XCTAssertTrue(hit(browser.devButtons[0])?.isDescendant(of: browser.devButtons[0]) == true)
        XCTAssertTrue(hit(browser.toolbarButtons[1])?.isDescendant(of: browser.toolbarButtons[1]) == true, "Back stays on the bar")
        XCTAssertGreaterThan(browser.developerAddress.frame.minX, browser.toolbarButtons[3].frame.maxX)
    }
    @MainActor func testHoldingTheShortcutTogglesOnce() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); browser.update()
        func press(repeating: Bool) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: repeating, keyCode: 2))
            browser.toggleDeveloperMode(from: event)
        }
        try press(repeating: false)
        XCTAssertTrue(tab.developer)
        try press(repeating: true); try press(repeating: true)
        XCTAssertTrue(tab.developer, "The key's repeats don't toggle it back and forth")
    }
    @MainActor func testTabSwitchCancelsDeveloperMotionAndReduceMotionShowsTheFinalLayoutImmediately() async throws {
        let browser = browser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab(), bar = PlainNavBar.Metrics.height
        browser.select(first.id); browser.showWindow(nil); browser.update()
        browser.developerMotion.reduceMotion = { false }
        browser.toggleDeveloperMode(for: second)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertTrue(second.developer)
        XCTAssertNil(browser.developerMotion.currentProgress)
        XCTAssertTrue(browser.developerBar.isHidden)
        browser.toggleDeveloperMode(for: second)
        browser.toggleDeveloperMode(for: first); browser.select(second.id)
        XCTAssertNil(browser.developerMotion.currentProgress)
        XCTAssertTrue(browser.developerBar.isHidden)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertEqual(second.page.view.frame.minY, bar)
        browser.developerMotion.reduceMotion = { true }
        browser.toggleDeveloper()
        XCTAssertNil(browser.developerMotion.currentProgress)
        XCTAssertEqual(browser.navBar.developerProgress, 1)
        XCTAssertEqual(second.page.view.frame.minY, bar); XCTAssertEqual(browser.developerBar.frame.minY, 0)
        browser.toggleDeveloper()
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertEqual(browser.navBar.developerProgress, 0)
    }
    @MainActor func testDeveloperDraftSurvivesBrowserUpdatesAndEscapeCancels() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.developer = true
        tab.requestedURL = URL(string: "https://example.com/original")
        browser.update()
        let field = browser.developerAddress
        XCTAssertTrue(field.isEditable); XCTAssertTrue(field.isSelectable)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("draft.example.com", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        browser.update()
        XCTAssertEqual(editor.string, "draft.example.com")
        XCTAssertNil(field.layer?.mask)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(field.stringValue, "https://example.com/original")
        XCTAssertEqual(tab.requestedURL?.absoluteString, "https://example.com/original")
        XCTAssertNil(field.currentEditor())
    }
    @MainActor func testReturnNavigatesEditedDeveloperAddressInTheSameTab() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.developer = true; browser.update()
        let file = browser.sessionURL.deletingLastPathComponent().appendingPathComponent("edited.html")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<!doctype html><title>Edited address</title><p>Loaded from the developer address field</p>".write(to: file, atomically: true, encoding: .utf8)
        browser.developerAddress.selectText(nil)
        let editor = try XCTUnwrap(browser.developerAddress.currentEditor() as? NSTextView)
        editor.insertText(file.path, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let deadline = Date().addingTimeInterval(10)
        while tab.page.title != "Edited address" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.page.title, "Edited address")
        XCTAssertEqual(tab.requestedURL, file)
        XCTAssertEqual(browser.selectedID, tab.id)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertNil(browser.developerAddress.currentEditor())
        XCTAssertEqual(browser.developerAddress.stringValue, file.absoluteString)
    }
    @MainActor func testSiteInformationUsesNativeTransientPopoverAndKeepsExistingDetails() throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.developer = true
        tab.requestedURL = URL(string: "https://example.com/page")
        browser.update()
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        browser.window?.orderFront(nil)
        browser.siteInfoPopover.animates = false
        browser.devButtons[4].performClick(nil)
        XCTAssertTrue(browser.siteInfoPopover.isShown)
        XCTAssertEqual(browser.siteInfoPopover.behavior, .transient)
        let content = try XCTUnwrap(browser.siteInfoPopover.contentViewController as? SiteInformationController)
        XCTAssertEqual(content.host.stringValue, "example.com")
        XCTAssertEqual(content.address.stringValue, "https://example.com/page")
        XCTAssertEqual(content.connection.stringValue, "This page uses an encrypted HTTPS connection.")
        XCTAssertEqual(content.engine.stringValue, "Rendering engine: Chromium")
        XCTAssertGreaterThan(browser.siteInfoPopover.contentSize.height, 100)
        XCTAssertEqual(browser.siteInfoPopover.contentSize.width, 340, accuracy: 1)
        browser.devButtons[4].performClick(nil)
        XCTAssertFalse(browser.siteInfoPopover.isShown)
    }
}

/// Developer mode's address, drawn in Ioskeley Mono: its ink, at rest and being edited.
final class DeveloperAddressInkTests: XCTestCase {
    /// Rows of the bar with ink in them, in points from its top, while focused or not.
    /// `nil` leaves the focus as it is.
    @MainActor func inkRows(_ browser: BrowserController, focused: Bool?) throws -> (rows: ClosedRange<CGFloat>, left: CGFloat) {
        let bar = browser.developerBar
        if focused == true { browser.developerAddress.selectText(nil); browser.developerAddress.currentEditor()?.selectedRange = NSRange(location: 0, length: 0) }
        else if focused == false { browser.window?.makeFirstResponder(nil) }
        bar.layoutSubtreeIfNeeded(); bar.displayIfNeeded()
        let rep = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        // Only the address: no stripes, buttons or hairline.
        let fill = bar.layer?.backgroundColor; bar.layer?.backgroundColor = NSColor.white.cgColor
        let hidden = bar.subviews.filter { $0 !== browser.developerAddress }; hidden.forEach { $0.isHidden = true }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        hidden.forEach { $0.isHidden = false }; bar.layer?.backgroundColor = fill
        let scale = CGFloat(rep.pixelsHigh)/bar.bounds.height
        let field = browser.developerAddress.frame
        var rows: [Int] = [], left = Int.max
        for y in 0..<rep.pixelsHigh {
            for x in Int(field.minX*scale)..<min(rep.pixelsWide, Int((field.minX+200)*scale)) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.6 { rows.append(y); left = min(left, x); break }
            }
        }
        let first = try XCTUnwrap(rows.first), last = try XCTUnwrap(rows.last)
        return (CGFloat(first)/scale...CGFloat(last+1)/scale, CGFloat(left)/scale)
    }
    @MainActor func testTheAddressIsCentredWholeAndStaysPutWhenEdited() throws {
        let font = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets/Fonts/IoskeleyMono-Regular.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.tabs.forEach { $0.page.stopLoading() }; browser.window?.orderOut(nil) }
        browser.developerAddress.font = try XCTUnwrap(NSFont(name: "Ioskeley-Mono", size: 12))

        let tab = browser.addTab(); tab.developer = true
        tab.requestedURL = URL(string: "https://www.google.com/search?q=gjpqy")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000)); browser.window?.orderFront(nil)
        browser.update(); browser.developerAddress.textColor = .black; browser.root.layoutSubtreeIfNeeded()
        let (resting, restingLeft) = try inkRows(browser, focused: false), (editing, editingLeft) = try inkRows(browser, focused: true)
        XCTAssertEqual(resting.lowerBound, editing.lowerBound, accuracy: 0.01, "Focusing doesn't move the address")
        XCTAssertEqual(resting.upperBound, editing.upperBound, accuracy: 0.01, "Focusing doesn't move the address")
        XCTAssertEqual(restingLeft, editingLeft, accuracy: 0.01, "Focusing doesn't move the address")
        (browser.developerAddress.currentEditor() as? NSTextView)?.insertText("g", replacementRange: NSRange(location: 0, length: 0))
        browser.layoutChrome()
        let typing = try inkRows(browser, focused: nil)
        XCTAssertEqual(typing.rows.lowerBound, editing.lowerBound, accuracy: 0.01, "Typing doesn't move it either")
        // The g's tail isn't cut off: the ink ends inside the field, not at its edge.
        XCTAssertLessThan(resting.upperBound, browser.developerAddress.frame.maxY-0.5)
        // Its capitals centred in the bar, on the page bar's baseline, as the page bar's are.
        browser.window?.makeFirstResponder(nil); browser.developerAddress.stringValue = "HHHHHH"
        let capitals = try inkRows(browser, focused: false).rows
        XCTAssertEqual((capitals.lowerBound+capitals.upperBound)/2, PlainNavBar.Metrics.midY, accuracy: 0.5)
        XCTAssertEqual(capitals.upperBound, 24.5, accuracy: 0.01, "The page bar's capitals stand on 24.5 pt")
    }
}
