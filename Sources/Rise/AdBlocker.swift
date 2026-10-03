import Foundation
import WebKit
import CryptoKit

/// Immutable native rules, compiled once per process and cached on disk by
/// WebKit. Network and cosmetic blocking use the engine, not fetch overrides.
@MainActor enum AdBlockRules {
    struct Manifest: Decodable {
        struct List: Decodable { let file: String; let sha256: String; let rules: Int }
        let lists: [List]
    }
    static let compilation: Task<[WKContentRuleList], Error> = Task {
        let inputs = try await Task.detached(priority: .userInitiated) { () -> [(String, String)] in
            guard let manifestURL = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Blocking") else {
                throw NSError(domain: "Rise.AdBlocker", code: 3, userInfo: [NSLocalizedDescriptionKey: "The bundled blocking rules are missing."])
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            return try manifest.lists.map { list in
                let data = try Data(contentsOf: manifestURL.deletingLastPathComponent().appendingPathComponent(list.file))
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard hash == list.sha256, let json = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "Rise.AdBlocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bundled blocking rules failed validation."])
                }
                return ("Rise.Blocking.\(hash)", json)
            }
        }.value
        var compiled: [WKContentRuleList] = []
        for (identifier, json) in inputs {
            guard let store = WKContentRuleListStore.default() else {
                throw NSError(domain: "Rise.AdBlocker", code: 4, userInfo: [NSLocalizedDescriptionKey: "WebKit’s blocking rule store is unavailable."])
            }
            if let cached = try? await store.contentRuleList(forIdentifier: identifier) { compiled.append(cached) }
            else {
                guard let rule = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                    throw NSError(domain: "Rise.AdBlocker", code: 2, userInfo: [NSLocalizedDescriptionKey: "WebKit couldn’t compile the blocking rules."])
                }
                compiled.append(rule)
            }
        }
        return compiled
    }
}

@MainActor final class AdBlocker {
    static let preferenceKey = "Rise.AdBlocking"
    private let preferences: UserDefaults
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let blockedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var rules: [WKContentRuleList] = []
    private var changeGeneration = 0
    private(set) var enabled: Bool
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        enabled = preferences.object(forKey: Self.preferenceKey) == nil || preferences.bool(forKey: Self.preferenceKey)
    }
    func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        if !controllers.contains(controller) { controllers.add(controller); apply(to: controller) }
    }
    func prepare(_ webView: WKWebView) async throws {
        install(on: webView)
        guard enabled else { return }
        rules = try await AdBlockRules.compilation.value
        // Recheck the preference after compilation; a toggle may have happened.
        for controller in controllers.allObjects { apply(to: controller) }
    }
    func setEnabled(_ value: Bool) -> Task<Void, Error> {
        changeGeneration += 1; let generation = changeGeneration
        enabled = value; preferences.set(value, forKey: Self.preferenceKey)
        return Task {
            if value { rules = try await AdBlockRules.compilation.value }
            guard changeGeneration == generation else { return }
            for controller in controllers.allObjects { apply(to: controller) }
        }
    }
    private func apply(to controller: WKUserContentController) {
        if enabled {
            guard !rules.isEmpty, !blockedControllers.contains(controller) else { return }
            for rule in rules { controller.add(rule) }
            blockedControllers.add(controller)
        } else if blockedControllers.contains(controller) {
            for rule in rules { controller.remove(rule) }
            blockedControllers.remove(controller)
        }
    }
}
