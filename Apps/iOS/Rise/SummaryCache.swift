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

    static func summary(for key: String) -> PageSummary? {
        let file = folder.appendingPathComponent(key+".json")
        guard let data = try? Data(contentsOf: file),
              let paragraphs = try? JSONDecoder().decode([String].self, from: data), !paragraphs.isEmpty else { return nil }
        // Used now, so kept over older ones.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return PageSummary(paragraphs: paragraphs)
    }

    static func store(_ summary: PageSummary, for key: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(summary.paragraphs) else { return }
        try? data.write(to: folder.appendingPathComponent(key+".json"), options: .atomic)
        prune()
    }

    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limit) { try? manager.removeItem(at: file) }
    }
}
