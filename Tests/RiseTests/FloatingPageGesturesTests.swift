import AppKit
import XCTest
@testable import Rise

@MainActor final class FloatingPageGesturesTests: XCTestCase {
    func testOnlyChromesFloatingPageWindowsMove() {
        // Rise's own windows, and any window that isn't Chrome's picture in picture, keep their scrolls.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        window.level = .floating
        XCTAssertFalse(FloatingPageGestures.isFloatingPage(window))
        XCTAssertFalse(FloatingPageGestures.startsMove(at: NSPoint(x: 100, y: 230), in: window))
    }
}
