import XCTest
import AppKit
import RiseCore
@testable import Rise

/// Replace on Page on the Mac: the coins in the page bar, shown as a permission's icon is, and the
/// permission panel saying what was replaced, with Revert in place of its check and cross.
@MainActor final class CurrencyReplacementTests: XCTestCase {
    private func browser() -> (BrowserController, UserDefaults, String) {
        _ = NSApplication.shared
        let suite = "Rise.CurrencyReplacementTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        browser.window?.setContentSize(NSSize(width: 900, height: 650))
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com")
        browser.showWindow(nil); browser.update(); browser.root.layoutSubtreeIfNeeded()
        return (browser, defaults, suite)
    }
    private func clean(_ browser: BrowserController, _ defaults: UserDefaults, _ suite: String) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
        browser.window?.orderOut(nil); defaults.removePersistentDomain(forName: suite)
    }

    func testTheCoinsSitRightOfCopyAndShowWithoutHover() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        let bar = browser.navBar, tab = try XCTUnwrap(browser.selectedTab)
        XCTAssertTrue(bar.currencyButton.isHidden)
        browser.currencyReplacement.replaced(12, with: "GBP", in: tab)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.replacedCurrency, "GBP")
        XCTAssertFalse(bar.currencyButton.isHidden)
        XCTAssertEqual(bar.currencyButton.frame.midX-bar.copyButton.frame.midX, PlainNavBar.Metrics.extensionStride, accuracy: 0.01)
        XCTAssertFalse(bar.isHovered)
        XCTAssertEqual(bar.currencyButton.alphaValue, 1, "Shown unhovered, as a permission's icon is")
        XCTAssertTrue(bar.currencyButton.allowsInteraction)
        XCTAssertEqual(bar.copyButton.alphaValue, 0)

        // The coins count as the bar's own buttons: on them, the address shows in full with copy and site controls.
        let point = bar.convert(NSPoint(x: bar.currencyButton.frame.midX, y: PlainNavBar.Metrics.midY), to: nil)
        bar.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: bar.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        XCTAssertTrue(bar.isHovered && bar.copyButton.allowsInteraction && bar.settingsButton.allowsInteraction)

        // The panel says what was replaced, with only Revert.
        let panel = browser.currencyReplacement.panel
        bar.currencyButton.actionBlock?()
        XCTAssertTrue(panel.isPresented)
        XCTAssertTrue(panel.superview === browser.root && !panel.isHidden, "Over the page, to come down")
        XCTAssertEqual(panel.frame.minX, browser.pageShadow.frame.minX, accuracy: 0.5)
        // The coins put it away, and bring it back.
        bar.currencyButton.actionBlock?()
        XCTAssertFalse(panel.isPresented)
        bar.currencyButton.actionBlock?()
        XCTAssertTrue(panel.isPresented)
        XCTAssertEqual(panel.notice?.message, "Replaced 12 values with GBP on the page")
        XCTAssertTrue(panel.allowButton.isHidden && panel.denyButton.isHidden)
        XCTAssertFalse(panel.revertButton.isHidden)
        XCTAssertEqual(panel.revertButton.hoverHint?.text, "Revert")
        XCTAssertEqual(panel.revertButton.hoverTint, CurrencyReplacement.accent(browser.theme), "Money's pink under the pointer")

        // Reverting takes it all away.
        panel.revertButton.actionBlock?()
        XCTAssertNil(tab.replacedCurrency)
        XCTAssertFalse(panel.isPresented)
    }

    func testCommandZRevertsForALittleWhile() throws {
        let (browser, defaults, suite) = browser(); defer { clean(browser, defaults, suite) }
        let tab = try XCTUnwrap(browser.selectedTab), window = try XCTUnwrap(browser.window)
        browser.currencyReplacement.replaced(3, with: "EUR", in: tab)
        let undo = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                                                 isARepeat: false, keyCode: 6))
        XCTAssertTrue(browser.currencyReplacement.handleUndoKey(undo))
        XCTAssertNil(tab.replacedCurrency)
        XCTAssertFalse(browser.currencyReplacement.handleUndoKey(undo), "Once only")
    }

    func testThePanelSaysHowManyValues() {
        XCTAssertEqual(CurrencyReplacement.message(1, "GBP"), "Replaced 1 value with GBP on the page")
        XCTAssertEqual(CurrencyReplacement.message(4, "GBP"), "Replaced 4 values with GBP on the page")
    }
}
