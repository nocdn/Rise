import Foundation

/// A quote plus its neighbours and UTF-16 position, so repeats can be distinguished after reload.
public struct AnnotationAnchor: Codable, Equatable, Sendable {
    public var exact: String, prefix: String, suffix: String
    public var start: Int
    public init(exact: String, prefix: String = "", suffix: String = "", start: Int = 0) {
        self.exact = String(exact.prefix(12_000)); self.prefix = String(prefix.suffix(80)); self.suffix = String(suffix.prefix(80)); self.start = max(0, start)
    }
}
public struct PageAnnotation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var number: Int
    public var anchor: AnnotationAnchor
    public var draft: String
    public init(id: UUID = UUID(), number: Int, anchor: AnnotationAnchor, draft: String = "") {
        self.id = id; self.number = number; self.anchor = anchor; self.draft = draft
    }
}
public struct AnnotationExchange: Codable, Equatable, Sendable {
    public var annotationID: UUID
    public var question: String, answer: String
    public var prompt: String?
    public init(annotationID: UUID, question: String, answer: String, prompt: String? = nil) {
        self.annotationID = annotationID; self.question = String(question.prefix(8_000)); self.answer = String(answer.prefix(24_000))
        self.prompt = prompt.map { String($0.prefix(64_000)) }
    }
}
public struct AnnotationDocument: Codable, Equatable, Sendable {
    public var annotations: [PageAnnotation] = []
    public var exchanges: [AnnotationExchange] = []
    public var nextNumber = 1
    public init() {}
    public mutating func add(_ anchor: AnnotationAnchor) -> PageAnnotation? {
        guard !anchor.exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, annotations.count < 100 else { return nil }
        let note = PageAnnotation(number: nextNumber, anchor: anchor)
        nextNumber += 1; annotations.append(note); return note
    }
    public mutating func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }; exchanges.removeAll { $0.annotationID == id }
    }
    public mutating func append(_ exchange: AnnotationExchange) {
        guard annotations.contains(where: { $0.id == exchange.annotationID }), !exchange.answer.isEmpty else { return }
        exchanges.append(exchange)
        if exchanges.count > 80 { exchanges.removeFirst(exchanges.count-80) }
    }
}

/// Notes live beside the browser session, independently of tab identity and cloud tab sync.
@MainActor public final class PageAnnotationStore {
    public private(set) var documents: [String: AnnotationDocument]
    public private(set) var saveError: String?
    private let url: URL?
    public init(url: URL?) {
        self.url = url
        documents = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: AnnotationDocument].self, from: $0) } ?? [:]
    }
    public static func key(for url: URL?) -> String? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user == nil, parts.password == nil else { return nil }
        // Keep hash-router pages distinct, while ordinary article section links share their notes.
        if let fragment = parts.fragment, !fragment.hasPrefix("/") && !fragment.hasPrefix("!/") { parts.fragment = nil }
        return parts.url?.absoluteString
    }
    public func document(for key: String) -> AnnotationDocument { documents[key] ?? AnnotationDocument() }
    public func set(_ document: AnnotationDocument, for key: String) {
        documents[key] = document.annotations.isEmpty ? nil : document
        guard let url else { return }
        do {
            let data = try JSONEncoder().encode(documents)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic); saveError = nil
        } catch { saveError = error.localizedDescription }
    }
}
