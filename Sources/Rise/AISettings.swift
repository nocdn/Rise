import Foundation
import Security

/// API keys for AI providers, in the login keychain. Each is read at most once per launch, so a
/// rebuilt app asks for access once rather than on every request.
@MainActor final class AIKeys {
    nonisolated static let service = "Rise AI API Key"
    private var cache: [AIProvider: String?] = [:]
    /// Replaced in tests, which mustn't touch the real keychain.
    var read: (AIProvider) -> String? = AIKeys.keychainRead
    var write: (AIProvider, String?) -> Void = AIKeys.keychainWrite

    func key(for provider: AIProvider) -> String? {
        if let cached = cache[provider] { return cached }
        let key = read(provider)
        cache[provider] = key
        return key
    }
    func set(_ key: String?, for provider: AIProvider) {
        write(provider, key)
        cache[provider] = key
    }

    nonisolated static func keychainRead(_ provider: AIProvider) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    nonisolated static func keychainWrite(_ provider: AIProvider, _ key: String?) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider.rawValue]
        SecItemDelete(item as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var added = item
        added[kSecValueData as String] = Data(key.utf8)
        added[kSecAttrLabel as String] = "Rise \(provider.title) API Key"
        SecItemAdd(added as CFDictionary, nil)
    }
}

/// The model, reasoning effort and key each provider uses, chosen in rise://settings under AI.
@MainActor extension BrowserController {
    private func aiKey(_ provider: AIProvider, _ name: String) -> String { "Rise.AI.\(provider.rawValue).\(name)" }

    func aiModel(_ provider: AIProvider) -> String {
        preferences.string(forKey: aiKey(provider, "Model")).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
    }
    func setAIModel(_ model: String, for provider: AIProvider) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty || model == provider.defaultModel { preferences.removeObject(forKey: aiKey(provider, "Model")) }
        else { preferences.set(model, forKey: aiKey(provider, "Model")) }
    }

    func aiEffort(_ provider: AIProvider) -> String {
        let effort = preferences.string(forKey: aiKey(provider, "Effort")) ?? PageAssistant.reasoningEffort
        return provider.efforts.contains { $0.0 == effort } ? effort : PageAssistant.reasoningEffort
    }
    func setAIEffort(_ effort: String, for provider: AIProvider) {
        guard provider.efforts.contains(where: { $0.0 == effort }) else { return }
        preferences.set(effort, forKey: aiKey(provider, "Effort"))
    }

    /// Whether a key is saved, known without reading the keychain.
    func hasAIKey(_ provider: AIProvider) -> Bool { preferences.bool(forKey: aiKey(provider, "HasKey")) }
    func setAIKey(_ key: String?, for provider: AIProvider) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = key.map { !$0.isEmpty } ?? false
        aiKeys.set(saved ? key : nil, for: provider)
        preferences.set(saved, forKey: aiKey(provider, "HasKey"))
    }

    /// What the next request uses: the user's own key, which OpenRouter and OpenAI both need;
    /// OpenCode signs in on its own and keeps Rise's default model.
    var modelChoice: ModelChoice {
        let provider = aiProvider
        if provider == .openCode { return .openCode }
        return ModelChoice(provider: provider, model: aiModel(provider), effort: aiEffort(provider),
                           apiKey: hasAIKey(provider) ? aiKeys.key(for: provider) : nil)
    }
}
