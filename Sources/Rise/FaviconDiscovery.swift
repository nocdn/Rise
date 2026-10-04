import Foundation

/// Inspect bounded HTML metadata without rendering the site or executing scripts.
enum FaviconDiscovery {
    static func icon(in bytes: Data, baseURL: URL) -> URL? {
        guard bytes.count <= 1_000_000,
              let html = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { return nil }
        let tags = matches("<(?:link|base)\\b[^>]*>", in: html)
        var base = baseURL
        if let tag = tags.first(where: { $0.lowercased().hasPrefix("<base") }),
           let href = attributes(tag)["href"], let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            base = url
        }
        let candidates = tags.compactMap { tag -> (URL, Bool)? in
            guard tag.lowercased().hasPrefix("<link") else { return nil }
            let values = attributes(tag)
            let rel = values["rel"]?.lowercased().split(whereSeparator: { $0.isWhitespace }) ?? []
            guard rel.contains("icon") || rel.contains("apple-touch-icon"), let href = values["href"],
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
            let svg = values["type"]?.lowercased().contains("svg") == true || url.pathExtension.lowercased() == "svg"
            return (url, svg)
        }
        return candidates.first(where: { !$0.1 })?.0 ?? candidates.first?.0
    }
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    private static func attributes(_ tag: String) -> [String: String] {
        let pattern = "([a-z][a-z0-9-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [:] }
        var values: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag),
                  let value = (2...4).compactMap({ Range(match.range(at: $0), in: tag) }).first else { continue }
            values[String(tag[key]).lowercased()] = String(tag[value])
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
        }
        return values
    }
}
