import CryptoKit
import Foundation

/// One verified rule bundle for WebKit and Chromium. Executable snippets only come from
/// these bundled assets, never a page's message or a downloaded filter.
public struct CookieConsentRules: Sendable {
    public static let worldName = "Rise.CookieConsent"
    public static let scriptMarker = "// Rise.CookieConsent\n"
    public let source: String
    public let evaluations: [String: String]

    public static func load(from directory: URL) throws -> Self {
        struct Manifest: Decodable {
            struct Asset: Decodable { let file: String; let sha256: String }
            let assets: [Asset]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("cookie-consent-manifest.json")))
        let expected: Set<String> = ["cookie-consent.js", "cookie-consent-evals.json"]
        guard manifest.assets.count == expected.count, Set(manifest.assets.map(\.file)) == expected else { throw Failure.resources }
        var assets: [String: Data] = [:]
        for asset in manifest.assets {
            let data = try Data(contentsOf: directory.appendingPathComponent(asset.file))
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw Failure.resources }
            assets[asset.file] = data
        }
        guard let source = assets["cookie-consent.js"].flatMap({ String(data: $0, encoding: .utf8) }),
              let evaluations = assets["cookie-consent-evals.json"] else { throw Failure.resources }
        return Self(source: scriptMarker+source, evaluations: try JSONDecoder().decode([String: String].self, from: evaluations))
    }
    public enum Failure: LocalizedError {
        case resources
        public var errorDescription: String? { "The bundled cookie-dialog rules couldn't be loaded or verified." }
    }
}

/// Each platform chooses its default; explicit site choices persist independently.
/// www and the bare host share an exception; subdomains remain independent.
/// A nil store is an in-memory private-browsing preference.
@MainActor public final class CookieConsentPolicy {
    public static let preferenceKey = "Rise.CookieConsent.DisabledSites"
    private static let enabledPreferenceKey = "Rise.CookieConsent.EnabledSites"
    private let preferences: UserDefaults?
    private let defaultEnabled: Bool
    private var privateDisabledSites = Set<String>()
    private var privateEnabledSites = Set<String>()
    public init(preferences: UserDefaults? = .standard, defaultEnabled: Bool = true) {
        self.preferences = preferences; self.defaultEnabled = defaultEnabled
        if let preferences, preferences.object(forKey: Self.preferenceKey) == nil,
           let old = preferences.stringArray(forKey: "Rise.iOS.CookieBanners.DisabledSites") {
            preferences.set(old, forKey: Self.preferenceKey)
        }
    }
    public static func site(_ url: URL?) -> String? {
        guard ["http", "https"].contains(url?.scheme?.lowercased() ?? ""), var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
    private var disabled: Set<String> { preferences?.stringArray(forKey: Self.preferenceKey).map(Set.init) ?? privateDisabledSites }
    private var enabled: Set<String> { preferences?.stringArray(forKey: Self.enabledPreferenceKey).map(Set.init) ?? privateEnabledSites }
    public func isEnabled(for url: URL?) -> Bool {
        guard let site = Self.site(url), !disabled.contains(site) else { return false }
        return enabled.contains(site) || defaultEnabled
    }
    public func setEnabled(_ enabled: Bool, for url: URL) {
        guard let site = Self.site(url) else { return }
        var denied = disabled, allowed = self.enabled
        if enabled { denied.remove(site); allowed.insert(site) }
        else { denied.insert(site); allowed.remove(site) }
        if let preferences {
            preferences.set(denied.sorted(), forKey: Self.preferenceKey)
            preferences.set(allowed.sorted(), forKey: Self.enabledPreferenceKey)
        } else { privateDisabledSites = denied; privateEnabledSites = allowed }
    }
    public func sharesStore(with other: CookieConsentPolicy) -> Bool { self === other || (defaultEnabled == other.defaultEnabled && preferences != nil && preferences === other.preferences) }
}
