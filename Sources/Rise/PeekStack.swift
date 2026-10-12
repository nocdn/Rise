import AppKit
import WebKit

/// One Peek at a time; the link pill says so when another is asked for from inside it.
@MainActor extension BrowserController {
    /// Only the Peek's page takes hover and sets the cursor; the pages under it are covered.
    func updatePeekCovers() {
        for tab in tabs { setCovered(peekTab != nil, tab) }
        if let peekTab { setCovered(false, peekTab) }
        // The split's handle isn't for a page under a Peek.
        layoutSplitHandle()
    }
    /// Pressing the link already ended its hover and hid the pill, so bring back its
    /// "Cannot open … in Peek" for that link, then shake it.
    func refusePeek(_ url: URL) {
        guard let web = peekTab?.page.view else { return }
        refusedPeekHide?.cancel(); refusedPeekHide = nil
        hoveredWebView = web
        linkStatus.show(url, theme: theme, peek: true, blocked: true)
        root.addSubview(linkStatus, positioned: .below, relativeTo: dismissArea)
        linkStatus.place(in: web.convert(web.bounds, to: root))
        linkStatus.shake()
        // Two quick taps on the trackpad, in time with the shake.
        let haptics = NSHapticFeedbackManager.defaultPerformer
        haptics.perform(.generic, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.09) { haptics.perform(.generic, performanceTime: .now) }
    }
    /// A page under a Peek, or rendering out of sight, takes no hover and sets no cursor.
    func setCovered(_ covered: Bool, _ tab: BrowserTab) {
        (tab.webView as? LinkCursorWebView)?.isCovered = covered
        tab.page.isCovered = covered
    }
    /// The Peek's page once it has gone somewhere from where it opened.
    var peekHasNavigated: Bool { peekTab?.page.canGoBack == true }
    /// While a Peek is open, history buttons and shortcuts move through the Peek's pages.
    var historyPage: WebPage? { peekTab?.page ?? selectedTab?.page }
}
