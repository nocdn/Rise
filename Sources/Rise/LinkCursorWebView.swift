import AppKit
import WebKit

/// A stationary Peek hover keeps an AppKit cursor rect, so a later WebKit
/// modifier/cursor update cannot replace its pointing hand with an arrow.
final class LinkCursorWebView: WKWebView {
    private(set) var peekCursorPoint: NSPoint?
    func keepPeekCursor(at point: NSPoint?) {
        guard peekCursorPoint != point else { return }
        peekCursorPoint = point
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let point = peekCursorPoint {
            addCursorRect(NSRect(x: point.x-1, y: point.y-1, width: 2, height: 2).intersection(bounds), cursor: .pointingHand)
        }
    }
}
