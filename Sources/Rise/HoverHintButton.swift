import AppKit

/// A chrome button that, after resting the pointer on it for a moment, explains itself in a
/// native popover: what it does, then its shortcut in the secondary text color.
final class HoverHintButton: ChromeButton {
    static let delay = 0.6
    private let text: String, shortcut: String
    private var timer: Timer?
    private(set) lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hint = NSTextField(labelWithAttributedString: hintText)
        hint.sizeToFit()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: ceil(hint.frame.width)+24, height: ceil(hint.frame.height)+16))
        hint.frame.origin = NSPoint(x: 12, y: 8); content.addSubview(hint)
        let controller = NSViewController(); controller.view = content
        popover.contentViewController = controller; popover.contentSize = content.frame.size
        return popover
    }()
    var hintText: NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: "  "+shortcut, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        return result
    }
    /// Matches the browser's theme rather than the window's fixed light appearance.
    var hintAppearance: NSAppearance? { didSet { popover.appearance = hintAppearance } }

    init(image: NSImage, text: String, shortcut: String, action: @escaping () -> Void) {
        self.text = text; self.shortcut = shortcut
        super.init(symbol: "questionmark", title: text, action: action)
        self.image = image; toolTip = nil
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showHint() }
        }
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); hideHint() }
    override func mouseDown(with event: NSEvent) { hideHint(); super.mouseDown(with: event) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hideHint() } }
    private func showHint() {
        guard hover, window?.isVisible == true, !popover.isShown else { return }
        popover.show(relativeTo: bounds, of: self, preferredEdge: isFlipped ? .minY : .maxY)
    }
    func hideHint() {
        timer?.invalidate(); timer = nil
        if popover.isShown { popover.close() }
    }
}
