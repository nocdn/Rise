import Foundation

/// Inspect bounded HTML metadata without rendering the site or executing scripts.
public enum FaviconDiscovery {
    public static func darkIcon(for url: URL?) -> URL? {
        githubIcon(for: url, dark: true)
    }
    public static func lightIcon(for url: URL?) -> URL? {
        githubIcon(for: url, dark: false)
    }
    /// The icon to show for one a page declares. Jira Server declares a grey placeholder, then
    /// swaps in its product's logo from JavaScript on some pages; Jira Software's sits beside it.
    public static func preferred(_ declared: URL) -> URL {
        guard declared.lastPathComponent == "fav-generic.png", declared.path.contains("/images/logos/favicons/") else { return declared }
        return declared.deletingLastPathComponent().appendingPathComponent("fav-jsw.png")
    }
    private static func githubIcon(for url: URL?, dark: Bool) -> URL? {
        guard url?.host?.lowercased() == "github.com", ["http", "https"].contains(url?.scheme?.lowercased() ?? "") else { return nil }
        return URL(string: "https://github.githubassets.com/favicons/favicon\(dark ? "-dark" : "").png")
    }
    public static func icon(in bytes: Data, baseURL: URL, dark: Bool = false) -> URL? {
        guard bytes.count <= 1_000_000,
              let html = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { return nil }
        let tags = matches("<(?:link|base)\\b[^>]*>", in: html)
        var base = baseURL
        if let tag = tags.first(where: { $0.lowercased().hasPrefix("<base") }),
           let href = attributes(tag)["href"], let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            base = url
        }
        let candidates = tags.compactMap { tag -> (url: URL, svg: Bool, themed: Bool, pixels: Int)? in
            guard tag.lowercased().hasPrefix("<link") else { return nil }
            let values = attributes(tag)
            let media = values["media"]?.lowercased() ?? ""
            let scheme = matches("\\(\\s*prefers-color-scheme\\s*:\\s*(?:light|dark)\\s*\\)", in: media).first
            if let scheme, scheme.contains("dark") != dark { return nil }
            let rel = values["rel"]?.lowercased().split(whereSeparator: { $0.isWhitespace }) ?? []
            guard rel.contains("icon") || rel.contains("apple-touch-icon"), let href = values["href"],
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
            let svg = values["type"]?.lowercased().contains("svg") == true || url.pathExtension.lowercased() == "svg"
            let pixels = (values["sizes"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { size -> Int? in
                let sides = size.split(separator: "x").compactMap { Int($0) }
                guard sides.count == 2, sides.allSatisfy({ $0 > 0 && $0 <= 16384 }) else { return nil }
                return min(sides[0], sides[1])
            }.max() ?? 0
            return (url, svg, scheme != nil, pixels)
        }
        if let icon = githubIcon(for: baseURL, dark: dark) { return icon }
        let themed = candidates.filter(\.themed)
        let eligible = themed.isEmpty ? candidates : themed
        let format = eligible.filter { $0.svg == dark }
        return ((format.isEmpty ? eligible : format).max(by: { $0.pixels < $1.pixels })?.url).map(preferred)
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
