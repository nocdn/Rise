import Foundation

/// The ranked destination, independent of AppKit/UIKit and favicon rendering.
public struct AddressCandidate: Equatable {
    public let title: String
    public let subtitle: String
    public let symbol: String
    public let url: URL?
    public var tabID: UUID?
    public var completion: String?
    public var fetchFavicon = true
    public var isTypedAction = false
    public var isAutofill = false

    public init(title: String, subtitle: String = "", symbol: String = "globe", url: URL?, tabID: UUID? = nil,
                completion: String? = nil, fetchFavicon: Bool = true, isTypedAction: Bool = false, isAutofill: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.url = url; self.tabID = tabID
        self.completion = completion; self.fetchFavicon = fetchFavicon
        self.isTypedAction = isTypedAction; self.isAutofill = isAutofill
    }
}

public struct AddressSuggestionTab {
    public let id: UUID, title: String
    public let url: URL?
    public init(id: UUID, title: String, url: URL?) { self.id = id; self.title = title; self.url = url }
}

/// One algorithm for Mac and iPhone: learned literal prefixes, popular sites, typed actions,
/// open tabs, and frecency-ranked history. Icons and platform commands are attached by each UI.
public enum AddressSuggestionEngine {
    public static func openTab(for url: URL, in tabs: [AddressSuggestionTab]) -> AddressSuggestionTab? {
        guard url.user == nil, url.password == nil, let key = BrowsingHistory.key(url) else { return nil }
        return tabs.first {
            guard let candidate = $0.url, candidate.user == nil, candidate.password == nil else { return false }
            return BrowsingHistory.key(candidate) == key && candidate.fragment == url.fragment
        }
    }

    public static func suggestions(for text: String, history: BrowsingHistory, tabs: [AddressSuggestionTab],
                                   currentURL: URL? = nil, editingCurrentAddress: Bool = false,
                                   searchEngine: SearchEngine = .google, limit: Int = 5) -> [AddressCandidate] {
        suggestions(for: text, history: history, tabs: tabs, currentURL: currentURL, editingCurrentAddress: editingCurrentAddress,
                    search: SearchProvider(searchEngine), limit: limit)
    }
    public static func suggestions(for text: String, history: BrowsingHistory, tabs: [AddressSuggestionTab],
                                   currentURL: URL? = nil, editingCurrentAddress: Bool = false,
                                   search: SearchProvider, limit: Int = 5) -> [AddressCandidate] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [AddressCandidate] = [], seen = Set<String>()
        let ranked = history.ranked(for: query, limit: limit)
        func appendSite(title: String, url: URL, learned: Bool = false, fetch: Bool = true, typed: Bool = false, completePath: Bool = false) {
            guard url.user == nil, url.password == nil, let key = BrowsingHistory.key(url), seen.insert(key).inserted else { return }
            result.append(AddressCandidate(title: title, subtitle: url.absoluteString, url: url,
                tabID: openTab(for: url, in: tabs)?.id, completion: learned ? BrowsingHistory.completion(for: query, url: url, includePath: completePath) : nil,
                fetchFavicon: fetch, isTypedAction: typed))
        }
        func appendHistory(_ entry: HistoryEntry, typed: Bool = false, completePath: Bool = false) {
            guard let url = URL(string: entry.url) else { return }
            appendSite(title: openTab(for: url, in: tabs)?.title ?? entry.title, url: url, learned: true, typed: typed, completePath: completePath)
        }
        if editingCurrentAddress, let key = BrowsingHistory.key(currentURL) { seen.insert(key) }
        // The site visited most across its pages, or its usual page (`BrowsingHistory.destination`).
        if !query.isEmpty, let destination = history.destination(for: query) {
            if let page = destination.page { appendHistory(page, typed: true, completePath: true) }
            else {
                let site = destination.site, saved = history.entries.first { $0.url == BrowsingHistory.key(site) }
                let domain = PopularSites.domain(ofAddress: site.absoluteString)
                appendSite(title: PopularSites.site(forAddress: domain)?.name ?? openTab(for: site, in: tabs)?.title ?? saved?.title ?? domain,
                           url: site, learned: true, typed: true)
            }
        }
        if result.first?.completion == nil, let popular = PopularSites.completion(for: query),
           let key = BrowsingHistory.key(popular.site.homeURL), seen.insert(key).inserted {
            result.append(AddressCandidate(title: popular.site.name, subtitle: popular.site.homeURL.absoluteString,
                url: popular.site.homeURL, tabID: openTab(for: popular.site.homeURL, in: tabs)?.id,
                completion: popular.completed, isTypedAction: true, isAutofill: true))
        }
        if !query.isEmpty, let url = AddressResolver.resolve(query, search: search.searchURL) {
            if url == search.searchURL(query) {
                result.append(AddressCandidate(title: "Search \(search.title) for “\(query)”", symbol: "magnifyingglass",
                                               url: url, isTypedAction: true))
            } else { appendSite(title: query, url: url, fetch: false, typed: true) }
        }
        if query.isEmpty { ranked.forEach { appendHistory($0) } }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for tab in tabs where words.allSatisfy({ (tab.title+" "+(tab.url?.absoluteString ?? "")).localizedCaseInsensitiveContains($0) }) {
            if let url = tab.url { appendSite(title: tab.title, url: url) }
        }
        if !query.isEmpty { ranked.forEach { appendHistory($0) } }
        if !query.isEmpty, query == currentURL?.absoluteString {
            history.ranked(for: "", limit: limit).forEach { appendHistory($0) }
            for tab in tabs { if let url = tab.url { appendSite(title: tab.title, url: url) } }
        }
        if query.isEmpty {
            for (name, address) in [("Hacker News", "https://news.ycombinator.com"), ("Wikipedia", "https://en.wikipedia.org"), ("GitHub", "https://github.com")] {
                appendSite(title: name, url: URL(string: address)!)
            }
        }
        return Array(result.prefix(max(0, limit)))
    }

    /// Remote search terms cannot displace matching open tabs or the typed/default action.
    public static func merging(_ remote: [String], into local: [AddressCandidate], searchEngine: SearchEngine = .google,
                               limit: Int = 5, tabs: [AddressSuggestionTab] = []) -> [AddressCandidate] {
        merging(remote, into: local, search: SearchProvider(searchEngine), limit: limit, tabs: tabs)
    }
    public static func merging(_ remote: [String], into local: [AddressCandidate], search: SearchProvider,
                               limit: Int = 5, tabs: [AddressSuggestionTab] = []) -> [AddressCandidate] {
        guard !remote.isEmpty else { return Array(local.prefix(max(0, limit))) }
        let openPrefix = (local.lastIndex { $0.tabID != nil }).map { $0+1 } ?? 0
        var result = Array(local.prefix(max(openPrefix, max(2, limit-remote.count))))
        func key(_ url: URL) -> String {
            (BrowsingHistory.key(url) ?? url.absoluteString)+(url.fragment.map { "#"+$0 } ?? "")
        }
        var seen = Set(result.compactMap { $0.url.map(key) })
        for term in remote {
            let searchURL = search.searchURL(term)
            let resolved = AddressResolver.resolve(term, search: search.searchURL)
            guard let url = resolved.flatMap({
                ["http", "https"].contains($0.scheme ?? "") && $0.user == nil && $0.password == nil ? $0 : nil
            }) ?? searchURL else { continue }
            let isSearch = url == searchURL
            if seen.insert(key(url)).inserted {
                result.append(AddressCandidate(title: term, subtitle: isSearch ? "" : url.absoluteString,
                    symbol: isSearch ? "magnifyingglass" : "globe", url: url, tabID: openTab(for: url, in: tabs)?.id))
            }
        }
        return Array(result.prefix(max(0, limit)))
    }
}
