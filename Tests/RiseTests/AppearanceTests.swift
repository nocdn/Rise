import XCTest
import AppKit
@testable import Rise

// Pages taking the theme's colour scheme are checked on Chromium: Tests/Live/ChromiumFeatureChecks.swift.
final class AppearanceTests: XCTestCase {
    @MainActor func testPopupOpensAndClosesImmediatelyAndKeepsItsShadow() {
        _ = NSApplication.shared
        let popup = AddressPalette()
        popup.place(at: NSPoint(x: 8, y: 50), width: 350)
        popup.show(text: "example.com", theme: .dark)
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(popup.alphaValue, 1)
        XCTAssertEqual(popup.frame.width, 350)
        XCTAssertNotNil(popup.shadow)
        XCTAssertTrue(popup.layer?.animationKeys()?.isEmpty ?? true)
        popup.hide()
        XCTAssertTrue(popup.isHidden)
        popup.show(text: "reopened", theme: .neutral)
        XCTAssertTrue(popup.isPresented)
        XCTAssertEqual(popup.input.stringValue, "reopened")
        XCTAssertEqual(popup.alphaValue, 1)
        popup.hide()
        XCTAssertTrue(popup.isHidden)
    }
    @MainActor func testDarkAppearanceRestores() {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false)
        defer {
            browser.saveWork?.cancel(); browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        browser.addTab()
        browser.theme = .dark; browser.update()
        XCTAssertEqual(browser.window?.appearance?.name, .darkAqua)
        XCTAssertEqual(browser.sidebar.newTab.theme, .dark)
        XCTAssertEqual(browser.sidebar.address.frame.minY, 50)
        browser.saveNow()
        let restored = BrowserController(sessionURL: session)
        defer { restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.window?.appearance?.name, .darkAqua)
    }
}
