import Foundation

public enum AddressResolver {
    public static func resolve(_ input: String, searchEngine: SearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "about:blank" { return URL(string: text) }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "file" || (["https", "http"].contains(scheme) && url.host != nil) { return url }
        if !text.contains(where: { $0.isWhitespace }), let candidate = URL(string: "https://" + text), let rawHost = candidate.host {
            let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
            if local || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")) || text.hasPrefix("[") {
                return URL(string: (local ? "http://" : "https://") + text)
            }
        }
        return searchEngine.searchURL(for: text)
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
    /// WebKit's archived session for the tab, including its back/forward list.
    public var sessionState: Data?
    public init(id: UUID = UUID(), url: String, title: String, pinned: Bool = false, developer: Bool = false, customTitle: String? = nil, faviconData: Data? = nil, darkFaviconData: Data? = nil, faviconOrigin: String? = nil, sessionState: Data? = nil) {
        self.id = id; self.url = url; self.title = title; self.pinned = pinned; self.developer = developer
        self.customTitle = customTitle
        self.faviconData = faviconData; self.darkFaviconData = darkFaviconData; self.faviconOrigin = faviconOrigin
        self.sessionState = sessionState
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
public struct BrowserSession: Codable, Equatable {
    public var tabs: [SavedTab]
    public var selectedID: UUID?
    public var theme: String
    public var sidebarWidth: Double
    public var splitGroups: [SplitTabGroup]
    public init(tabs: [SavedTab] = [], selectedID: UUID? = nil, theme: String = "neutral", sidebarWidth: Double = 215, splitGroups: [SplitTabGroup] = []) {
        self.tabs = tabs; self.selectedID = selectedID; self.theme = theme; self.sidebarWidth = sidebarWidth; self.splitGroups = splitGroups
    }
    private enum CodingKeys: String, CodingKey { case tabs, selectedID, theme, sidebarWidth, splitGroups }
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        tabs = try data.decode([SavedTab].self, forKey: .tabs)
        selectedID = try data.decodeIfPresent(UUID.self, forKey: .selectedID)
        theme = try data.decode(String.self, forKey: .theme)
        sidebarWidth = try data.decode(Double.self, forKey: .sidebarWidth)
        splitGroups = SplitTabGroup.valid(try data.decodeIfPresent([SplitTabGroup].self, forKey: .splitGroups) ?? [], tabIDs: tabs.map(\.id))
    }
}
public enum SessionStorage {
    public static func read(from url: URL) -> BrowserSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserSession.self, from: data)
    }
    public static func write(_ state: BrowserSession, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
