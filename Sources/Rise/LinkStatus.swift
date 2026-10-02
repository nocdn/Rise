import AppKit
import WebKit

@MainActor extension BrowserController {
    func showHoveredLink(_ url: URL?, in webView: WKWebView) {
        let visible = [selectedTab?.webView, splitTab?.webView, peekTab?.webView].compactMap { $0 }
        guard visible.contains(where: { $0 === webView }), webView.superview != nil else { return }
        if url == nil, hoveredWebView !== webView { return }
        hoveredWebView = url == nil ? nil : webView
        linkStatus.show(url, theme: theme)
        root.addSubview(linkStatus, positioned: .below, relativeTo: dismissArea)
        layoutLinkStatus()
        if let url, linkPreloader.isComplete(url) { linkStatus.markReady(url) }
    }
    func hideLinkStatus() {
        hoveredWebView = nil; linkStatus.show(nil, theme: theme)
    }
    func layoutLinkStatus() {
        guard let webView = hoveredWebView, webView.superview != nil else { hideLinkStatus(); return }
        let page = webView.convert(webView.bounds, to: root)
        if let url = linkStatus.url { linkStatus.show(url, theme: theme) }
        linkStatus.place(in: page)
    }
}
