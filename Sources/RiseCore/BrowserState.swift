import CryptoKit
import Foundation

public enum AddressResolver {
    public static func resolve(_ input: String, searchEngine: SearchEngine = .google) -> URL? {
        resolve(input) { searchEngine.searchURL(for: $0) }
    }
    /// An address for what was typed, or failing that a search for it with `search`.
    public static func resolve(_ input: String, search: (String) -> URL?) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "about:blank" { return URL(string: text) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        // Rise's own pages, such as rise://settings.
        if let url = URL(string: text), url.scheme?.lowercased() == "rise", url.host != nil { return url }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "file" || (["https", "http"].contains(scheme) && url.host != nil) { return url }
        if !text.contains(where: { $0.isWhitespace }), let candidate = URL(string: "https://" + text), let rawHost = candidate.host {
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
            if local || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")) || text.hasPrefix("[") {
                return URL(string: (local ? "http://" : "https://") + text)
            }
        }
        return search(text)
    }
    public static func displayHost(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "Search or Enter URL…" }
        return (url.host ?? url.lastPathComponent).replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
    public static func isLocal(_ url: URL?) -> Bool {
        guard let rawHost = url?.host else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }
}

public struct SavedTab: Codable, Equatable {
    public var id: UUID
    public var url: String
    public var title: String
    public var pinned: Bool
    public var developer: Bool
    public var customTitle: String?
    public var faviconData: Data?
    public var darkFaviconData: Data?
    public var faviconOrigin: String?
    /// The engine's archived session for the tab, including its back/forward list.
    public var sessionState: Data?
    public var navigationHistory: TabNavigationHistory?
    /// Nil in sessions from before uses were kept: its time starts when it's next restored.
    public var use: TabUse?
    public init(id: UUID = UUID(), url: String, title: String, pinned: Bool = false, developer: Bool = false, customTitle: String? = nil, faviconData: Data? = nil, darkFaviconData: Data? = nil, faviconOrigin: String? = nil, sessionState: Data? = nil, navigationHistory: TabNavigationHistory? = nil, use: TabUse? = nil) {
        self.id = id; self.url = url; self.title = title; self.pinned = pinned; self.developer = developer
        self.customTitle = customTitle
        self.faviconData = faviconData; self.darkFaviconData = darkFaviconData; self.faviconOrigin = faviconOrigin
        self.sessionState = sessionState
        self.navigationHistory = navigationHistory?.validated(for: url)
        self.use = use
    }
}
public struct SplitTabGroup: Codable, Equatable {
    public var id: UUID
    public var leftID: UUID
    public var rightID: UUID
    /// The left page's share of the room for both, set by dragging the handle between them.
    public var fraction: Double
    public static let fractionRange: ClosedRange<Double> = 0.2...0.8
    public init(id: UUID = UUID(), leftID: UUID, rightID: UUID, fraction: Double = 0.5) {
        self.id = id; self.leftID = leftID; self.rightID = rightID
        self.fraction = min(max(fraction, Self.fractionRange.lowerBound), Self.fractionRange.upperBound)
    }
    // Sessions saved before the handle existed have no fraction, so they split down the middle.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id), leftID: try container.decode(UUID.self, forKey: .leftID),
                  rightID: try container.decode(UUID.self, forKey: .rightID), fraction: try container.decodeIfPresent(Double.self, forKey: .fraction) ?? 0.5)
    }
    public func contains(_ id: UUID) -> Bool { leftID == id || rightID == id }
    public static func valid(_ groups: [SplitTabGroup], tabIDs: [UUID]) -> [SplitTabGroup] {
        let available = Set(tabIDs)
        var used = Set<UUID>(), groupIDs = Set<UUID>()
        return groups.filter { group in
            guard group.leftID != group.rightID, available.contains(group.leftID), available.contains(group.rightID),
                  !used.contains(group.leftID), !used.contains(group.rightID), !groupIDs.contains(group.id) else { return false }
            used.formUnion([group.leftID, group.rightID]); groupIDs.insert(group.id); return true
        }
    }
}
/// A tab's Peek, open or waiting behind it, with the page it shows.
public struct SavedPeek: Codable, Equatable {
    /// The tab the Peek belongs to, which shows it again when selected.
    public var ownerID: UUID
    public var tab: SavedTab
    /// The tab whose link opened it, when another tab's.
    public var sourceID: UUID?
    public var opensNewTab: Bool
    public init(ownerID: UUID, tab: SavedTab, sourceID: UUID? = nil, opensNewTab: Bool = false) {
        self.ownerID = ownerID; self.tab = tab; self.sourceID = sourceID; self.opensNewTab = opensNewTab
    }
    /// One for each tab still there, the first saved for it.
    public static func valid(_ peeks: [SavedPeek], tabIDs: [UUID]) -> [SavedPeek] {
        let available = Set(tabIDs)
        var owners = Set<UUID>()
        return peeks.filter { available.contains($0.ownerID) && !available.contains($0.tab.id) && owners.insert($0.ownerID).inserted }
    }
}
public struct BrowserSession: Codable, Equatable {
    public var tabs: [SavedTab]
    public var selectedID: UUID?
    public var theme: String
    public var sidebarWidth: Double
    public var splitGroups: [SplitTabGroup]
    /// Tabs' Peeks, open or waiting behind them; none in sessions from before they were kept.
    public var peeks: [SavedPeek]
    public init(tabs: [SavedTab] = [], selectedID: UUID? = nil, theme: String = "neutral", sidebarWidth: Double = 215, splitGroups: [SplitTabGroup] = [], peeks: [SavedPeek] = []) {
        self.tabs = tabs; self.selectedID = selectedID; self.theme = theme; self.sidebarWidth = sidebarWidth; self.splitGroups = splitGroups
        self.peeks = peeks
    }
    private enum CodingKeys: String, CodingKey { case tabs, selectedID, theme, sidebarWidth, splitGroups, peeks }
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try data.decode([SavedTab].self, forKey: .tabs)
        selectedID = try data.decodeIfPresent(UUID.self, forKey: .selectedID)
        theme = try data.decode(String.self, forKey: .theme)
        sidebarWidth = try data.decode(Double.self, forKey: .sidebarWidth)
        splitGroups = SplitTabGroup.valid(try data.decodeIfPresent([SplitTabGroup].self, forKey: .splitGroups) ?? [], tabIDs: tabs.map(\.id))
        peeks = SavedPeek.valid((try? data.decodeIfPresent([SavedPeek].self, forKey: .peeks)) ?? [], tabIDs: tabs.map(\.id))
    }
}
/// The session is `session.json`, and each tab's engine state, nearly all of its size, a file of its
/// own in `Tab States` beside it, written only when it changes. The session names each file by its
/// digest, so a file that's missing, or left from another time, is never restored: that tab opens
/// from its saved history instead. Sessions from before keep their state inline, and still read.
public enum SessionStorage {
    /// Encoded and written in the background, in order, so a save doesn't hold up the main thread.
    public static let writer = DispatchQueue(label: "dev.bartosz.Rise.session-writer", qos: .utility)
    static func statesFolder(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("Tab States", isDirectory: true) }
    static func stateFile(_ id: UUID, for url: URL) -> URL { statesFolder(for: url).appendingPathComponent(id.uuidString + ".state") }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Stored: Codable {
        var session: BrowserSession
        var stateFiles: [String: String]?
        init(session: BrowserSession, stateFiles: [String: String]?) { self.session = session; self.stateFiles = stateFiles }
        init(from decoder: Decoder) throws {
            session = try BrowserSession(from: decoder)
            stateFiles = try decoder.container(keyedBy: Key.self).decodeIfPresent([String: String].self, forKey: .stateFiles)
        }
        func encode(to encoder: Encoder) throws {
            try session.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encodeIfPresent(stateFiles, forKey: .stateFiles)
        }
        enum Key: String, CodingKey { case stateFiles }
    }
    public static func read(from url: URL) -> BrowserSession? {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        var session = stored.session
        for index in session.tabs.indices where session.tabs[index].sessionState == nil {
            let id = session.tabs[index].id
            guard let digest = stored.stateFiles?[id.uuidString], let state = try? Data(contentsOf: stateFile(id, for: url)),
                  Self.digest(state) == digest else { continue }
            session.tabs[index].sessionState = state
        }
        return session
    }
    /// The digests of the state files last written, so unchanged ones aren't written again.
    nonisolated(unsafe) private static var written: [String: String] = [:]
    private static let writtenLock = NSLock()
    public static func write(_ state: BrowserSession, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let folder = statesFolder(for: url)
        var session = state, files: [String: String] = [:]
        for index in session.tabs.indices {
            guard let data = session.tabs[index].sessionState else { continue }
            let id = session.tabs[index].id, file = stateFile(id, for: url), digest = Self.digest(data)
            let known = writtenLock.withLock { written[file.path] }
            if known != digest || !fileManager.fileExists(atPath: file.path) {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                writtenLock.withLock { written[file.path] = digest }
            }
            files[id.uuidString] = digest
            session.tabs[index].sessionState = nil
        }
        // The states first, then the session naming them, so it never names one not yet written.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Stored(session: session, stateFiles: files)).write(to: url, options: .atomic)
        // Then the states no tab has any more.
        let kept = Set(files.keys.map { $0 + ".state" })
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".state") && !kept.contains(name) {
            let file = folder.appendingPathComponent(name)
            try? fileManager.removeItem(at: file)
            writtenLock.withLock { written[file.path] = nil }
        }
    }
}
