import Foundation

/// Text-only selection conversions, shared by macOS and iOS. No network or
/// lossy decoding: arbitrary binary mustn't become an unreadable menu item.
public enum SelectionBase64 {
    public static let maximumBytes = 65_536
    public static let encodedMessage = "Copied Base64"
    public static let decodedMessage = "Copied decoded value"

    public struct Decoded: Equatable {
        public let value: String
        public var preview: String {
            let visible = value.replacingOccurrences(of: "\r\n", with: " ↵ ")
                .replacingOccurrences(of: "\n", with: " ↵ ")
                .replacingOccurrences(of: "\r", with: " ↵ ")
                .replacingOccurrences(of: "\t", with: " ⇥ ")
            let text = visible.trimmingCharacters(in: .whitespaces).isEmpty
                ? visible.replacingOccurrences(of: " ", with: "␠") : visible
            return text.count > 80 ? String(text.prefix(80))+"…" : text
        }
    }

    /// Preserve precisely what was selected, including Unicode and whitespace.
    public static func encode(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= maximumBytes else { return nil }
        return Data(text.utf8).base64EncodedString()
    }

    /// Accept padded/unpadded Base64 and Base64url, including wrapped lines.
    /// Canonical padding bits and UTF-8 are checked rather than silently fixed.
    public static func decode(_ text: String) -> Decoded? {
        guard !text.isEmpty, text.utf8.count <= maximumBytes else { return nil }
        let bytes = text.utf8.filter { ![9, 10, 13, 32].contains($0) }
        let body = bytes.prefix { $0 != 61 }
        let padding = bytes.count-body.count
        guard body.count >= 2, body.count % 4 != 1, padding <= 2,
              bytes.dropFirst(body.count).allSatisfy({ $0 == 61 }),
              body.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43, 47, 45, 95].contains($0) }),
              !(body.contains(where: { [43, 47].contains($0) }) && body.contains(where: { [45, 95].contains($0) })) else { return nil }
        let needed = (4-body.count % 4) % 4
        guard padding == 0 || padding == needed else { return nil }
        let standard = String(decoding: body.map { $0 == 45 ? 43 : $0 == 95 ? 47 : $0 }, as: UTF8.self)
        guard let data = Data(base64Encoded: standard+String(repeating: "=", count: needed)),
              data.base64EncodedString() == standard+String(repeating: "=", count: needed),
              let value = String(data: data, encoding: .utf8), !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 32 && !(127...159).contains($0.value) || [9, 10, 13].contains($0.value) }) else { return nil }
        return Decoded(value: value)
    }
}
