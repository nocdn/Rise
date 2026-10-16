import Foundation

/// Any search engine: its name, how to build its search address, and whether it's Google,
/// which offers suggestions as you type.
public struct SearchProvider {
    public let title: String
    public let searchURL: (String) -> URL?
    public let isGoogle: Bool
    public init(title: String, searchURL: @escaping (String) -> URL?, isGoogle: Bool) {
        self.title = title; self.searchURL = searchURL; self.isGoogle = isGoogle
    }
    public init(_ engine: SearchEngine) {
        self.init(title: engine.title, searchURL: { engine.searchURL(for: $0) }, isGoogle: engine == .google)
    }
}

public enum SearchEngine: String, CaseIterable {
    case google, kagi

    public var title: String { self == .google ? "Google" : "Kagi" }

    public func searchURL(for text: String) -> URL {
        var url = URLComponents(string: self == .google ? "https://www.google.com/search" : "https://kagi.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: text)]
        return url.url!
    }
}
