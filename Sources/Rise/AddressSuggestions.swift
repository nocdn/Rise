import AppKit
import RiseCore

@MainActor extension BrowserController {
    /// Match the complete destination, including its query and anchor. History
    /// normalizes scheme/host/default ports, but intentionally drops anchors.
    func openTab(for url: URL) -> BrowserTab? {
        guard url.user == nil, url.password == nil, let key = BrowsingHistory.key(url) else { return nil }
        return tabs.first {
            guard let candidate = $0.url, candidate.user == nil, candidate.password == nil else { return false }
            return BrowsingHistory.key(candidate) == key && candidate.fragment == url.fragment
        }
    }
    func suggestions(for text: String) -> [AddressSuggestion] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [AddressSuggestion] = [], seen = Set<String>()
        var typedURL: URL?
        let ranked = browsingHistory.ranked(for: query, limit: AddressAppearance.maximumSuggestions)
        func appendSite(title: String, url: URL, tabID: UUID? = nil, learned: Bool = false, fetchFavicon: Bool = true) {
            guard let key = BrowsingHistory.key(url), seen.insert(key).inserted else { return }
            let completion = learned ? BrowsingHistory.completion(for: query, url: url) : nil
            let destinationTab = tabID ?? openTab(for: url)?.id
            result.append(AddressSuggestion(title: title, subtitle: url.absoluteString, symbol: "globe", url: url,
                                            tabID: destinationTab, command: nil, completion: completion, fetchFavicon: fetchFavicon))
        }
        func appendHistory(_ entry: HistoryEntry) {
            guard let url = URL(string: entry.url) else { return }
            let tab = openTab(for: url)
            appendSite(title: tab?.title ?? entry.title, url: url, tabID: tab?.id, learned: true)
        }
        // A learned literal URL prefix takes Enter/autocomplete priority.
        if !query.isEmpty, let first = ranked.first, let url = URL(string: first.url),
           BrowsingHistory.completion(for: query, url: url) != nil {
            appendHistory(first)
        }
        if !query.isEmpty, let url = AddressResolver.resolve(query, searchEngine: searchEngine) {
            let search = url == searchEngine.searchURL(for: query)
            if search {
                result.append(AddressSuggestion(title: "Search \(searchEngine.title) for “\(query)”", subtitle: "", symbol: "magnifyingglass", url: url, tabID: nil, command: nil))
            } else { typedURL = url; appendSite(title: query, url: url, fetchFavicon: false) }
        }
        // On an empty query, the most useful learned sites come first.
        if query.isEmpty { ranked.forEach(appendHistory) }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for tab in tabs where words.allSatisfy({ (tab.title + " " + (tab.url?.absoluteString ?? "")).localizedCaseInsensitiveContains($0) }) {
            if let url = tab.url { appendSite(title: tab.title, url: url, tabID: tab.id) }
        }
        if !query.isEmpty { ranked.forEach(appendHistory) }
        // Opening the current address also offers recent destinations, while
        // retaining that exact address as the default Enter action.
        if !query.isEmpty, query == selectedTab?.url?.absoluteString {
            browsingHistory.ranked(for: "", limit: AddressAppearance.maximumSuggestions).forEach(appendHistory)
            for tab in tabs {
                if let url = tab.url { appendSite(title: tab.title, url: url, tabID: tab.id) }
            }
        }
        if query.isEmpty {
            for (name, address) in [("Hacker News", "https://news.ycombinator.com"), ("Wikipedia", "https://en.wikipedia.org"), ("GitHub", "https://github.com")] {
                appendSite(title: name, url: URL(string: address)!)
            }
        } else {
            for (name, symbol) in [("Toggle Developer Mode", "hammer"), ("Change Theme", "paintbrush"), ("Toggle Sidebar", "sidebar.left"), ("Split View", "rectangle.split.2x1")] where name.localizedCaseInsensitiveContains(query) {
                let command = AddressSuggestion(title: name, subtitle: "", symbol: symbol, url: nil, tabID: nil, command: name)
                if result.first?.completion != nil { result.append(command) }
                else { result.insert(command, at: 0) }
            }
        }
        if searchEngine == .google, palette.isPresented, (palette.input.currentEditor() as? NSTextView)?.hasMarkedText() != true,
           result.first?.command == nil {
            let remote = googleSearchSuggestions.suggestions(for: query)
            if !remote.isEmpty {
                // Remote completions must not push matching open tabs out of the list.
                let openTabPrefix = (result.lastIndex { $0.tabID != nil }).map { $0+1 } ?? 0
                result = Array(result.prefix(max(openTabPrefix, max(2, AddressAppearance.maximumSuggestions-remote.count))))
                var destinations = Set(result.compactMap { $0.url?.absoluteString })
                for term in remote {
                    let url = searchEngine.searchURL(for: term)
                    guard destinations.insert(url.absoluteString).inserted else { continue }
                    result.append(AddressSuggestion(title: term, subtitle: "", symbol: "magnifyingglass", url: url, tabID: nil, command: nil))
                }
            }
        } else { googleSearchSuggestions.cancel() }
        suggestionFavicons.preview(typedURL)
        return result.prefix(AddressAppearance.maximumSuggestions).map { suggestion in
            var suggestion = suggestion
            if suggestion.tabID == nil, suggestion.command == nil, let url = suggestion.url {
                suggestion.tabID = openTab(for: url)?.id
            }
            if suggestion.symbol == "globe" {
                let origin = SitePermissions.origin(suggestion.url)
                let tab = suggestion.tabID.flatMap { id in tabs.first { $0.id == id } } ??
                    tabs.first { origin != nil && SitePermissions.origin($0.url) == origin && $0.favicon != nil }
                suggestion.favicon = tab?.favicon ?? suggestionFavicons.image(for: suggestion.url, fetch: suggestion.fetchFavicon)
            }
            return suggestion
        }
    }

    @objc func confirmClearBrowsingHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Browsing History?"
        alert.informativeText = "Remove saved visits and learned address suggestions. Your open tabs and cookies will stay."
        alert.addButton(withTitle: "Clear History"); alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do { try self.clearBrowsingHistory() }
            catch {
                let failure = NSAlert(); failure.messageText = "History could not be cleared"
                failure.informativeText = error.localizedDescription; failure.beginSheetModal(for: window)
            }
        }
    }
    func clearBrowsingHistory() throws {
        try browsingHistory.clear()
        palette.removeInlineCompletion(); palette.refresh()
    }
}
