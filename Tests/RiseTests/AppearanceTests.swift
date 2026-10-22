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
        browser.saveNow()
        let restored = BrowserController(sessionURL: session)
        defer { restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.window?.appearance?.name, .darkAqua)
    }
    @MainActor func testAButtonUnderSomethingInFrontOfItDoesNotLightUp() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let button = ChromeButton(symbol: "link", title: "Copy", action: {}); button.frame = NSRect(x: 20, y: 20, width: 40, height: 40)
        let cover = Surface(color: .red); cover.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        window.contentView?.addSubview(button); window.contentView?.addSubview(cover); window.orderFront(nil)
        let middle = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        button.refreshHoverState(at: middle)
        XCTAssertFalse(button.hover, "Peek's buttons over the page bar keep its own from lighting up")
        cover.removeFromSuperview(); button.refreshHoverState(at: middle)
        XCTAssertTrue(button.hover)
    }
}
