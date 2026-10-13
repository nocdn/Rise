import CryptoKit
import Foundation
import WebKit

/// Native filtering plus bundled, site-scoped compatibility fixes. Policy is applied before
/// navigation is allowed, including redirects; YouTube can never opt into filtering.
@MainActor final class MobileAdBlocker {
    static let shared = MobileAdBlocker()
    nonisolated static let scriptMarker = "// Rise.AdBlock\n"
    private static let preferenceKey = "Rise.iOS.AdBlocking.DisabledSites"
    private let preferences: UserDefaults
    // Pages can move between browser owners (Peek -> full tab). A single ledger also
    // prevents an old owner's pending preparation from undoing the new owner's policy.
    private static let versions = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private static let installed = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private static var generation = 0
    private static var compiledCatalog: Catalog?

    struct Manifest: Decodable, Sendable {
        struct Asset: Decodable, Sendable { let file: String; let sha256: String }
        let lists: [Asset]
        let scripts: [Asset]
    }
    private struct Inputs: Sendable { let rules: [(String, String)]; let scripts: [String] }
    private struct Catalog { let rules: [WKContentRuleList]; let scripts: [WKUserScript] }

    private static let compilation: Task<Catalog, Error> = Task { @MainActor in
        let input = try await Task.detached(priority: .userInitiated) {
            guard let manifestURL = Bundle.main.url(forResource: "adblock-manifest", withExtension: "json") else {
                throw Failure.missingResources
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            func read(_ asset: Manifest.Asset) throws -> String {
                guard let url = Bundle.main.url(forResource: asset.file, withExtension: nil) else { throw Failure.missingResources }
                let data = try Data(contentsOf: url)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == asset.sha256, let text = String(data: data, encoding: .utf8) else { throw Failure.invalidResources }
                return text
            }
            return Inputs(rules: try manifest.lists.map { ("Rise.iOS.Ads.\($0.sha256)", try read($0)) },
                          scripts: try manifest.scripts.map(read))
        }.value
        guard let store = WKContentRuleListStore.default() else { throw Failure.unavailable }
        var rules: [WKContentRuleList] = []
        for (identifier, json) in input.rules {
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) { rules.append(cached) }
            else {
                guard let rule = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                    throw Failure.unavailable
                }
                rules.append(rule)
            }
        }
        let catalog = Catalog(rules: rules, scripts: input.scripts.enumerated().map { index, source in
            WKUserScript(source: scriptMarker+source, injectionTime: index == 0 ? .atDocumentStart : .atDocumentEnd,
                         forMainFrameOnly: false, in: .page)
        })
        compiledCatalog = catalog
        return catalog
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        _ = Self.compilation // Prepare the immutable catalog while the initial UI opens.
    }

    static func isYouTube(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return ["youtube.com", "youtube-nocookie.com", "youtu.be", "youtubekids.com"].contains {
            host == $0 || host.hasSuffix("."+$0)
        }
    }

    private static func site(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func isEnabled(for url: URL?) -> Bool {
        guard !Self.isYouTube(url), let site = Self.site(url) else { return false }
        return !(preferences.stringArray(forKey: Self.preferenceKey) ?? []).contains(site)
    }

    func setEnabled(_ value: Bool, for url: URL) {
        guard !Self.isYouTube(url), let site = Self.site(url) else { return }
        var disabled = Set(preferences.stringArray(forKey: Self.preferenceKey) ?? [])
        if value { disabled.remove(site) } else { disabled.insert(site) }
        preferences.set(disabled.sorted(), forKey: Self.preferenceKey)
    }

    func prepare(_ page: WKWebView, for url: URL?) async throws {
        let id = beginPreparation(on: page)
        guard isEnabled(for: url) else { apply(false, to: page); return }
        _ = try await Self.compilation.value
        guard !Task.isCancelled, Self.versions.object(forKey: page)?.intValue == id else { throw CancellationError() }
        apply(true, to: page)
    }

    /// Normal navigations and reloads have a compiled catalog already. Make those policy
    /// decisions synchronously: an unnecessary async decision can race stopLoading().
    func prepareIfReady(_ page: WKWebView, for url: URL?) -> Bool {
        _ = beginPreparation(on: page)
        let enabled = isEnabled(for: url)
        guard !enabled || Self.compiledCatalog != nil else { return false }
        apply(enabled, to: page)
        return true
    }

    private func beginPreparation(on page: WKWebView) -> Int {
        Self.generation += 1
        Self.versions.setObject(NSNumber(value: Self.generation), forKey: page)
        return Self.generation
    }

    private func apply(_ enabled: Bool, to page: WKWebView) {
        if Self.installed.object(forKey: page)?.boolValue == enabled { return }
        let controller = page.configuration.userContentController
        // Also clear on an unknown controller: an adopted page can have been configured by
        // another instance using the same immutable catalog.
        if let catalog = Self.compiledCatalog { for rule in catalog.rules { controller.remove(rule) } }
        let otherScripts = controller.userScripts.filter { !$0.source.hasPrefix(Self.scriptMarker) }
        if otherScripts.count != controller.userScripts.count {
            controller.removeAllUserScripts()
            otherScripts.forEach(controller.addUserScript)
        }
        if enabled, let catalog = Self.compiledCatalog {
            catalog.rules.forEach(controller.add)
            catalog.scripts.forEach(controller.addUserScript)
        }
        Self.installed.setObject(NSNumber(value: enabled), forKey: page)
    }

    func isInstalled(on page: WKWebView) -> Bool { Self.installed.object(forKey: page)?.boolValue == true }

    private enum Failure: LocalizedError {
        case missingResources, invalidResources, unavailable
        var errorDescription: String? {
            switch self {
            case .missingResources: "The bundled ad-blocking filters are missing."
            case .invalidResources: "The bundled ad-blocking filters failed validation."
            case .unavailable: "WebKit couldn't prepare the ad-blocking filters."
            }
        }
    }
}
