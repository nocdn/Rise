import UIKit
import WebKit

/// Summarise in a held link's menu: the linked page loads out of sight, the bar grows into a
/// panel that shimmers "Summarising", and the summary streams into it. It's the same summary as
/// the pinch's, asked for the same way, and kept for the page, so opening the link and pinching
/// finds it ready, to ask about.
@MainActor extension BrowserViewController {
    static let summariseLinkIdentifier = UIAction.Identifier("dev.bartosz.Rise.summariseLink")

    /// Adds Summarise after Open Here, or Open, in a link's menu.
    func addingSummarise(to actions: [UIMenuElement], url: URL?) -> [UIMenuElement] {
        guard let url, Self.canPeek(url), MobileAISettings.shared.enabled else { return actions }
        let summarise = UIAction(title: "Summarise", image: UIImage(systemName: LinkSummaryPanel.symbol),
                                 identifier: Self.summariseLinkIdentifier) { [weak self] _ in self?.summariseLink(url) }
        var added = false
        func insert(_ elements: [UIMenuElement]) -> [UIMenuElement] {
            let targets = [Self.openHereIdentifier, Self.openLinkIdentifier]
            for target in targets {
                guard !added else { break }
                if let index = elements.firstIndex(where: { ($0 as? UIAction)?.identifier == target }) {
                    added = true
                    var next = elements; next.insert(summarise, at: index+1); return next
                }
            }
            return elements.map { element in
                guard !added, let menu = element as? UIMenu else { return element }
                return menu.replacingChildren(insert(menu.children))
            }
        }
        let result = insert(actions)
        return added ? result : actions+[summarise]
    }

    /// Chosen in the menu: it starts once the menu has gone.
    func summariseLink(_ url: URL) {
        pendingLinkSummary = url
        guard !isLinkContextMenuOpen else { return }
        DispatchQueue.main.async { [weak self] in self?.startPendingLinkSummary() }
    }

    func startPendingLinkSummary() {
        guard let url = pendingLinkSummary else { return }
        pendingLinkSummary = nil
        guard view.window != nil, !isPanelOpen, presentedViewController == nil, summarise == nil, !isTabSwitcherOpen else { return }
        linkSummaryRun?.stopPage()
        let run = LinkSummaryRun(url: url, dataStore: websiteDataStore, videoPlayback: videoPlayback)
        linkSummaryRun = run
        let panel = bottomBar.linkSummary
        panel.begin(url)
        openPanel(.linkSummary)
        let keeps = !isPrivateBrowsing, choice = MobileAISettings.shared.modelChoice
        let success = UINotificationFeedbackGenerator()
        success.prepare()
        run.task = Task { [weak self, weak run] in
            guard let run else { return }
            // Only the run showing writes into the panel; an earlier one still finishes, to keep its summary.
            let showing = { [weak self, weak run] in self?.linkSummaryRun === run && run != nil }
            do {
                let snapshot = try await run.read(in: self?.view)
                run.stopPage()
                let finalURL = URL(string: snapshot.url)
                let known = keeps ? SummaryCache.summary(for: SummaryCache.key(of: snapshot)) ?? SummaryCache.linkSummary(for: url) : nil
                let summary: PageSummary
                if let known { summary = known } else {
                    guard let model = self?.summariseLinkModel else { return }
                    summary = try await model(snapshot, choice) { reply in
                        if showing() { panel.show(LinkSummaryPanel.display(reply), finished: false) }
                    }
                }
                if keeps {
                    SummaryCache.store(summary, for: SummaryCache.key(of: snapshot))
                    SummaryCache.storeLink(summary, for: [url]+[finalURL].compactMap { $0 })
                }
                guard showing() else { return }
                panel.show(summary.paragraphs.joined(separator: "\n\n"), finished: true)
                guard let self, isPanelOpen, bottomBar.panel == .linkSummary else { return }
                success.notificationOccurred(.success)
                #if DEBUG
                linkSummarySuccessCount += 1
                #endif
            } catch {
                run.stopPage()
                guard !Task.isCancelled, showing() else { return }
                // Sharing with the model declined: nothing to show.
                if error is CancellationError {
                    if let self, isPanelOpen, bottomBar.panel == .linkSummary { closePanel() }
                    return
                }
                panel.fail("Rise couldn’t summarise this page. "+((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }
}

/// Loads a held link's page out of sight, in the same website data as the page it's on, and
/// reads its text as Summarise reads a page.
@MainActor final class LinkSummaryRun: NSObject, WKNavigationDelegate {
    let url: URL
    let page: WKWebView
    var task: Task<Void, Never>?
    private var loaded: CheckedContinuation<Void, Never>?
    private var finished = false
    /// How long it waits for the page; whatever has loaded by then is read.
    static let timeout: Double = 20
    /// Its text is read again every `settleInterval` until it stops growing, at most this often.
    static let settleReads = 15, settleInterval = 0.4

    init(url: URL, dataStore: WKWebsiteDataStore, videoPlayback: VideoPlaybackPolicy) {
        self.url = url
        page = BrowserViewController.makeWebView(dataStore: dataStore, videoPlayback: videoPlayback)
        super.init()
        page.navigationDelegate = self
        page.isUserInteractionEnabled = false
        page.accessibilityElementsHidden = true
    }

    /// The page's text once it has loaded and its text has settled. It's laid out as wide as the
    /// screen, unseen behind everything, since text that isn't laid out can't be read.
    func read(in host: UIView?) async throws -> PageAssistant.Page {
        if let host {
            page.frame = host.bounds
            page.alpha = 0
            host.insertSubview(page, at: 0)
        }
        page.load(URLRequest(url: url))
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if finished { continuation.resume(); return }
                loaded = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.timeout))
                    self?.finish()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish() }
        }
        try Task.checkCancellation()
        // Text the page's scripts write after it loads: read again until it stops growing, and
        // for a page that has none yet, a while longer for it to come.
        var snapshot = try await PageAssistant.snapshot(of: page)
        for _ in 0..<Self.settleReads {
            try await Task.sleep(for: .seconds(Self.settleInterval))
            let next = try await PageAssistant.snapshot(of: page)
            let settled = !snapshot.text.isEmpty && next.text.count <= snapshot.text.count
            snapshot = next
            if settled { break }
        }
        return snapshot
    }

    private func finish() {
        finished = true
        loaded?.resume(); loaded = nil
    }

    func stopPage() {
        page.stopLoading()
        page.navigationDelegate = nil
        page.removeFromSuperview()
        finish()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish() }
}
