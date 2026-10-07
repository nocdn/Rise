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
        guard !isCovered else { return }
        super.resetCursorRects()
        if let point = peekCursorPoint {
            addCursorRect(NSRect(x: point.x-1, y: point.y-1, width: 2, height: 2).intersection(bounds), cursor: .pointingHand)
        }
    }
    /// A page under a Peek. Tracking areas fire regardless of what covers a view, so without
    /// this the page behind would keep hovering its links and setting the cursor, fighting
    /// the Peek's page above it. WebKit's tracking areas belong to an internal observer, not
    /// this view, so they're set aside while covered and put back afterwards.
    var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            keepPeekCursor(at: nil)
            if isCovered { suspendTrackingAreas() }
            else { let areas = suspendedAreas; suspendedAreas = []; areas.forEach(addTrackingArea) }
            window?.invalidateCursorRects(for: self)
        }
    }
    private var suspendedAreas: [NSTrackingArea] = []
    private func suspendTrackingAreas() {
        let areas = trackingAreas
        areas.forEach(removeTrackingArea); suspendedAreas += areas
    }
    // WebKit swaps its tracking area itself, for instance when the view resizes; while
    // covered, new areas wait with the others.
    override func addTrackingArea(_ area: NSTrackingArea) {
        if isCovered { suspendedAreas.append(area) } else { super.addTrackingArea(area) }
    }
    override func removeTrackingArea(_ area: NSTrackingArea) {
        suspendedAreas.removeAll { $0 === area }; super.removeTrackingArea(area)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if isCovered { suspendTrackingAreas() }
    }
}
