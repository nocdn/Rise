import Foundation
import RiseCore

@MainActor final class GoogleSearchSuggestions {
    nonisolated static let maximumResults = 6
    private let session: URLSession
    private let delay: TimeInterval
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var token = UUID()
    private var query: String?
    private var values: [String] = []
    private var cache: [String: [String]] = [:]
    private var order: [String] = []
    var onLoad: ((String) -> Void)?

    init(session: URLSession? = nil, delay: TimeInterval = 0.18) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
            config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
            self.session = URLSession(configuration: config)
        }
        self.delay = delay
    }
    deinit { timer?.invalidate(); task?.cancel() }

    func suggestions(for text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSearchQuery(text) else { cancel(); return [] }
        if query == text { return values }
        cancel(); query = text
        if let cached = cache[text] { values = cached; return cached }
        let requestToken = token
        let pending = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch(text, token: requestToken) }
        }
        timer = pending; RunLoop.main.add(pending, forMode: .common)
        return []
    }
    func cancel() {
        token = UUID(); timer?.invalidate(); timer = nil; task?.cancel(); task = nil
        query = nil; values = []
    }
    private func fetch(_ text: String, token requestToken: UUID) {
        guard token == requestToken, query == text else { return }
        timer = nil
        var endpoint = URLComponents(string: "https://www.google.com/complete/search")!
        endpoint.queryItems = [URLQueryItem(name: "client", value: "chrome"), URLQueryItem(name: "ie", value: "UTF-8"),
                               URLQueryItem(name: "hl", value: Locale.current.language.languageCode?.identifier ?? "en"),
                               URLQueryItem(name: "q", value: text)]
        var request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            let results: [String]?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data {
                results = Self.parse(data, query: text)
            } else { results = nil }
            Task { @MainActor [weak self] in
                guard let self, self.token == requestToken, self.query == text else { return }
                self.task = nil
                guard let results else { return }
                self.values = results; self.cache[text] = results
                self.order.removeAll { $0 == text }; self.order.append(text)
                while self.order.count > 32 { self.cache.removeValue(forKey: self.order.removeFirst()) }
                self.onLoad?(text)
            }
        }
        task?.resume()
    }
    nonisolated static func isSearchQuery(_ text: String) -> Bool {
        guard (2...256).contains(text.count), !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !text.contains("://"), !text.contains("@"), let url = AddressResolver.resolve(text) else { return false }
        return url.host == "www.google.com" && url.path == "/search"
    }
    nonisolated static func searchURL(for term: String) -> URL {
        var url = URLComponents(string: "https://www.google.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: term)]
        return url.url!
    }
    nonisolated static func parse(_ data: Data, query: String) -> [String]? {
        guard data.count <= 128_000, let response = try? JSONSerialization.jsonObject(with: data) as? [Any],
              response.count >= 2, response[0] as? String == query, let results = response[1] as? [String] else { return nil }
        var seen: Set<String> = [query.lowercased()]
        return results.compactMap { value -> String? in
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 256, !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }.prefix(maximumResults).map { $0 }
    }
}
