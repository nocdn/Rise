import AppKit

/// A row in the pull request card with one piece of text that opens something. Under the
/// pointer the text lightens at once and the pointer becomes a hand; a click opens it.
class CardLinkRow: FlippedView {
    var onOpen: (() -> Void)?
    /// The pointer went onto the link's text, or off it.
    var onLinkHover: ((Bool) -> Void)?
    var dark = false { didSet { needsDisplay = true } }
    var muted = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    /// Where the link's text was last drawn.
    private(set) var linkRect = NSRect.zero
    private(set) var linkHovered = false { didSet { if linkHovered != oldValue { needsDisplay = true; onLinkHover?(linkHovered) } } }
    private var pressed = false
    override var mouseDownCanMoveWindow: Bool { false }
    var linkColor: NSColor { linkHovered ? muted.blended(withFraction: 0.45, of: .white) ?? muted : muted }

    func placeLink(_ rect: NSRect) {
        guard linkRect != rect else { return }
        linkRect = rect; window?.invalidateCursorRects(for: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { if !linkRect.isEmpty { addCursorRect(linkRect, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { hover(event) }
    override func mouseMoved(with event: NSEvent) { hover(event) }
    override func mouseExited(with event: NSEvent) { linkHovered = false }
    override func viewDidHide() { super.viewDidHide(); linkHovered = false }
    private func hover(_ event: NSEvent) {
        linkHovered = linkRect.contains(convert(event.locationInWindow, from: nil))
        if linkHovered { NSCursor.pointingHand.set() }
    }
    override func mouseDown(with event: NSEvent) {
        pressed = linkRect.contains(convert(event.locationInWindow, from: nil))
        if !pressed { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, linkRect.contains(convert(event.locationInWindow, from: nil)) else { return super.mouseUp(with: event) }
        linkHovered = false; onOpen?()
    }
}

/// A row in the card that's GitLab's status icon, then text that opens something.
class StatusLinkRow: CardLinkRow {
    static let height: CGFloat = 18, iconSize: CGFloat = 14, iconGap: CGFloat = 8
    static let font = NSFont.systemFont(ofSize: 13)
    var text: String? { didSet { needsDisplay = true } }
    /// The width the row needs to fit on one line.
    static func width(_ text: String?) -> CGFloat {
        guard let text else { return 0 }
        return iconSize+iconGap+ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
    func drawIcon(in rect: NSRect) {}
    override func draw(_ dirtyRect: NSRect) {
        guard let text else { placeLink(.zero); return }
        let midY = Self.height/2, size = Self.iconSize
        drawIcon(in: NSRect(x: 0, y: midY-size/2, width: size, height: size))
        let string = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: linkColor])
        string.draw(at: NSPoint(x: size+Self.iconGap, y: midY-string.size().height/2))
        placeLink(NSRect(x: size+Self.iconGap, y: 0, width: ceil(string.size().width), height: Self.height))
    }
}

/// A GitLab merge request's latest pipeline: GitLab's status icon and the pipeline's number,
/// which opens its jobs.
final class PipelineRow: StatusLinkRow {
    var pipeline: Pipeline? {
        didSet {
            text = pipeline.map(Self.number)
            setAccessibilityLabel(pipeline.map { "Pipeline #\($0.id), \($0.label)" })
        }
    }
    static func number(_ pipeline: Pipeline) -> String { "#\(pipeline.id)" }
    override func drawIcon(in rect: NSRect) { if let pipeline { Self.drawIcon(pipeline.status, dark: dark, in: rect) } }
    /// GitLab's bordered status icon: a ring and glyph in the status color, filled with its tint.
    static func drawIcon(_ status: Pipeline.Status, dark: Bool, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let colors = status.colors(dark: dark)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: rect.width/14, y: rect.height/14)
        context.setFillColor(colors.icon.cgColor); context.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
        context.setFillColor(colors.fill.cgColor); context.fillEllipse(in: CGRect(x: 1, y: 1, width: 12, height: 12))
        context.addPath(TablerIcon.path(status.glyph))
        context.setFillColor(colors.icon.cgColor); context.fillPath(using: .evenOdd)
    }
}

/// Whether a merge request can be merged: a tick and "Ready", or a minus and what's in the
/// way. Either opens the merge request's merge checks.
final class MergeCheckRow: StatusLinkRow {
    var mergeCheck: MergeCheck? {
        didSet {
            text = mergeCheck.map(Self.text)
            setAccessibilityLabel(mergeCheck.map { $0.ready ? "Ready to merge" : "Can't merge yet: \(Self.text($0))" })
        }
    }
    /// The card's color, which the icon's glyph is cut out in.
    var cutout = NSColor.white { didSet { needsDisplay = true } }
    static func text(_ check: MergeCheck) -> String {
        check.ready ? "Ready" : check.blockers.map { $0 == "Pipeline" ? "Pipeline success" : $0 }.joined(separator: " · ")
    }
    override func drawIcon(in rect: NSRect) {
        if let mergeCheck { Self.drawMergeIcon(ready: mergeCheck.ready, dark: dark, cutout: cutout, in: rect) }
    }
    /// GitLab's merge checks icon: a solid tick or minus disc, cut out of the card, in a tinted halo.
    static func drawMergeIcon(ready: Bool, dark: Bool, cutout: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let pair: (UInt32, UInt32) = ready ? (dark ? (0x61C28C, 0x2F6141) : (0x108548, 0xC3E6CD))
                                           : (dark ? (0xFB937E, 0x953214) : (0xDD2B0E, 0xFDD4CD))
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY); context.scaleBy(x: rect.width/14, y: rect.height/14)
        context.setFillColor(NSColor(hex: pair.1).cgColor); context.fillEllipse(in: CGRect(x: 0, y: 0, width: 14, height: 14))
        context.setFillColor(NSColor(hex: pair.0).cgColor); context.fillEllipse(in: CGRect(x: 2, y: 2, width: 10, height: 10))
        context.addPath(TablerIcon.path(ready ? "M4.9 7.1l1.45 1.45l2.75-2.85" : "M4.9 7h4.2"))
        context.setStrokeColor(cutout.cgColor); context.setLineWidth(1.4); context.setLineCap(.round); context.setLineJoin(.round)
        context.strokePath()
    }
}

extension Pipeline.Status {
    /// The glyphs inside GitLab's 14-unit status icons (gitlab-svgs, MIT).
    var glyph: String {
        switch self {
        case .running: return "M7 3c2.2 0 4 1.8 4 4s-1.8 4-4 4c-1.3 0-2.5-.7-3.3-1.7L7 7V3"
        case .success: return "M6.278 7.697L5.045 6.464a.296.296 0 0 0-.42-.002l-.613.614a.298.298 0 0 0 .002.42l1.91 1.909a.5.5 0 0 0 .703.005l.265-.265L9.997 6.04a.291.291 0 0 0-.009-.408l-.614-.614a.29.29 0 0 0-.408-.009L6.278 7.697z"
        case .warning: return "M6 3.5c0-.3.2-.5.5-.5h1c.3 0 .5.2.5.5v4c0 .3-.2.5-.5.5h-1c-.3 0-.5-.2-.5-.5v-4m0 6c0-.3.2-.5.5-.5h1c.3 0 .5.2.5.5v1c0 .3-.2.5-.5.5h-1c-.3 0-.5-.2-.5-.5v-1"
        case .failed: return "M7 5.969L5.599 4.568a.29.29 0 0 0-.413.004l-.614.614a.294.294 0 0 0-.004.413L5.968 7l-1.4 1.401a.29.29 0 0 0 .004.413l.614.614c.113.114.3.117.413.004L7 8.032l1.401 1.4a.29.29 0 0 0 .413-.004l.614-.614a.294.294 0 0 0 .004-.413L8.032 7l1.4-1.401a.29.29 0 0 0-.004-.413l-.614-.614a.294.294 0 0 0-.413-.004L7 5.968z"
        case .pending: return "M4.7 5.3c0-.2.1-.3.3-.3h.9c.2 0 .3.1.3.3v3.4c0 .2-.1.3-.3.3H5c-.2 0-.3-.1-.3-.3V5.3m3 0c0-.2.1-.3.3-.3h.9c.2 0 .3.1.3.3v3.4c0 .2-.1.3-.3.3H8c-.2 0-.3-.1-.3-.3V5.3"
        case .canceled: return "M5.2 3.8l4.9 4.9c.2.2.2.5 0 .7l-.7.7c-.2.2-.5.2-.7 0L3.8 5.2c-.2-.2-.2-.5 0-.7l.7-.7c.2-.2.5-.2.7 0"
        case .skipped: return "M6.415 7.04L4.579 5.203a.295.295 0 0 1 .004-.416l.349-.349a.29.29 0 0 1 .416-.004l2.214 2.214a.289.289 0 0 1 .019.021l.132.133c.11.11.108.291 0 .398L5.341 9.573a.282.282 0 0 1-.398 0l-.331-.331a.285.285 0 0 1 0-.399L6.415 7.04zm2.54 0L7.119 5.203a.295.295 0 0 1 .004-.416l.349-.349a.29.29 0 0 1 .416-.004l2.214 2.214a.289.289 0 0 1 .019.021l.132.133c.11.11.108.291 0 .398L7.881 9.573a.282.282 0 0 1-.398 0l-.331-.331a.285.285 0 0 1 0-.399L8.955 7.04z"
        case .manual: return "M10.5 7.63V6.37l-.787-.13c-.044-.175-.132-.349-.263-.61l.481-.652-.918-.913-.657.478a2.346 2.346 0 0 0-.612-.26L7.656 3.5H6.388l-.132.783c-.219.043-.394.13-.612.26l-.657-.478-.918.913.437.652c-.131.218-.175.392-.262.61l-.744.086v1.261l.787.13c.044.218.132.392.263.61l-.438.651.92.913.655-.434c.175.086.394.173.613.26l.131.783h1.313l.131-.783c.219-.043.394-.13.613-.26l.656.478.918-.913-.48-.652c.13-.218.218-.435.262-.61l.656-.13zM7 8.283a1.285 1.285 0 0 1-1.313-1.305c0-.739.57-1.304 1.313-1.304.744 0 1.313.565 1.313 1.304 0 .74-.57 1.305-1.313 1.305z"
        case .created: return "M3.75 7a3.25 3.25 0 1 0 6.5 0a3.25 3.25 0 1 0-6.5 0"
        }
    }
    /// GitLab's status colors: the icon's, and the tint inside its ring.
    func colors(dark: Bool) -> (icon: NSColor, fill: NSColor) {
        let pair: (UInt32, UInt32)
        switch self {
        case .running: pair = dark ? (0x78B6ED, 0x25427A) : (0x1F75CB, 0xCBE2F9)
        case .success: pair = dark ? (0x52B87A, 0x0D4524) : (0x108548, 0xC3E6CD)
        case .warning, .pending: pair = dark ? (0xE9BE74, 0x5C2900) : (0xAB6100, 0xF5D9A8)
        case .failed: pair = dark ? (0xF57F6C, 0x660E00) : (0xDD2B0E, 0xFDD4CD)
        case .canceled, .skipped, .manual, .created: pair = dark ? (0xA4A3A8, 0x434248) : (0x626168, 0xDCDCDE)
        }
        return (NSColor(hex: pair.0), NSColor(hex: pair.1))
    }
}
