import AppKit
@testable import Rise

extension TabRow {
    /// The pointer coming onto the row's middle, as a tracking area reports it: a row only takes it
    /// where it's in front.
    @MainActor func pointerEnters() {
        let point = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
    }
}
