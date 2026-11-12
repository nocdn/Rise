import AppKit

/// Renders a chat answer's Markdown as Dia lays it out: paragraphs on 25 pt lines with 14 pt
/// between them, bullet and numbered lists, headings, code and quotes, with the inline styles
/// the find bar's answers already use (bold, italics, code and links).
enum AIChatMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: String, text: String)
        case quote(String)
        case code(String)
    }

    /// Splits text into blocks. While the answer is still coming, a last line that is only a
    /// marker so far (`-`, `1.`, `##`, a code fence) is held back so it never shows bare.
    static func blocks(_ text: String, finished: Bool = true) -> [Block] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if !finished, let last = lines.last, isBareMarker(last) { lines.removeLast() }
        var blocks: [Block] = [], paragraph: [String] = [], index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[index]); index += 1 }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && trimmed.count >= 3 { flush(); continue }
            let depth = min(3, line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }/2)
            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush(); blocks.append(.heading(level: match.1.count, text: String(match.2))); continue
            }
            if let match = trimmed.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush(); blocks.append(.bullet(depth: depth, text: String(match.1))); continue
            }
            if let match = trimmed.firstMatch(of: #/^(\d{1,3})[.)]\s+(.*)$/#) {
                flush(); blocks.append(.numbered(depth: depth, number: String(match.1), text: String(match.2))); continue
            }
            if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                flush(); blocks.append(.quote(String(match.1))); continue
            }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }
    private static func isBareMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.wholeMatch(of: #/#{1,6}|[-*+>]|\d{1,3}[.)]|`{1,3}\w*/#) != nil
    }

    static func render(_ text: String, colors: AIChatColors, finished: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = blocks(text, finished: finished)
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count-1
            let next = last ? nil : blocks[index+1]
            // Items of one list sit closer together than paragraphs.
            let listContinues: Bool
            switch (block, next) {
            case (.bullet, .bullet?), (.bullet, .numbered?), (.numbered, .numbered?), (.numbered, .bullet?): listContinues = true
            default: listContinues = false
            }
            let spacing = last ? 0 : listContinues ? 6 : AIChatStyle.paragraphSpacing
            let body = AIChatStyle.font()
            switch block {
            case .paragraph(let text):
                result.append(inline(text, font: body, color: colors, spacing: spacing))
            case .heading(let level, let text):
                let font = AIChatStyle.font(level <= 2 ? 17 : AIChatStyle.fontSize, weight: .semibold)
                result.append(inline(text, font: font, color: colors, spacing: last ? 0 : 8, lineHeight: level <= 2 ? 27 : AIChatStyle.lineHeight))
            case .bullet(let depth, let text):
                result.append(item("•", depth: depth, text: text, font: body, colors: colors, spacing: spacing))
            case .numbered(let depth, let number, let text):
                result.append(item(number+".", depth: depth, text: text, font: body, colors: colors, spacing: spacing))
            case .quote(let text):
                let quote = NSMutableAttributedString(attributedString: inline(text, font: body, color: colors, spacing: spacing))
                let paragraph = AIChatStyle.paragraph(spacing: spacing)
                paragraph.firstLineHeadIndent = 12; paragraph.headIndent = 12
                quote.addAttributes([.paragraphStyle: paragraph, .foregroundColor: colors.muted], range: NSRange(location: 0, length: quote.length))
                result.append(quote)
            case .code(let code):
                let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                var attributes = AIChatStyle.attributes(font, color: colors.text, lineHeight: 21, spacing: spacing)
                attributes[.backgroundColor] = colors.code
                result.append(NSAttributedString(string: code.isEmpty ? " " : code, attributes: attributes))
            }
            if !last { result.append(NSAttributedString(string: "\n", attributes: AIChatStyle.attributes(color: colors.text, spacing: spacing))) }
        }
        return result
    }

    /// A list item with its marker hanging in the margin, so wrapped lines line up with its text.
    private static func item(_ marker: String, depth: Int, text: String, font: NSFont, colors: AIChatColors, spacing: CGFloat) -> NSAttributedString {
        let indent = CGFloat(depth)*18, markerWidth: CGFloat = marker == "•" ? 16 : 22
        let line = NSMutableAttributedString(string: marker+"\t", attributes: AIChatStyle.attributes(font, color: marker == "•" ? colors.muted : colors.text))
        line.append(inline(text, font: font, color: colors, spacing: spacing))
        let paragraph = AIChatStyle.paragraph(spacing: spacing)
        paragraph.firstLineHeadIndent = indent+2; paragraph.headIndent = indent+markerWidth
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent+markerWidth)]
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Bold, italics, code and links in one block, as `FindBar.styled` reads them.
    static func inline(_ text: String, font: NSFont, color colors: AIChatColors, spacing: CGFloat = 0,
                       lineHeight: CGFloat = AIChatStyle.lineHeight) -> NSAttributedString {
        let base = AIChatStyle.attributes(font, color: colors.text, lineHeight: lineHeight, spacing: spacing)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let markdown = try? AttributedString(markdown: text, options: options) else { return NSAttributedString(string: text, attributes: base) }
        let result = NSMutableAttributedString()
        for run in markdown.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.stronglyEmphasized) ? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize-2, weight: .regular)
                attributes[.backgroundColor] = colors.code
                attributes[.baselineOffset] = AIChatStyle.baselineOffset(font, lineHeight: lineHeight)
            }
            attributes[.font] = runFont
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        return result
    }
}
