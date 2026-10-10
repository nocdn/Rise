import Foundation

/// How sites without a search of Rise's own search, learned from a search made on them: the
/// address it went to, with the words searched for as `{q}`, so Tab searches the site from the
/// address bar as it does well-known ones.
public final class LearnedSearches {
    public struct Search: Codable, Equatable {
        public var name: String
        public var template: String
        public var learned: Date
    }
    public static let maximumSearches = 500
    public let storageURL: URL
    /// By the domain typed for the site, without "www.".
    public private(set) var searches: [String: Search] = [:]
    private var dirty = false

    public init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL), data.count <= 1_000_000,
           let saved = try? JSONDecoder().decode([String: Search].self, from: data) {
            searches = saved.filter { $0.value.template.contains("{q}") && URL(string: $0.value.template.replacingOccurrences(of: "{q}", with: "q")) != nil }
        }
    }

    /// Learns the site's search when `url` holds one of the `terms` just searched for on it. A site
    /// searched on its own subdomain (szukaj.onet.pl) is also searched from its domain (onet.pl).
    @discardableResult public func learn(from url: URL, terms: [String], name: String?, at date: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), let template = Self.template(from: url, terms: terms) else { return false }
        let domains = Self.domains(for: host)
        // A site Rise already knows how to search keeps that.
        guard !domains.contains(where: { PopularSites.site(forAddress: $0)?.isSearchable == true }) else { return false }
        let search = Search(name: Self.siteName(name, domains: domains), template: template, learned: date)
        for (index, domain) in domains.enumerated() {
            // A domain whose own pages have a search keeps it over a subdomain's.
            if index > 0, let existing = searches[domain], Self.searchesItself(existing, domain) { continue }
            if searches[domain] != search { searches[domain] = search; dirty = true }
        }
        if searches.count > Self.maximumSearches {
            for (domain, _) in searches.sorted(by: { $0.value.learned < $1.value.learned }).prefix(searches.count-Self.maximumSearches) {
                searches[domain] = nil
            }
        }
        return true
    }

    /// The learned site whose address `text` is exactly.
    public func site(forAddress text: String) -> PopularSite? {
        let domain = PopularSites.domain(ofAddress: text)
        guard let search = searches[domain] else { return nil }
        return PopularSite(name: search.name, domain: domain, search: search.template, color: nil)
    }

    /// `url` with the parameter, or else the path segment, holding a searched-for term as `{q}`.
    /// Other parameters are left out: they tend to be the page's state, not the search's.
    public static func template(from url: URL, terms: [String]) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.percentEncodedHost?.lowercased(), !host.isEmpty else { return nil }
        let wanted = Set(terms.map(normalized).filter { $0.count >= 2 })
        guard !wanted.isEmpty else { return nil }
        let site = scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        for item in parts.percentEncodedQueryItems ?? [] {
            if let value = item.value, wanted.contains(normalized(decoded(value))) { return site + path + "?" + item.name + "={q}" }
        }
        var segments = path.components(separatedBy: "/")
        guard let index = segments.firstIndex(where: { wanted.contains(normalized(decoded($0))) }) else { return nil }
        segments[index] = "{q}"
        return site + segments.joined(separator: "/")
    }
    private static func decoded(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// The host without "www.", then the domain it's on, if that's another.
    static func domains(for host: String) -> [String] {
        let host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return [host] }
        // Two-part country suffixes, as in example.co.uk, keep three labels.
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count-2]) ? 3 : 2
        guard labels.count > keep else { return [host] }
        return [host, labels.suffix(keep).joined(separator: ".")]
    }
    private static func searchesItself(_ search: Search, _ domain: String) -> Bool {
        guard let host = URL(string: search.template.replacingOccurrences(of: "{q}", with: "q"))?.host?.lowercased() else { return false }
        return host == domain || host == "www." + domain
    }
    /// The page's own name for its site, or else its domain's main word ("Onet" for szukaj.onet.pl).
    private static func siteName(_ name: String?, domains: [String]) -> String {
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !named.isEmpty, named.count <= 40 { return named }
        let word = domains.last!.split(separator: ".").first.map(String.init) ?? domains.last!
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    public func clear() throws {
        let previous = searches
        searches = [:]; dirty = true
        do { try save() }
        catch { searches = previous; dirty = true; throw error }
    }
    public func save() throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(searches).write(to: storageURL, options: .atomic)
        dirty = false
    }
}
