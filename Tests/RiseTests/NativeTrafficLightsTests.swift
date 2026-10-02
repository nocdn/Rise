import XCTest
import AppKit
import CoreImage
@testable import Rise

final class NativeTrafficLightsTests: XCTestCase {
    @MainActor func browser() -> BrowserController {
        _ = NSApplication.shared
        return BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
    }
    @MainActor func clean(_ browser: BrowserController) {
        browser.trafficLights.detach(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor func testNativeButtonsKeepTheirActionsAndEnablementWhileGrayAndRestoreTogetherOnHover() throws {
        let browser = browser(); defer { clean(browser) }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { browser.window!.standardWindowButton($0)! }
        let parents = buttons.map(\.superview), actions = buttons.map(\.action), targets = buttons.map(\.target)
        let lights = browser.trafficLights!
        XCTAssertFalse(lights.isHovering)
        let area = try XCTUnwrap(lights.trackingArea)
        for button in buttons {
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.contentFilters.last?.name, "CIColorControls")
            XCTAssertEqual(button.contentFilters.last?.value(forKey: kCIInputSaturationKey) as? Double, 0)
            XCTAssertTrue(area.rect.contains(button.convert(button.bounds, to: button.superview)))
        }
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0)!
        let enter = NSSelectorFromString("mouseEntered:"), exit = NSSelectorFromString("mouseExited:")
        XCTAssertTrue(lights.responds(to: enter)); XCTAssertTrue(lights.responds(to: exit))
        lights.perform(enter, with: event)
        XCTAssertTrue(lights.isHovering)
        XCTAssertTrue(buttons.allSatisfy { $0.contentFilters.isEmpty && $0.isEnabled })
        lights.perform(exit, with: event)
        XCTAssertFalse(lights.isHovering)
        for (i, button) in buttons.enumerated() {
            XCTAssertEqual(button.contentFilters.count, 1)
            XCTAssertTrue(button.superview === parents[i])
            XCTAssertEqual(button.action, actions[i])
            XCTAssertTrue(button.target === targets[i])
        }
    }
    @MainActor func testThemeChangesAndHiddenSidebarKeepTrackingAndFiltersConsistent() {
        let browser = browser(); defer { clean(browser) }
        let lights = browser.trafficLights!, close = browser.window!.standardWindowButton(.closeButton)!
        browser.theme = .dark; browser.update()
        XCTAssertEqual(close.contentFilters.last?.value(forKey: kCIInputBrightnessKey) as? Double, -0.22)
        browser.toggleSidebar()
        XCTAssertNil(lights.trackingArea)
        lights.setHovered(true)
        XCTAssertFalse(lights.isHovering)
        XCTAssertTrue(close.isHidden); XCTAssertTrue(close.isEnabled)
        browser.toggleSidebar()
        XCTAssertNotNil(lights.trackingArea); XCTAssertFalse(close.isHidden)
        browser.theme = .neutral; browser.update()
        XCTAssertEqual(close.contentFilters.last?.value(forKey: kCIInputBrightnessKey) as? Double, 0.20)
        lights.detach()
        XCTAssertTrue(close.contentFilters.isEmpty); XCTAssertNil(lights.trackingArea)
    }
    @MainActor func testNativeCloseButtonStillWorksWithoutHover() {
        let browser = browser(); defer { clean(browser) }
        let window = browser.window!
        window.setFrameAutosaveName(""); window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        browser.layoutChrome()
        let close = window.standardWindowButton(.closeButton)!
        XCTAssertFalse(browser.trafficLights.isHovering)
        XCTAssertFalse(close.contentFilters.isEmpty)
        let closed = expectation(forNotification: NSWindow.willCloseNotification, object: window)
        close.performClick(nil)
        wait(for: [closed], timeout: 2)
        XCTAssertFalse(window.isVisible)
    }
}
