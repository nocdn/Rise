import AppKit
import RiseCore

/// What happens as Rise's pages load, navigate and open links, as the engine reports it.
@MainActor extension BrowserController {
    func shouldPeek(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.shift) || modifiers.contains(.option)
    }
    /// A Shift- or Option-click on a link opens a Peek before Chromium sees the click, which would
    /// otherwise open a window or download the link.
    func takeLinkClick(_ event: NSEvent) -> Bool {
        if event.type != .leftMouseDown {
            if event.type == .leftMouseUp, takesLinkClick { takesLinkClick = false; return true }
            return takesLinkClick
        }
        takesLinkClick = false
        guard shouldPeek(modifiers: event.modifierFlags), let hovered = hoveredWebView, let url = linkStatus.url,
              page(showing: hovered) != nil,
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)), hit === hovered || hit.isDescendant(of: hovered) else { return false }
        takesLinkClick = true
        openModifiedLink(url, modifiers: event.modifierFlags, from: hovered)
        return true
    }
    @discardableResult func openModifiedLink(_ url: URL, modifiers: NSEvent.ModifierFlags, from source: NSView? = nil, opensNewTab: Bool = false) -> Bool {
        if shouldPeek(modifiers: modifiers) { showPeek(url: url, from: source, opensNewTab: opensNewTab); return true }
        if modifiers.contains(.command) {
            addTab(url: url, background: true, opener: tabs.first { $0.page.view === source }?.id ?? selectedID); return true
        }
        return false
    }
    /// Going somewhere new, not back or forward, leaves the tab's later held pages behind.
    func leaveForwardPages(of view: NSView) {
        if let tab = tabs.first(where: { $0.page.view === view }), !tab.forwardPages.isEmpty { dropForwardPages(of: tab) }
    }
    /// External schemes require a deliberate choice; never silently run them.
    func confirmOpeningInOtherApp(_ url: URL) {
        let alert = NSAlert(); alert.messageText = "Open in another app?"; alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        if let window { alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } } }
    }
    /// A page, as its view, starts loading somewhere new.
    func pageStartedLoading(_ webView: NSView) {
        pictureInPicture.navigationStarted(in: webView)
        permissionCoordinator.cancel(for: webView)
        if selectedTab?.page.view === webView { siteControlsPopover.close() }
        if let page = page(showing: webView) { historySwipe.cancel(for: page) }
        if hoveredWebView === webView { hideLinkStatus() }
        if errorWebView === webView { errorWebView = nil }; update()
    }
    /// A page, as its view, has loaded: it goes in the history, and its tab's picture, icon
    /// and find bar catch up.
    func pageFinishedLoading(_ webView: NSView) {
        if let tab = tabs.first(where: { $0.page.view === webView }), let url = tab.url, url.absoluteString != "about:blank" {
            tab.captureThumbnail()
            browsingHistory.record(url, title: historyTitle(tab.page.title ?? tab.title, url: url))
            discoverPageFavicon(tab.page)
        } else if let peek = allPeekTabs.first(where: { $0.page.view === webView }) {
            discoverPageFavicon(peek.page)
        }; update()
        if let tab = tabs.first(where: { $0.page.view === webView }) { findBars[tab.id]?.pageChanged() }
    }
    func showNavigationError(_ error: Error, in webView: NSView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showNavigationError(error.localizedDescription, in: webView)
    }
    func showNavigationError(_ message: String, in webView: NSView) {
        errorWebView = webView; errorMessage.stringValue = message; update()
    }
    /// A page's process ended, taking its media; it loads again.
    func pageCrashed(_ webView: NSView) {
        pictureInPicture.navigationStarted(in: webView)
        guard let page = page(showing: webView) else { return }
        if let tab = tabs.first(where: { $0.page === page }) { tabMedia.remove(tab.id) }
        page.reload()
    }
    /// Where a new download named `suggestedFilename` saves: in Downloads, numbered if the name's in use.
    func newDownloadDestination(_ suggestedFilename: String) -> URL {
        try? FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)
        let pending = downloads.pendingDestinations
        return Self.downloadDestination(for: suggestedFilename, in: downloadsFolder) {
            pending.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
