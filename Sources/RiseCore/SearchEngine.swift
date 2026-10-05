import Foundation

public enum SearchEngine: String, CaseIterable {
    case google, kagi

    public var title: String { self == .google ? "Google" : "Kagi" }

    public func searchURL(for text: String) -> URL {
        var url = URLComponents(string: self == .google ? "https://www.google.com/search" : "https://kagi.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: text)]
        return url.url!
    }
}
