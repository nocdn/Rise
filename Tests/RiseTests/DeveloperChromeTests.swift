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
    @MainActor func testDeveloperHeaderPushesTheViewportTogetherAndReversesWithoutJumping() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = browser.addTab(); tab.requestedURL = URL(string: "http://localhost:3000")
        browser.showWindow(nil); browser.update(); browser.root.layoutSubtreeIfNeeded()
        browser.developerMotion.reduceMotion = { false }
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id]), titleY = row.titleField.frame.minY
        browser.toggleDeveloper()
        XCTAssertEqual(tab.page.view.frame.minY, 0, "Opening starts from the current viewport")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(row.titleField.layer?.animation(forKey: TabListMotion.movementKey))
            XCTAssertNotNil(row.subtitle.layer?.animation(forKey: DeveloperModeMotion.subtitleFadeKey))
        }
        XCTAssertLessThan(row.titleField.frame.minY, titleY)
        try await Task.sleep(for: .milliseconds(65))
        let openingHeight = tab.page.view.frame.minY
        XCTAssertGreaterThan(openingHeight, 0); XCTAssertLessThan(openingHeight, 40)
        XCTAssertEqual(browser.developerBar.frame.maxY, openingHeight)
        XCTAssertEqual(tab.page.view.frame.maxY, browser.pageClip.bounds.maxY)
        browser.update()
        XCTAssertEqual(tab.page.view.frame.minY, openingHeight, "Loading updates do not snap the ongoing motion")
        browser.toggleDeveloper()
        XCTAssertEqual(tab.page.view.frame.minY, openingHeight, "Reversing continues from the visible position")
        try await Task.sleep(for: .milliseconds(65))
        XCTAssertLessThan(tab.page.view.frame.minY, openingHeight)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(tab.page.view.frame, browser.pageClip.bounds)
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertTrue(row.subtitle.isHidden)
        XCTAssertEqual(row.titleField.frame.minY, titleY)
    }
    @MainActor func testTabSwitchCancelsDeveloperMotionAndReduceMotionShowsTheFinalLayoutImmediately() async throws {
        let browser = browser(); defer { clean(browser) }
        let first = browser.addTab(), second = browser.addTab()
        browser.select(first.id); browser.showWindow(nil); browser.update()
        browser.developerMotion.reduceMotion = { false }
        browser.toggleDeveloperMode(for: second)
        XCTAssertEqual(browser.selectedID, first.id)
        XCTAssertTrue(second.developer)
        XCTAssertNil(browser.developerMotion.currentHeight)
        XCTAssertTrue(browser.developerBar.isHidden)
        browser.toggleDeveloperMode(for: second)
        browser.toggleDeveloperMode(for: first); browser.select(second.id)
        XCTAssertNil(browser.developerMotion.currentHeight)
        XCTAssertTrue(browser.developerBar.isHidden)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertEqual(second.page.view.frame.minY, 0)
        browser.developerMotion.reduceMotion = { true }
        browser.toggleDeveloper()
        XCTAssertNil(browser.developerMotion.currentHeight)
        XCTAssertEqual(second.page.view.frame.minY, 40); XCTAssertEqual(browser.developerBar.frame.minY, 0)
        browser.toggleDeveloper()
        XCTAssertTrue(browser.developerBar.isHidden); XCTAssertEqual(second.page.view.frame.minY, 0)
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
