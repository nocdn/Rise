import AppKit
import XCTest
@testable import Rise

@MainActor final class PageZoomTests: XCTestCase {
    private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.PageZoomTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let folder = URL.temporaryDirectory.appendingPathComponent(suite)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: defaults)
        browser.window?.setContentSize(NSSize(width: 900, height: 650))
        let tab = browser.addTab(); tab.requestedURL = URL(string: "https://example.com/")!
        browser.showWindow(nil); browser.update(); browser.root.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            browser.closePeek(); browser.finishPeekMotion(); browser.saveWork?.cancel()
            browser.tabs.forEach { $0.cancelLoad() }; browser.suggestionFavicons.cancel(); browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        return browser
    }
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.22)) }

    func testZoomChangesAndResetSayTheirValuesInTheAddressBar() throws {
        let browser = browser(), bar = browser.navBar
        browser.setPageZoom(1.25)
        XCTAssertEqual(browser.selectedTab?.page.zoom, 1.25)
        XCTAssertEqual(bar.notice?.text, "Set page zoom to 125%")
        browser.zoomIn()
        XCTAssertEqual(bar.notice?.text, "Set page zoom to 150%")
        bar.setHovered(true)
        bar.zoomButton.actionBlock?()
        XCTAssertEqual(browser.selectedTab?.page.zoom, 1)
        XCTAssertEqual(bar.notice?.text, "Reset page zoom to 100%")
        XCTAssertEqual(bar.zoomButton.hoverHint?.text, "Reset page zoom to 100%")
        XCTAssertFalse(bar.showsZoom || bar.zoomButton.allowsInteraction)
        XCTAssertFalse(browser.siteControlsPopover.isShown)
    }

    func testZoomIsRightOfCopyAndStaysVisibleOutsideTheAddressHoverArea() {
        let browser = browser(), bar = browser.navBar
        let extensions = ["one", "two"].map { SidebarExtensionButton(extensionID: $0, action: {}) }
        bar.extensionButtons = extensions
        browser.setPageZoom(1.5); bar.layoutSubtreeIfNeeded()
        settle()
        XCTAssertEqual(bar.zoomButton.alphaValue, 1, accuracy: 0.001)
        XCTAssertFalse(bar.zoomButton.isHidden)
        XCTAssertTrue(bar.zoomButton.allowsInteraction)
        XCTAssertFalse(bar.copyButton.allowsInteraction)
        let row: [NSView] = [bar.settingsButton, bar.copyButton, bar.zoomButton]+extensions
        for (left, right) in zip(row, row.dropFirst()) {
            XCTAssertEqual(right.frame.midX-left.frame.midX, PlainNavBar.Metrics.extensionStride, accuracy: 0.01)
        }
        let point = bar.convert(NSPoint(x: bar.zoomButton.frame.midX, y: PlainNavBar.Metrics.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: bar.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        bar.mouseMoved(with: event)
        XCTAssertTrue(bar.isHovered && bar.zoomButton.allowsInteraction, "Its own slot keeps the controls hovered")
        bar.setHovered(false)
        XCTAssertTrue(bar.zoomButton.allowsInteraction)
    }

    func testTheDepartingIconFadesWhileItsSlotIsReleasedAndRapidChangesDoNotHideANewIcon() {
        let browser = browser(), bar = browser.navBar
        bar.setHovered(true); settle()
        let normalCopyX = bar.copyButton.frame.minX
        browser.setPageZoom(1.25); bar.layoutSubtreeIfNeeded(); settle()
        XCTAssertEqual(bar.copyButton.frame.minX, normalCopyX-PlainNavBar.Metrics.extensionStride, accuracy: 0.01)
        browser.actualSize(); bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.copyButton.frame.minX, normalCopyX, accuracy: 0.01, "The old zoom slot is removed immediately")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertFalse(bar.zoomButton.isHidden, "The outgoing icon is still drawn while it fades")
            XCTAssertNotNil(bar.copyButton.layer?.animation(forKey: "Rise.PageControlPosition"), "The other icons spring across the freed slot")
        }
        XCTAssertFalse(bar.zoomButton.allowsInteraction, "A fading icon cannot reset a different zoom")
        browser.setPageZoom(1.5); bar.layoutSubtreeIfNeeded(); settle()
        XCTAssertFalse(bar.zoomButton.isHidden)
        XCTAssertTrue(bar.zoomButton.allowsInteraction)
        XCTAssertEqual(bar.zoomButton.alphaValue, 1, accuracy: 0.001)
        browser.actualSize(); bar.layoutSubtreeIfNeeded(); settle(); bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.zoomButton.isHidden)
        XCTAssertEqual(bar.zoomButton.alphaValue, 0, accuracy: 0.001)
    }

    func testTheAddressBackgroundAndButtonsShareTheirLayoutSpring() throws {
        let browser = browser(), bar = browser.navBar
        bar.setHovered(true); settle()
        browser.setPageZoom(1.25); bar.layoutSubtreeIfNeeded()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let field = try XCTUnwrap(bar.layer?.sublayers?.first { $0.cornerRadius == PlainNavBar.Metrics.fieldRadius })
        let position = try XCTUnwrap(field.animation(forKey: "Rise.PageControlPosition") as? CASpringAnimation)
        let width = try XCTUnwrap(field.animation(forKey: "Rise.PageControlWidth") as? CASpringAnimation)
        let button = try XCTUnwrap(bar.copyButton.layer?.animation(forKey: "Rise.PageControlPosition") as? CASpringAnimation)
        for animation in [position, width] {
            XCTAssertEqual(animation.stiffness, button.stiffness)
            XCTAssertEqual(animation.damping, button.damping)
            XCTAssertEqual(animation.duration, button.duration)
        }
    }

    func testZoomAndResetTargetThePeekAndItsNoticeInsteadOfTheBackgroundPage() throws {
        let browser = browser(), source = try XCTUnwrap(browser.selectedTab)
        browser.showPeek(url: URL(string: "https://example.com/peek")!, animated: false)
        let peek = try XCTUnwrap(browser.peekTab)
        browser.setPageZoom(1.5)
        XCTAssertEqual(peek.page.zoom, 1.5)
        XCTAssertEqual(source.page.zoom, 1)
        XCTAssertEqual(browser.peekBar.notice?.text, "Set page zoom to 150%")
        XCTAssertNil(browser.navBar.notice)
        browser.peekBar.zoomButton.actionBlock?()
        XCTAssertEqual(peek.page.zoom, 1)
        XCTAssertEqual(browser.peekBar.notice?.text, "Reset page zoom to 100%")
    }
}
