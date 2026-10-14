import Foundation

/// The durable part of a browser session. Live pages, Peeks and transient panels stay in memory.
struct MobileBrowserSession: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        let id: UUID
        var url: URL?
        var title: String?
        var isSyncPlaceholder: Bool?

        init(id: UUID = UUID(), url: URL?, title: String? = nil, isSyncPlaceholder: Bool? = nil) {
            self.id = id
            self.url = url
            self.title = title
            self.isSyncPlaceholder = isSyncPlaceholder
        }
    }

    let version: Int
    let tabs: [Tab]
    let selectedTabID: UUID

    init(tabs: [Tab], selectedTabID: UUID) {
        version = 1
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    static func canRestore(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// Preserve valid tabs if one entry is unusable, and choose a surviving tab if necessary.
    var validated: MobileBrowserSession? {
        guard version == 1 else { return nil }
        var seen = Set<UUID>()
        let usable = tabs.filter {
            ($0.url.map(Self.canRestore) ?? true) && seen.insert($0.id).inserted
        }
        guard let first = usable.first else { return nil }
        let selected = usable.contains { $0.id == selectedTabID } ? selectedTabID : first.id
        return MobileBrowserSession(tabs: usable, selectedTabID: selected)
    }
}

/// Lives in Application Support, so installing a new build retains the session. Ordered atomic
/// writes run off the main thread; the scene flushes them before it is suspended or disconnected.
@MainActor final class MobileBrowserSessionStore {
    static let shared = MobileBrowserSessionStore(fileURL:
        URL.applicationSupportDirectory.appending(path: "BrowserSession.json"))

    let fileURL: URL
    private let writer = DispatchQueue(label: "Rise.iOS.BrowserSession", qos: .utility)

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() -> MobileBrowserSession? {
        let file = fileURL
        return writer.sync {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            do { return try JSONDecoder().decode(MobileBrowserSession.self, from: Data(contentsOf: file)).validated }
            catch { print("Rise iOS: couldn't restore tabs: \(error.localizedDescription)"); return nil }
        }
    }

    func save(_ session: MobileBrowserSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let file = fileURL
        writer.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { print("Rise iOS: couldn't save tabs: \(error.localizedDescription)") }
        }
    }

    func flush() { writer.sync {} }
}
