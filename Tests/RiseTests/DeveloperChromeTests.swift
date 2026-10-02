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
        browser.siteInfoPopover.close(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
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
        while tab.webView.title != "Edited address" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.webView.title, "Edited address")
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
        XCTAssertEqual(content.engine.stringValue, "Rendering engine: Apple WebKit")
        XCTAssertGreaterThan(browser.siteInfoPopover.contentSize.height, 100)
        XCTAssertEqual(browser.siteInfoPopover.contentSize.width, 340, accuracy: 1)
        browser.devButtons[4].performClick(nil)
        XCTAssertFalse(browser.siteInfoPopover.isShown)
    }
}
