import AppKit

/// AppKit decodes SVG icons, but doesn't evaluate prefers-color-scheme or root
/// presentation rules. Resolve those before decoding, keeping the site's own colors.
enum FaviconImage {
    static func hasAppearanceStyles(_ bytes: Data) -> Bool {
        String(data: bytes, encoding: .utf8)?.lowercased().contains("prefers-color-scheme") == true
    }
    static func decode(_ bytes: Data, dark: Bool) -> NSImage? {
        guard var svg = String(data: bytes, encoding: .utf8), svg.lowercased().contains("<svg"),
              let styles = try? NSRegularExpression(pattern: "<style\\b[^>]*>([\\s\\S]*?)</style>", options: .caseInsensitive) else {
            return NSImage(data: bytes)
        }
        let source = svg as NSString
        var rootPresentation: [String: String] = [:]
        for match in styles.matches(in: svg, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range(at: 1), in: svg) else { continue }
            let css = appearanceRules(source.substring(with: match.range(at: 1)), dark: dark)
            // Later stylesheets win; declarations within one stylesheet are read in order.
            rootPresentation.merge(presentation(in: css)) { later, _ in later }
            svg.replaceSubrange(range, with: css)
        }
        // AppKit also ignores :root presentation rules (ChatGPT uses one to override
        // fill="none"). Put those colors on the root, preserving child-specific artwork.
        if !rootPresentation.isEmpty,
           let document = try? XMLDocument(xmlString: svg, options: .nodeLoadExternalEntitiesNever),
           let root = document.rootElement() {
            for (name, value) in rootPresentation {
                root.removeAttribute(forName: name)
                root.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
            }
            svg = document.xmlString
        }
        return NSImage(data: Data(svg.utf8))
    }
    private static func presentation(in css: String) -> [String: String] {
        guard let rules = try? NSRegularExpression(pattern: ":root\\s*\\{([^{}]*)\\}", options: .caseInsensitive) else { return [:] }
        let text = css as NSString
        let properties: Set<String> = ["fill", "fill-opacity", "stroke", "stroke-opacity", "stroke-width", "color", "opacity"]
        var values: [String: String] = [:]
        for rule in rules.matches(in: css, range: NSRange(location: 0, length: text.length)) {
            for declaration in text.substring(with: rule.range(at: 1)).split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard parts.count == 2, properties.contains(parts[0].lowercased()), !parts[1].isEmpty else { continue }
                values[parts[0].lowercased()] = parts[1]
            }
        }
        return values
    }
    private static func appearanceRules(_ css: String, dark: Bool) -> String {
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
