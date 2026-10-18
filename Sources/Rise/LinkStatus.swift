import AppKit

@MainActor extension BrowserController {
    func showHoveredLink(_ url: URL?, in webView: NSView, waitsForRefusal: Bool = true) {
        let visible = [selectedTab?.page.view, splitTab?.page.view, peekTab?.page.view].compactMap { $0 }
        // A page under a Peek can still report a hover it had; only the top page shows its links.
        guard visible.contains(where: { $0 === webView }), webView.superview != nil,
              page(showing: webView)?.isCovered != true else { return }
        if url == nil, hoveredWebView !== webView { return }
        linkHoverChanged(url, in: webView)
        refusedPeekHide?.cancel(); refusedPeekHide = nil
        // Pressing a link ends its hover just before a Shift-click is refused; keep "Cannot
        // open … in Peek" up through the press so the refusal shakes it rather than re-showing it.
        if url == nil, waitsForRefusal, linkStatus.peekBlocked, webView === peekTab?.page.view {
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.refusedPeekHide = nil; self.showHoveredLink(nil, in: webView, waitsForRefusal: false)
            }
            refusedPeekHide = work
            DispatchQueue.main.asyncAfter(deadline: .now()+0.25, execute: work)
            return
        }
        hoveredWebView = url == nil ? nil : webView
        linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: NSEvent.modifierFlags), blocked: hoversInsidePeek)
        root.addSubview(linkStatus, positioned: .below, relativeTo: dismissArea)
        layoutLinkStatus()
        if let url, linkPreloader.isComplete(url) { linkStatus.markReady(url) }
        updatePeekStandby()
    }
    /// Links inside the Peek can't open another Peek; there's only ever one.
    var hoversInsidePeek: Bool { hoveredWebView != nil && hoveredWebView === peekTab?.page.view }
    func updateHoveredLinkModifiers(_ flags: NSEvent.ModifierFlags) {
        if let web = hoveredWebView, web.superview != nil, let url = linkStatus.url {
            linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: flags), blocked: hoversInsidePeek)
            linkStatus.place(in: web.convert(web.bounds, to: root))
        }
        updatePeekStandby(modifiers: flags)
    }
    /// The page went away or changed: no link status, and no pull request card over its links.
    func hideLinkStatus() {
        clearLinkStatus()
        hideLinkCard()
    }
    /// Only the status. Leaving a link ends its hover, but its card stays while the pointer
    /// crosses into it.
    private func clearLinkStatus() {
        hoveredWebView = nil; linkStatus.show(nil, theme: theme)
    }
    func layoutLinkStatus() {
        guard let webView = hoveredWebView, webView.superview != nil else { clearLinkStatus(); return }
        let page = webView.convert(webView.bounds, to: root)
        if let url = linkStatus.url { linkStatus.show(url, theme: theme, peek: shouldPeek(modifiers: NSEvent.modifierFlags), blocked: hoversInsidePeek) }
        linkStatus.place(in: page)
    }
}
