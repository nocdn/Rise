import UIKit
import WebKit

/// The mobile adapter owns local visits; ranking, autocomplete, and learning live in shared code.
@MainActor final class MobileAddressSuggestions {
    let recordsBrowsing: Bool
    let history: BrowsingHistory
    let learner: SiteSearchLearner
    let icons: MobileSuggestionFavicons
    var onChange: (() -> Void)?
    private struct Visit { weak var page: WKWebView?; let key: String }
    private var lastAddresses: [ObjectIdentifier: Visit] = [:]
    private var saveTask: Task<Void, Never>?

    init(directory: URL, recordsBrowsing: Bool = true) {
        self.recordsBrowsing = recordsBrowsing
        let directory = recordsBrowsing ? directory : URL.temporaryDirectory.appendingPathComponent("RisePrivate-\(UUID())")
        history = BrowsingHistory(storageURL: directory.appendingPathComponent("history.json"))
        learner = SiteSearchLearner(storageURL: directory.appendingPathComponent("searches.json"))
        icons = MobileSuggestionFavicons(storageURL: recordsBrowsing ? directory.appendingPathComponent("suggestion-icons.json") : nil,
                                          allowsNetwork: recordsBrowsing)
        learner.onLearn = { [weak self] in self?.scheduleSave(); self?.onChange?() }
    }
    func changed(_ page: WKWebView) {
        guard recordsBrowsing else { return }
        learner.addressChanged(page)
        if !page.isLoading, let url = page.url, let key = BrowsingHistory.key(url) {
            let id = ObjectIdentifier(page)
            if lastAddresses[id]?.page !== page || lastAddresses[id]?.key != key { committed(page) }
            else if let title = page.title { history.updateTitle(title, for: url); scheduleSave() }
        }
    }
    func committed(_ page: WKWebView) {
        guard recordsBrowsing else { return }
        guard let url = page.url, let key = BrowsingHistory.key(url) else { return }
        lastAddresses = lastAddresses.filter { $0.value.page != nil }
        lastAddresses[ObjectIdentifier(page)] = Visit(page: page, key: key)
        history.record(url, title: page.title ?? url.host ?? "")
        scheduleSave()
    }
    func removeHistory(_ url: URL) {
        removeHistory([url])
    }
    func removeHistory(_ urls: [URL]) {
        var removed = false
        for url in urls { if history.remove(url) { removed = true } }
        if removed { scheduleSave() }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func save() {
        guard recordsBrowsing else { return }
        saveTask?.cancel(); saveTask = nil
        do { try history.save(); try learner.searches.save() }
        catch { NSLog("Rise address learning couldn't be saved: %@", error.localizedDescription) }
        icons.save()
    }
}
