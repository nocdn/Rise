import AppKit

/// A passive 12-point native spinner or star, sharing the tab's icon swap motion.
@MainActor final class LinkRepositoryGlyph: FlippedView {
    let spinner = NSProgressIndicator()
    let empty = NSImageView(), filled = NSImageView()
    private(set) var state: GitHubLinkStatus.State?
    var color: NSColor = .labelColor { didSet { empty.contentTintColor = color; filled.contentTintColor = color } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning; spinner.controlSize = .mini; spinner.isDisplayedWhenStopped = false
        for (view, name) in [(empty, "star"), (filled, "star.fill")] {
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            view.imageScaling = .scaleProportionallyDown
        }
        for view in [spinner, empty, filled] {
            view.wantsLayer = true; view.layer?.opacity = 0; addSubview(view)
            view.setAccessibilityElement(false)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        // Keep layer anchors centered so scaling never moves a glyph sideways.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for view in [spinner, empty, filled] {
            let side: CGFloat = view === spinner ? 12 : 14
            let lift: CGFloat = view === spinner ? 0 : 0.5
            view.frame = NSRect(x: (bounds.width-side)/2, y: (bounds.height-side)/2-lift, width: side, height: side)
            view.layer?.anchorPoint = NSPoint(x: 0.5, y: 0.5)
            view.layer?.bounds = view.bounds
            view.layer?.position = NSPoint(x: bounds.midX, y: bounds.midY-lift)
        }
        CATransaction.commit()
    }
    private func view(for state: GitHubLinkStatus.State) -> NSView {
        switch state { case .checking: spinner; case .starred: filled; case .unstarred: empty }
    }
    func show(_ state: GitHubLinkStatus.State?, animated: Bool) {
        guard state != self.state else { return }
        let previous = self.state; self.state = state
        guard let state else {
            [spinner, empty, filled].forEach { $0.layer?.removeAllAnimations(); $0.layer?.opacity = 0 }
            spinner.stopAnimation(nil); return
        }
        let incoming = view(for: state), outgoing = previous.map(view(for:)) ?? (state == .checking ? empty : spinner)
        if state == .checking { spinner.startAnimation(nil) }
        if let a = incoming.layer, let b = outgoing.layer { SymbolSwapMotion.show(a, replacing: b, animated: animated && previous != nil) }
        // The spinner can finish its shrinking animation before it stops drawing.
        if state != .checking {
            DispatchQueue.main.asyncAfter(deadline: .now()+0.12) { [weak self] in
                if self?.state != .checking { self?.spinner.stopAnimation(nil) }
            }
        }
    }
}
