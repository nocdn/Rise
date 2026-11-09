import AppKit

/// Holds the page of a link hovered with the Peek modifier, rendering invisibly at
/// the Peek card's size so a click can show it from the first animation frame.
final class PeekStandbyView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor extension BrowserController {
    /// Holding Shift (or Option) over a link is a strong signal that a Peek follows.
    /// A short dwell keeps sweeps across many links from loading each one.
    func updatePeekStandby(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        peekStandbyWork?.cancel(); peekStandbyWork = nil
        guard shouldPeek(modifiers: modifiers), let web = hoveredWebView, web !== peekTab?.page.view, let url = linkStatus.url,
              let page = page(showing: web), LinkPreloader.isEligible(url, from: page.url), peekStandby?.url != url else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.linkStatus.url == url, self.shouldPeek(modifiers: NSEvent.modifierFlags) else { return }
            self.renderPeekStandby(url)
        }
        peekStandbyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.08, execute: work)
    }
    /// The standby page uses the hovered page's engine, as the Peek it becomes does.
    func renderPeekStandby(_ url: URL) {
        discardPeekStandby()
        let tab = configure(BrowserTab())
        // It renders invisibly behind the page, so it mustn't take hover until it's shown.
        setCovered(true, tab)
        peekStandbyView.alphaValue = 0; peekStandbyView.addSubview(tab.page.view)
        if peekStandbyView.superview == nil { root.addSubview(peekStandbyView, positioned: .below, relativeTo: pageShadow) }
        peekStandby = (url, tab); layoutPeekStandby(); tab.load(url)
        // An abandoned standby page stops using resources after a while.
        let expiry = DispatchWorkItem { [weak self] in self?.discardPeekStandby() }
        peekStandbyExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now()+20, execute: expiry)
    }
    func layoutPeekStandby() {
        peekStandbyView.frame = peekCardFrame
        // At the size it will have in the card, under the Peek's bar.
        let bar = Self.peekBarHeight, bounds = peekStandbyView.bounds
        peekStandby?.tab.page.view.frame = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height-bar))
    }
    /// Hands over the standby page if it is the one being Peeked; otherwise drops it.
    func takePeekStandby(for url: URL) -> BrowserTab? {
        guard let standby = peekStandby, standby.url == url else { discardPeekStandby(); return nil }
        peekStandby = nil; peekStandbyExpiry?.cancel(); peekStandbyExpiry = nil
        standby.tab.page.view.removeFromSuperview()
        return standby.tab
    }
    func discardPeekStandby() {
        peekStandbyExpiry?.cancel(); peekStandbyExpiry = nil
        guard let standby = peekStandby else { return }
        peekStandby = nil
        permissionCoordinator.cancel(for: standby.tab.page.view)
        standby.tab.cancelLoad(); standby.tab.page.view.removeFromSuperview()
    }
}
