import XCTest
import UIKit
import WebKit
@testable import RiseiOS

final class PrintingTests: XCTestCase {
    @MainActor func testWindowPrintOpensThePrintSheetWithoutHoldingThePage() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let printer = UIPrintInteractionController.shared
        printer.printFormatter = nil
        let browser = BrowserViewController(startURL: fixture.url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { printer.dismiss(animated: false); window.isHidden = true }
        let page = browser.webView
        for _ in 0..<500 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }

        _ = try await page.evaluateJavaScript("window.printed = 0; setTimeout(() => { window.print(); window.printed = 1 }, 0); true")
        for _ in 0..<250 where printer.printFormatter == nil { try await Task.sleep(for: .milliseconds(20)) }
        let formatter = try XCTUnwrap(printer.printFormatter as? UIViewPrintFormatter, "window.print() opens the print sheet")
        XCTAssertTrue(formatter.view === page, "It prints the page that asked")

        // A page held in window.print() can't draw the sheet's preview, which then spins for good.
        var printed: Int?
        for _ in 0..<250 {
            printed = try? await page.evaluateJavaScript("window.printed") as? Int
            if printed == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(printed, 1, "The page carries on while the sheet is open")
        XCTAssertTrue(printer.printFormatter === formatter, "The sheet is still open")
    }

    /// Print buttons often open a window and write the page into it, as printatestpage.com does.
    /// That window has no navigation of its own, and must not wait under the loading spinner.
    @MainActor func testAWindowItsOpenerWritesIntoShowsItsPage() async throws {
        let fixture = try AdBlockHTTPFixture(); try await fixture.start()
        defer { fixture.stop() }
        let browser = BrowserViewController(startURL: fixture.url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let page = browser.webView
        for _ in 0..<500 where page.isLoading || page.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let popups = browser.adBlocker.popups, wasEnabled = popups.isEnabled(for: fixture.url)
        popups.setEnabled(false, for: fixture.url)
        defer { popups.setEnabled(wasEnabled, for: fixture.url) }

        _ = try await page.evaluateJavaScript("""
            var w = window.open('Printatestpage.com', 'Printatestpage.com');
            w.document.open(); w.document.write('<html><body><h1>Test page</h1></body></html>'); w.document.close(); true
            """)
        for _ in 0..<250 where browser.tabs.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(browser.tabs.count, 2, "The window opens as a tab")
        let popup = browser.tabs[1]
        for _ in 0..<250 where !popup.hasCommittedDocument { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(popup.hasCommittedDocument, "The written page counts as loaded")
        XCTAssertTrue(browser.navigationStatus.isHidden, "No loading spinner over it")
    }
}
