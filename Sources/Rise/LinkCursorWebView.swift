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
    /// The link under the pointer that a Peek can open, and opening it, for the link's menu.
    var peekableLink: (() -> URL?)?
    var openInPeek: ((URL) -> Void)?
    /// Pressing a link ends its hover before WebKit builds the menu, so the link is kept from the press.
    private var menuLink: URL?
    override func rightMouseDown(with event: NSEvent) { menuLink = peekableLink?(); super.rightMouseDown(with: event) }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { menuLink = peekableLink?() }
        super.mouseDown(with: event)
    }
    /// "Open Link in Peek" follows WebKit's "Open Link in New Window".
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        defer { menuLink = nil }
        guard let url = menuLink ?? peekableLink?(),
              let open = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) else { return }
        let after = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" } ?? open
        let item = NSMenuItem(title: "Open Link in Peek", action: #selector(openLinkInPeek(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = url
        menu.insertItem(item, at: after+1)
    }
    @objc private func openLinkInPeek(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openInPeek?(url) }
    }
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
