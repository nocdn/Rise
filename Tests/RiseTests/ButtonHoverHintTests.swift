import XCTest
import AppKit
@testable import Rise

final class ButtonHoverHintTests: XCTestCase {
    @MainActor func testNativeHintWaitsForHoverUpdatesInPlaceAndDismissesOnActionsAndRemoval() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var presses = 0
        let button = ChromeButton(symbol: "arrow.clockwise", title: "Reload", action: { presses += 1 })
        button.frame = NSRect(x: 150, y: 60, width: 28, height: 28)
        button.setHoverHint("Reload", shortcut: "⌘R")
        let hint = try XCTUnwrap(button.hoverHint)
        defer { hint.hide(); window.orderOut(nil) }
        window.contentView?.addSubview(button); window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let middle = button.convert(NSPoint(x: 14, y: 14), to: nil)
        button.refreshHoverState(at: middle)
        XCTAssertTrue(button.hover)
        XCTAssertNil(hint.popover, "Entering does not open the hint immediately")
        try await Task.sleep(for: .milliseconds(750))
        let popover = try XCTUnwrap(hint.popover)
        XCTAssertTrue(popover.isShown)
        let field = try XCTUnwrap(popover.contentViewController?.view.subviews.first as? NSTextField)
        XCTAssertEqual(field.stringValue, "Reload  ⌘R")
        let previousWidth = popover.contentSize.width
        hint.setShortcut("⌘⌃⌥R")
        XCTAssertTrue(popover.isShown, "A shortcut edit updates the existing popover")
        XCTAssertEqual(field.stringValue, "Reload  ⌘⌃⌥R")
        XCTAssertGreaterThan(popover.contentSize.width, previousWidth)
        XCTAssertEqual(popover.contentSize.width, ceil(field.frame.width)+24)
        XCTAssertEqual(popover.contentSize.height, ceil(field.frame.height)+16)
        popover.animates = false
        button.runAction()
        XCTAssertEqual(presses, 1)
        XCTAssertFalse(popover.isShown)
        button.refreshHoverState(at: NSPoint(x: 10, y: 10))
        button.refreshHoverState(at: middle)
        button.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertFalse(popover.isShown, "Removing the anchor cancels a pending hint")
    }
}
