import Foundation

@MainActor public final class GoogleSearchSuggestions {
    nonisolated public static let maximumResults = 6
    private let session: URLSession
    private let delay: TimeInterval
    private var timer: Task<Void, Never>?
    /// Requests stay in flight while typing continues, oldest first; an answer for an
    /// earlier prefix still narrows the list until the current one arrives.
    private var tasks: [(query: String, task: URLSessionDataTask)] = []
    private static let maximumInFlight = 6
    private var token = UUID()
    private var query: String?
    public struct Suggestion: Equatable, Sendable {
        public let text: String
        public let isCalculator: Bool
    }
    private var values: [Suggestion] = []
    private var cache: [String: [Suggestion]] = [:]
    private var order: [String] = []
    private var warmedAt: Date?
    public var onLoad: ((String) -> Void)?

    /// The delay only merges keystrokes that land together, as when pasting.
    public init(session: URLSession? = nil, delay: TimeInterval = 0.02) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
            self.session = URLSession(configuration: config)
        }
        self.delay = delay
    }
    deinit { timer?.cancel(); tasks.forEach { $0.task.cancel() } }

    public func suggestions(for text: String) -> [String] { results(for: text).map(\.text) }

    public func results(for text: String) -> [Suggestion] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSearchQuery(text) else { cancel(); return [] }
        if query == text { return values }
        timer?.cancel(); timer = nil
        let shown = values
        query = text
        if let cached = cache[text] { values = cached; return cached }
        // The rows already showing stay until this query's own answer replaces them, so the
        // list keeps its height instead of collapsing to the direct search while Google answers.
        values = shown
        if values.isEmpty, let prefix = cachedPrefix(of: text) { values = Self.narrowResults(cache[prefix] ?? [], to: text) }
        guard !tasks.contains(where: { $0.query == text }) else { return values }
        let requestToken = token
        timer = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.delay))
            guard !Task.isCancelled else { return }
            self.fetch(text, token: requestToken)
        }
        return values
    }
    public func cancel() {
        token = UUID(); timer?.cancel(); timer = nil
        tasks.forEach { $0.task.cancel() }; tasks = []
        query = nil; values = []
    }
    /// Opens the connection to Google before the first keystroke, so the first
    /// suggestions skip the TLS handshake. The request carries no typed text.
    public func warmUp() {
        guard tasks.isEmpty, Date().timeIntervalSince(warmedAt ?? .distantPast) > 20 else { return }
        warmedAt = Date()
        var request = URLRequest(url: URL(string: "https://www.google.com/complete/search?client=chrome&q=")!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "HEAD"; request.httpShouldHandleCookies = false
        session.dataTask(with: request).resume()
    }
    nonisolated public static func narrow(_ terms: [String], to text: String) -> [String] {
        let typed = text.lowercased()
        return terms.filter { $0.lowercased().hasPrefix(typed) && $0.lowercased() != typed }
    }
    nonisolated private static func narrowResults(_ results: [Suggestion], to text: String) -> [Suggestion] {
        let terms = Set(narrow(results.map(\.text), to: text))
        return results.filter { terms.contains($0.text) }
    }
    private func cachedPrefix(of text: String) -> String? {
        order.last { $0.count < text.count && text.lowercased().hasPrefix($0.lowercased()) }
    }
    private func fetch(_ text: String, token requestToken: UUID) {
        guard token == requestToken, query == text else { return }
        timer = nil
        while tasks.count >= Self.maximumInFlight { tasks.removeFirst().task.cancel() }
        var endpoint = URLComponents(string: "https://www.google.com/complete/search")!
        endpoint.queryItems = [URLQueryItem(name: "client", value: "chrome"), URLQueryItem(name: "ie", value: "UTF-8"),
                               URLQueryItem(name: "hl", value: Locale.current.language.languageCode?.identifier ?? "en"),
                               URLQueryItem(name: "q", value: text)]
        var request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let results: [Suggestion]?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data {
                results = Self.parseResults(data, query: text)
            } else { results = nil }
            Task { @MainActor [weak self] in
                guard let self, self.token == requestToken else { return }
                self.tasks.removeAll { $0.query == text }
                guard let current = self.query else { return }
                guard let results else {
                    // No answer is coming for what's typed, so the held rows go.
                    if current == text, !self.values.isEmpty { self.values = []; self.onLoad?(current) }
                    return
                }
                self.cache[text] = results
                self.order.removeAll { $0 == text }; self.order.append(text)
                while self.order.count > 32 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                if current == text {
                    self.values = results; self.onLoad?(current)
                } else if self.cache[current] == nil, current.lowercased().hasPrefix(text.lowercased()) {
                    // An earlier prefix answered first: show what still fits until the current answer
                    // lands, unless that would shorten the list in the meantime.
                    let narrowed = Self.narrowResults(results, to: current)
                    guard !narrowed.isEmpty, narrowed.count >= self.values.count, narrowed != self.values else { return }
                    self.values = narrowed; self.onLoad?(current)
                }
            }
        }
        tasks.append((text, task))
        task.resume()
    }
    nonisolated public static func isSearchQuery(_ text: String) -> Bool {
        guard (2...256).contains(text.count), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !text.contains("://"), !text.contains("@"), let url = AddressResolver.resolve(text) else { return false }
        return url.host == "www.google.com" && url.path == "/search"
    }
    nonisolated public static func searchURL(for term: String) -> URL {
        SearchEngine.google.searchURL(for: term)
    }
    nonisolated public static func parse(_ data: Data, query: String) -> [String]? {
        parseResults(data, query: query)?.map(\.text)
    }
    nonisolated static func parseResults(_ data: Data, query: String) -> [Suggestion]? {
        guard data.count <= 128_000, let response = try? JSONSerialization.jsonObject(with: data) as? [Any],
              response.count >= 2, response[0] as? String == query, let results = response[1] as? [String] else { return nil }
        let metadata = response.dropFirst(4).first as? [String: Any]
        let types = metadata?["google:suggesttype"] as? [Any] ?? []
        var seen: Set<String> = [query.lowercased()]
        return results.enumerated().compactMap { index, value -> Suggestion? in
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 256, !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(term.lowercased()).inserted else { return nil }
            return Suggestion(text: term, isCalculator: types.indices.contains(index) && (types[index] as? String) == "CALCULATOR")
        }.prefix(maximumResults).map { $0 }
    }
}
