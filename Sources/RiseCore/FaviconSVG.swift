import Foundation

/// Resolve a site's SVG appearance CSS before rasterization. Image decoders do
/// not consistently inherit the browser chrome's color scheme for SVG images.
public enum FaviconSVG {
    public static func resolve(_ bytes: Data, dark: Bool) -> Data? {
        guard bytes.count <= 1_000_000, var svg = String(data: bytes, encoding: .utf8),
              svg.lowercased().contains("<svg"),
              let styles = try? NSRegularExpression(pattern: "<style\\b[^>]*>([\\s\\S]*?)</style>", options: .caseInsensitive) else { return nil }
        for match in styles.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).reversed() {
            guard let range = Range(match.range(at: 1), in: svg) else { continue }
            let css = appearanceRules(String(svg[range]), dark: dark)
            svg.replaceSubrange(range, with: css)
        }
        return Data(svg.utf8)
    }
    public static func appearanceRules(_ css: String, dark: Bool) -> String {
        guard let media = try? NSRegularExpression(pattern: "@media\\s*\\(\\s*prefers-color-scheme\\s*:\\s*(dark|light)\\s*\\)\\s*\\{", options: .caseInsensitive) else { return css }
        let chars = Array(css), text = css as NSString
        var output = "", position = 0
        // Match media headers, then balance braces (including nested CSS rules),
        // skipping quoted strings and comments so a content value can't end a rule.
        for match in media.matches(in: css, range: NSRange(location: 0, length: text.length)) {
            guard let header = Range(match.range, in: css) else { continue }
            let start = css.distance(from: css.startIndex, to: header.lowerBound)
            let body = css.distance(from: css.startIndex, to: header.upperBound)
            guard start >= position else { continue }
            var end = body, depth = 1, quote: Character?, comment = false
            while end < chars.count, depth > 0 {
                let c = chars[end], next = end+1 < chars.count ? chars[end+1] : "\0"
                if comment {
                    if c == "*", next == "/" { comment = false; end += 1 }
                } else if let q = quote {
                    if c == "\\" { end += 1 } else if c == q { quote = nil }
                } else if c == "/", next == "*" { comment = true; end += 1 }
                else if c == "\"" || c == "'" { quote = c }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1 }
                end += 1
            }
            guard depth == 0 else { break }
            output += String(chars[position..<start])
            if (text.substring(with: match.range(at: 1)).lowercased() == "dark") == dark {
                output += appearanceRules(String(chars[body..<(end-1)]), dark: dark)
            }
            position = end
        }
        return output + String(chars[position...])
    }
}
