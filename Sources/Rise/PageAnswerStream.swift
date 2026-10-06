import Foundation

/// The first line is a JSON snippet header; everything after it is the streamed answer.
/// Keeping the header separate lets Markdown stream unchanged, without displaying metadata.
struct PageAnswerStream {
    struct Output {
        var snippet: String?
        var text = ""
    }
    private var header = ""
    private var readingHeader = true
    private var pendingFence: String?
    private static let headerLimit = 16_384

    mutating func append(_ text: String) throws -> Output {
        guard readingHeader else { return Output(text: answerText(text)) }
        header += text
        header = String(header.drop(while: { $0.isWhitespace }))
        // Tolerate a model wrapping only the metadata in a JSON code fence.
        if pendingFence == nil {
            for fence in ["```json\n", "```json\r\n"] {
                if header.hasPrefix(fence) {
                    header = String(header.dropFirst(fence.count)); pendingFence = ""; break
                }
                if fence.hasPrefix(header) { return Output() }
            }
        }
        guard !header.isEmpty else { return Output() }
        // A model that omits the header can still answer; don't hold its prose until a newline.
        guard header.first == "{" else {
            guard pendingFence == nil else { throw Self.invalidHeader() }
            readingHeader = false
            defer { header = "" }
            return Output(text: header)
        }
        if let newline = header.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let snippet = try Self.snippet(in: String(header[..<newline]))
            let answer = String(header[header.index(after: newline)...])
            header = ""; readingHeader = false
            return Output(snippet: snippet, text: answerText(answer))
        }
        guard header.utf8.count <= Self.headerLimit else { throw Self.invalidHeader() }
        return Output()
    }

    mutating func finish() throws -> Output {
        guard readingHeader else {
            defer { pendingFence = nil }
            guard let pendingFence else { return Output() }
            let prefix = String(pendingFence.drop(while: { $0.isWhitespace }))
            return Output(text: "```".hasPrefix(prefix) ? "" : pendingFence)
        }
        guard !header.isEmpty else { return Output() }
        let snippet = try Self.snippet(in: header)
        header = ""; readingHeader = false
        return Output(snippet: snippet)
    }

    private mutating func answerText(_ text: String) -> String {
        guard var pending = pendingFence else { return text }
        pending += text
        let prefix = String(pending.drop(while: { $0.isWhitespace }))
        for fence in ["```\n", "```\r\n"] {
            if prefix.hasPrefix(fence) {
                pendingFence = nil; return String(prefix.dropFirst(fence.count))
            }
            if fence.hasPrefix(prefix) { pendingFence = pending; return "" }
        }
        pendingFence = nil; return pending
    }

    private static func snippet(in line: String) throws -> String {
        guard line.utf8.count <= headerLimit,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object.count == 1, let snippet = object["snippet"] as? String else { throw invalidHeader() }
        return snippet
    }
    private static func invalidHeader() -> PageAssistant.Failure {
        .service("The model returned an unreadable answer. Please try again.")
    }
}
