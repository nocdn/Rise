import XCTest
import AppKit
@testable import Rise

final class TooltipTrackingTests: XCTestCase {
    /// Rise's buttons redo their hover areas often; AppKit's tooltip area has to survive it, or
    /// AppKit can message a freed button about its tooltip, as splitting a Peek crashed.
    @MainActor func testUpdatingHoverAreasKeepsAppKitsTooltipArea() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let control = PeekControl(glyph: .split, title: "Split"), button = ChromeButton(symbol: "xmark", title: "Close", action: {})
        for view in [control, button] as [NSView] {
            view.frame = NSRect(x: 20, y: 20, width: 60, height: 60); window.contentView?.addSubview(view)
        }
        window.displayIfNeeded()
        for view in [control, button] as [NSView] {
            view.updateTrackingAreas()
            let owners = view.trackingAreas.map { String(describing: type(of: $0.owner as AnyObject)) }
            XCTAssertTrue(owners.contains("NSToolTipManager"), "\(type(of: view)): \(owners)")
            XCTAssertTrue(view.trackingAreas.contains { $0.owner === view }, "Its own hover area is back too")
        }
    }
}
