import AppKit
import XCTest
@testable import Rise

@MainActor final class FaviconViewTests: XCTestCase {
    func testCachedFaviconsUseTheSameOrdinaryCornersInSidebarAndSuggestions() throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        defer {
            browser.hidePalette(); browser.saveWork?.cancel(); browser.suggestionFavicons.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            try? FileManager.default.removeItem(at: folder)
        }
        let original = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.orange.setFill(); rect.fill(); return true
        }
        let cached = try XCTUnwrap(FaviconSnapshot.encode(original))
        let square = try XCTUnwrap(FaviconSnapshot.decode(cached))
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: cached))
        XCTAssertEqual(pixels.colorAt(x: 0, y: 0)?.alphaComponent, 1, "Cache entries retain the site's square artwork")
        let url = URL(string: "https://favicon.example/")!
        let tab = browser.addTab(); tab.requestedURL = url; tab.favicon = square
        browser.update(); browser.showWindow(nil); browser.root.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(browser.sidebar.rows[tab.id]?.icon)
        browser.newTab()
        browser.palette.replaceSuggestions([AddressSuggestion(title: "Example", subtitle: url.absoluteString, symbol: "globe", url: url, command: nil, favicon: square)])
        browser.palette.layoutSubtreeIfNeeded()
        let suggestion = try XCTUnwrap(browser.palette.buttons.first?.subviews.first as? FaviconView)
        XCTAssertEqual(sidebar.layer?.cornerCurve, .circular, "Favicon corners have no continuous squircle smoothing")
        XCTAssertEqual(sidebar.layer?.cornerCurve, suggestion.layer?.cornerCurve)
        XCTAssertEqual(try XCTUnwrap(sidebar.layer?.cornerRadius)/sidebar.bounds.width,
                       try XCTUnwrap(suggestion.layer?.cornerRadius)/suggestion.bounds.width, accuracy: 0.0001)
        XCTAssertEqual(FaviconSnapshot.encode(square), cached, "View clipping never gets baked back into cached artwork")
    }
}
