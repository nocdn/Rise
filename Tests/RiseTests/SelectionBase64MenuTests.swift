import AppKit
import XCTest
import RiseCore
@testable import Rise

@MainActor final class SelectionBase64MenuTests: XCTestCase {
    func testDecodePreviewIsDisabledAndActionsCopyAndAnnounceTheirValues() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.linkPasteboard = NSPasteboard.withUniqueName()
        defer { browser.linkPasteboard.releaseGlobally(); browser.navBar.hideNotice(); browser.saveWork?.cancel(); browser.suggestionFavicons.cancel(); browser.window?.close(); try? FileManager.default.removeItem(at: folder) }
        let menu = try XCTUnwrap(browser.base64DecodeItem(for: "SGVsbG8="))
        XCTAssertEqual(menu.title, "Decode Base64")
        let children = try XCTUnwrap(menu.submenu).items
        XCTAssertEqual(children.map(\.title), ["Copy Decoded Value", "Hello"])
        XCTAssertFalse(children[1].isEnabled); XCTAssertNil(children[1].action)
        (children[0].target as? MenuAction)?.invoke()
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), "Hello")
        XCTAssertEqual(browser.navBar.notice?.text, SelectionBase64.decodedMessage)
        let encode = try XCTUnwrap(browser.base64EncodeItem(for: "  café\n"))
        XCTAssertEqual(encode.title, "Encode")
        let action = try XCTUnwrap(encode.submenu?.items.first)
        XCTAssertEqual(action.title, "Base64")
        (action.target as? MenuAction)?.invoke()
        XCTAssertEqual(browser.linkPasteboard.string(forType: .string), Data("  café\n".utf8).base64EncodedString())
        XCTAssertEqual(browser.navBar.notice?.text, SelectionBase64.encodedMessage)
        XCTAssertNil(browser.base64DecodeItem(for: "not base64!"))
        XCTAssertNil(browser.base64EncodeItem(for: ""))
        XCTAssertTrue(BrowserController.base64Icon.isValid)
        XCTAssertTrue(BrowserController.base64Icon.isTemplate)
        XCTAssertTrue(BrowserController.base64Icon.representations.contains { "\(type(of: $0))".contains("SVG") }, "Use the supplied SVG rather than the fallback symbol")
    }
}
