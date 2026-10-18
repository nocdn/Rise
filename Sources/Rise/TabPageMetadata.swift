import Foundation
import CoreFoundation
import RiseCore

/// Public document metadata only; no scripts, subresources or browser visits.
struct TabPageMetadata {
    let title: String?
    let lightIcon: URL?
    let darkIcon: URL?

    init(html: Data, url: URL) {
        lightIcon = FaviconDiscovery.icon(in: html, baseURL: url)
        darkIcon = FaviconDiscovery.icon(in: html, baseURL: url, dark: true)
        guard html.count <= 1_000_000,
              var text = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) else {
            title = nil; return
        }
        text = text.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: "", options: [.regularExpression, .caseInsensitive])
        let pattern = #"(?is)<title\b[^>]*>(.*?)</title\s*>"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let value = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) }
        let entities = ["nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
                        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "bull": "•"]
        let decoded = value.flatMap { CFXMLCreateStringByUnescapingEntities(nil, $0 as CFString, entities as CFDictionary) as String? }
        let normalized = decoded?.replacingOccurrences(of: #"[\s\p{Cc}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = normalized.flatMap { $0.isEmpty ? nil : String($0.prefix(512)) }
    }
}
