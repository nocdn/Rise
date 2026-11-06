import AppKit

/// "AirDrop", right under a menu's "Share…": the same items, straight to AirDrop, without the share
/// menu between.
@MainActor enum AirDropMenuItem {
    /// MingCute's AirDrop (two open rings and a dot), redrawn as strokes to match Share's own symbol
    /// in a menu, `square.and.arrow.up` at the menu font's 13 points: a template, so it takes the
    /// menu's colour as Share's does, on a round symbol's 15-point canvas, with its 13-point glyph,
    /// 1.05-point line and alignment rect. The rings open at the bottom as the original's do.
    static let icon: NSImage = {
        let side: CGFloat = 15, line: CGFloat = 1.05
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            let center = NSPoint(x: side/2, y: side/2)
            // The original's rings sit at radii 9 and 5 and its dot at 2, on a 24-point grid whose
            // outer ring reaches 10; here the outer ring's edge reaches the glyph's 13 points.
            let outer = (13-line)/2, unit = outer/9
            // Its rings open between 63.4° and 116.6° below the center, where its caps end.
            for radius in [outer, 5*unit] {
                let ring = NSBezierPath()
                ring.appendArc(withCenter: center, radius: radius, startAngle: 116.57, endAngle: 63.43, clockwise: false)
                ring.lineWidth = line; ring.lineCapStyle = .round
                NSColor.black.setStroke(); ring.stroke()
            }
            let dot = 2*unit
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x-dot, y: center.y-dot, width: dot*2, height: dot*2)).fill()
            return true
        }
        image.isTemplate = true
        image.alignmentRect = NSRect(x: 0, y: 3, width: side, height: 9)
        image.accessibilityDescription = "AirDrop"
        return image
    }()

    /// The AirDrop item for `items`, or nil when AirDrop can't take them, as when it's off.
    /// `window` is the one AirDrop's panel opens on.
    static func make(for items: [Any], in window: @escaping () -> NSWindow?) -> NSMenuItem? {
        guard canSend(items) else { return nil }
        return item(title: "AirDrop") { send(items, in: window) }
    }
    static func canSend(_ items: [Any]) -> Bool { NSSharingService(named: .sendViaAirDrop)?.canPerform(withItems: items) == true }
    /// Opens AirDrop's panel on `items`, over `window`.
    static func send(_ items: [Any], in window: @escaping () -> NSWindow?) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        let source = SourceWindow(window); service.delegate = source
        // Kept until AirDrop finishes, which the service doesn't do for its delegate.
        sending = (service, source)
        service.perform(withItems: items)
    }
    /// A menu item with AirDrop's icon.
    static func item(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        let handler = MenuAction(action)
        item.target = handler; item.representedObject = handler
        item.image = icon
        // macOS 27 hides menu items' images unless they ask to be seen, as Share's own does.
        // Only its SDK (Swift 6.4, Xcode 27) has the setting; older Xcodes build without it.
        #if compiler(>=6.4)
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
        #endif
        return item
    }
    private static var sending: (NSSharingService, SourceWindow)?
    private final class SourceWindow: NSObject, NSSharingServiceDelegate {
        let window: () -> NSWindow?
        init(_ window: @escaping () -> NSWindow?) { self.window = window }
        func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { window() }
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { Task { @MainActor in AirDropMenuItem.finish(sharingService) } }
        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) { Task { @MainActor in AirDropMenuItem.finish(sharingService) } }
    }
    private static func finish(_ service: NSSharingService) { if sending?.0 === service { sending = nil } }
}
