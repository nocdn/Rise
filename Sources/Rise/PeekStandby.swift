import AppKit
import WebKit

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
        guard shouldPeek(modifiers: modifiers), let web = hoveredWebView, let url = linkStatus.url,
              LinkPreloader.isEligible(url, from: web.url), peekStandby?.url != url else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.linkStatus.url == url, self.shouldPeek(modifiers: NSEvent.modifierFlags) else { return }
            self.renderPeekStandby(url)
        }
        peekStandbyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.08, execute: work)
    }
    func renderPeekStandby(_ url: URL) {
        discardPeekStandby()
        let tab = configure(BrowserTab())
        peekStandbyView.alphaValue = 0; peekStandbyView.addSubview(tab.webView)
        if peekStandbyView.superview == nil { root.addSubview(peekStandbyView, positioned: .below, relativeTo: pageShadow) }
        peekStandby = (url, tab); layoutPeekStandby(); tab.load(url)
        // An abandoned standby page stops using resources after a while.
        let expiry = DispatchWorkItem { [weak self] in self?.discardPeekStandby() }
        peekStandbyExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now()+20, execute: expiry)
    }
    func layoutPeekStandby() {
        peekStandbyView.frame = peekCardFrame
        peekStandby?.tab.webView.frame = peekStandbyView.bounds
    }
    /// Hands over the standby page if it is the one being Peeked; otherwise drops it.
    func takePeekStandby(for url: URL) -> BrowserTab? {
        guard let standby = peekStandby, standby.url == url else { discardPeekStandby(); return nil }
        peekStandby = nil; peekStandbyExpiry?.cancel(); peekStandbyExpiry = nil
        standby.tab.webView.removeFromSuperview()
        return standby.tab
    }
    func discardPeekStandby() {
        peekStandbyExpiry?.cancel(); peekStandbyExpiry = nil
        guard let standby = peekStandby else { return }
        peekStandby = nil
        permissionCoordinator.cancel(for: standby.tab.webView)
        standby.tab.cancelLoad(); standby.tab.webView.removeFromSuperview()
    }
}
