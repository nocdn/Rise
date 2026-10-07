import AppKit
import WebKit

@MainActor extension BrowserController {
    func showHoveredLink(_ url: URL?, in webView: WKWebView, waitsForRefusal: Bool = true) {
        let visible = [selectedTab?.webView, splitTab?.webView, peekTab?.webView].compactMap { $0 }
        // A page under a Peek can still report a hover it had; only the top page shows its links.
        guard visible.contains(where: { $0 === webView }), webView.superview != nil,
              (webView as? LinkCursorWebView)?.isCovered != true else { return }
        if url == nil, hoveredWebView !== webView { return }
        refusedPeekHide?.cancel(); refusedPeekHide = nil
        // Pressing a link ends its hover just before a Shift-click is refused; keep "Cannot
        // open … in Peek" up through the press so the refusal shakes it rather than re-showing it.
        if url == nil, waitsForRefusal, linkStatus.peekBlocked, webView === peekTab?.webView {
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.refusedPeekHide = nil; self.showHoveredLink(nil, in: webView, waitsForRefusal: false)
            }
            refusedPeekHide = work
            DispatchQueue.main.asyncAfter(deadline: .now()+0.25, execute: work)
            return
        }
        if hoveredWebView !== webView || url == nil { (hoveredWebView as? LinkCursorWebView)?.keepPeekCursor(at: nil) }
        hoveredWebView = url == nil ? nil : webView
        linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: NSEvent.modifierFlags), blocked: hoversInsidePeek)
        root.addSubview(linkStatus, positioned: .below, relativeTo: dismissArea)
        layoutLinkStatus()
        if let url, linkPreloader.isComplete(url) { linkStatus.markReady(url) }
        keepHoveredLinkCursor(modifiers: NSEvent.modifierFlags)
        updatePeekStandby()
    }
    /// Links inside the Peek can't open another Peek; there's only ever one.
    var hoversInsidePeek: Bool { hoveredWebView != nil && hoveredWebView === peekTab?.webView }
    func updateHoveredLinkModifiers(_ flags: NSEvent.ModifierFlags) {
        if let web = hoveredWebView, web.superview != nil, let url = linkStatus.url {
            linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: flags), blocked: hoversInsidePeek)
            linkStatus.place(in: web.convert(web.bounds, to: root))
            keepHoveredLinkCursor(modifiers: flags)
        }
        updatePeekStandby(modifiers: flags)
    }
    func updateHoveredLinkCursor(_ event: NSEvent) {
        if event.type == .mouseMoved, shouldPeek(modifiers: event.modifierFlags) {
            keepHoveredLinkCursor(modifiers: event.modifierFlags)
        } else { (hoveredWebView as? LinkCursorWebView)?.keepPeekCursor(at: nil) }
    }
    private func keepHoveredLinkCursor(modifiers: NSEvent.ModifierFlags) {
        guard let web = hoveredWebView as? LinkCursorWebView else { return }
        guard linkStatus.url != nil, let window, window.isKeyWindow, !isSwitchingTabs, !palette.isPresented,
              let container = root.superview,
              let hit = root.hitTest(container.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
              hit.isDescendant(of: web) else { web.keepPeekCursor(at: nil); return }
        let point = web.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        web.keepPeekCursor(at: shouldPeek(modifiers: modifiers) ? point : nil)
        NSCursor.pointingHand.set()
    }
    func hideLinkStatus() {
        (hoveredWebView as? LinkCursorWebView)?.keepPeekCursor(at: nil)
        hoveredWebView = nil; linkStatus.show(nil, theme: theme)
    }
    func layoutLinkStatus() {
        guard let webView = hoveredWebView, webView.superview != nil else { hideLinkStatus(); return }
        let page = webView.convert(webView.bounds, to: root)
        if let url = linkStatus.url { linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: NSEvent.modifierFlags), blocked: hoversInsidePeek) }
        linkStatus.place(in: page)
    }
}
