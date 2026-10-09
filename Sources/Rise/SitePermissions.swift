import Foundation
import WebKit

enum SiteCapability: String, CaseIterable {
    case notifications, camera, microphone, location
    var title: String {
        switch self {
        case .notifications: return "Notifications"
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .location: return "Location"
        }
    }
    var symbol: String {
        switch self {
        case .notifications: return "bell.fill"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        }
    }
}
enum SitePermission: String, CaseIterable {
    case ask, allow, block
    var subtitle: String { self == .allow ? "Allowed" : self == .block ? "Blocked" : "Ask" }
}

/// Decisions are scoped to the requesting security origin, including its port.
/// Changing a site's preference never grants another frame or another site access.
@MainActor final class SitePermissions {
    static let preferenceKey = "Rise.SitePermissions"
    private let preferences: UserDefaults
    private var decisions: [String: [String: String]]
    init(preferences: UserDefaults) {
        self.preferences = preferences
        decisions = preferences.dictionary(forKey: Self.preferenceKey) as? [String: [String: String]] ?? [:]
    }
    static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
    static func origin(_ origin: WKSecurityOrigin) -> String? {
        // Pages without an origin, such as loaded HTML, report an empty scheme, which
        // URLComponents refuses with a crash.
        guard ["http", "https"].contains(origin.protocol.lowercased()) else { return nil }
        var parts = URLComponents(); parts.scheme = origin.protocol; parts.host = origin.host
        if origin.port > 0 { parts.port = origin.port }
        return Self.origin(parts.url)
    }
    func permission(_ capability: SiteCapability, origin: String?) -> SitePermission {
        guard let origin, let value = decisions[origin]?[capability.rawValue] else { return .ask }
        return SitePermission(rawValue: value) ?? .ask
    }
    func set(_ value: SitePermission, for capability: SiteCapability, origin: String) {
        decisions[origin, default: [:]][capability.rawValue] = value.rawValue
        preferences.set(decisions, forKey: Self.preferenceKey)
    }
    func hasDecision(_ capability: SiteCapability, origin: String?) -> Bool {
        origin.flatMap { decisions[$0]?[capability.rawValue] } != nil
    }
    func automaticPictureInPicture(origin: String?) -> Bool {
        guard let origin else { return false }
        return decisions[origin]?["automaticPictureInPicture"] != "block"
    }
    func setAutomaticPictureInPicture(_ allowed: Bool, origin: String) {
        decisions[origin, default: [:]]["automaticPictureInPicture"] = allowed ? "allow" : "block"
        preferences.set(decisions, forKey: Self.preferenceKey)
    }
}
