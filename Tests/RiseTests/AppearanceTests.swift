import XCTest
import AppKit
import WebKit
@testable import Rise

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
    @MainActor func testAFreshPageInDarkShowsTheDarkSurfaceUntilItPaints() async throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false)
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        try "<title>Painted</title>Page".write(to: page, atomically: true, encoding: .utf8)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: session.deletingLastPathComponent()); try? FileManager.default.removeItem(at: page)
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        browser.theme = .dark; browser.update(); browser.showWindow(nil)
        let tab = browser.addTab()
        XCTAssertFalse(PagePaintWatcher.drawsBackground(tab.webView), "No white before the page paints")
        tab.load(page)
        let deadline = Date().addingTimeInterval(10)
        while !browser.pagePaint.hasPainted(tab.webView) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(tab.webView.title, "Painted")
        XCTAssertTrue(PagePaintWatcher.drawsBackground(tab.webView), "Once painted, pages without a background get WebKit's white again")
        browser.theme = .neutral; browser.update()
        XCTAssertTrue(PagePaintWatcher.drawsBackground(browser.addTab().webView), "Light themes draw normally from the start")
    }
    @MainActor func testDarkAppearanceRestoresAndWebKitReceivesColorScheme() async throws {
        _ = NSApplication.shared
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json")
        let browser = BrowserController(sessionURL: session, restore: false)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.webView.stopLoading() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: session.deletingLastPathComponent())
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        let tab = browser.addTab()
        browser.theme = .dark; browser.update()
        tab.webView.loadHTMLString("<!doctype html><meta name='color-scheme' content='light dark'><title>Appearance</title>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while tab.webView.title != "Appearance" && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(browser.window?.appearance?.name, .darkAqua)
        XCTAssertEqual(browser.sidebar.newTab.theme, .dark)
        XCTAssertEqual(browser.sidebar.address.frame.minY, 50)
        let dark = try await tab.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")
        XCTAssertEqual(dark as? Bool, true)
        browser.saveNow()
        let restored = BrowserController(sessionURL: session)
        defer { restored.saveWork?.cancel(); restored.window?.orderOut(nil) }
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.window?.appearance?.name, .darkAqua)
        browser.theme = .neutral; browser.update()
        try await Task.sleep(for: .milliseconds(100))
        let light = try await tab.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")
        XCTAssertEqual(light as? Bool, false)
    }
}
