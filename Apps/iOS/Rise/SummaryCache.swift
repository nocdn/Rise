import CryptoKit
import Foundation

/// Summaries kept on disk across launches, by the page's address and a fingerprint of its text as
/// sent to the model, so a page summarised before and unchanged since flies straight to its
/// summary even after Rise was quit or reinstalled. A page whose text has changed gets a new
/// fingerprint and is summarised again. Not for private browsing.
enum SummaryCache {
    /// The most kept; the least recently used go first.
    static let limit = 300
    private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Summaries", isDirectory: true)

    /// The page's address and text, hashed.
    static func key(of page: PageAssistant.Page) -> String {
        let digest = SHA256.hash(data: Data((page.url+"\n"+page.title+"\n"+page.text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// As kept on disk: the paragraphs, and the questions asked under them since 8 November
    /// 2026. Earlier files are a plain list of paragraphs.
    private struct Kept: Codable {
        let paragraphs: [String]
        var conversation: [SummaryTurn]?
    }

    static func summary(for key: String) -> PageSummary? {
        let file = folder.appendingPathComponent(key+".json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        let kept = (try? JSONDecoder().decode(Kept.self, from: data))
            ?? (try? JSONDecoder().decode([String].self, from: data)).map { Kept(paragraphs: $0) }
        guard let kept, !kept.paragraphs.isEmpty else { return nil }
        // Used now, so kept over older ones.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return PageSummary(paragraphs: kept.paragraphs, conversation: kept.conversation ?? [])
    }

    static func store(_ summary: PageSummary, for key: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let kept = Kept(paragraphs: summary.paragraphs, conversation: summary.conversation.isEmpty ? nil : summary.conversation)
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: folder.appendingPathComponent(key+".json"), options: .atomic)
        prune()
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(key+".json"))
    }

    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) { try? manager.removeItem(at: file) }
    }
}
