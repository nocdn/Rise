import Foundation
import Security

/// App-wide AI preferences. Credentials stay on this device in Keychain, never in defaults or sync.
@MainActor final class MobileAISettings {
    static let shared = MobileAISettings()
    static let changed = Notification.Name("Rise.MobileAISettingsChanged")
    private let defaults: UserDefaults
    private let credentials: MobileAIKeyStore

    init(defaults: UserDefaults = .standard, credentials: MobileAIKeyStore = .init()) {
        self.defaults = defaults
        self.credentials = credentials
        #if DEBUG
        // Local developer installs can migrate the old development key into Keychain without
        // embedding it in the app. This environment variable is never used in distribution builds.
        if let legacy = ProcessInfo.processInfo.environment["RISE_AI_OPENROUTER_KEY"],
           credentials.key(for: .openRouter).isEmpty {
            try? credentials.set(legacy, for: .openRouter)
        }
        #endif
    }

    var enabled: Bool {
        get { defaults.object(forKey: "Rise.AI.Enabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "Rise.AI.Enabled")
            if !newValue { revokeSharingConsent() }
            notify()
        }
    }
    var provider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: AIProvider.preferenceKey) ?? "") ?? .openRouter }
        set {
            if newValue != provider { consentRevision += 1 }
            defaults.set(newValue.rawValue, forKey: AIProvider.preferenceKey)
            notify()
        }
    }
    func key(for provider: AIProvider) -> String { credentials.key(for: provider) }

    // Versioned and provider-specific: an existing key or the default-on toggle never
    // counts as permission to send page content. Disabling AI withdraws permission.
    private static let sharingVersion = 1
    private(set) var consentRevision = 0
    func hasSharingConsent(for provider: AIProvider) -> Bool {
        defaults.integer(forKey: consentKey(provider)) == Self.sharingVersion
    }
    func allowSharing(with provider: AIProvider) {
        defaults.set(Self.sharingVersion, forKey: consentKey(provider))
        notify()
    }
    func revokeSharingConsent() {
        for provider in AIProvider.allCases { defaults.removeObject(forKey: consentKey(provider)) }
        consentRevision += 1
        notify()
    }
    private func consentKey(_ provider: AIProvider) -> String { "Rise.AI.SharingConsent.\(provider.rawValue)" }
    func setKey(_ value: String, for provider: AIProvider) throws {
        try credentials.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
        notify()
    }
    var modelChoice: ModelChoice {
        ModelChoice(provider: provider, model: provider.defaultModel, effort: PageAssistant.reasoningEffort,
                    apiKey: key(for: provider))
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

/// Updating an existing item is atomic: a failed write never erases a previously saved key.
@MainActor final class MobileAIKeyStore {
    private let service: String
    private var cache: [AIProvider: String] = [:]
    init(service: String = "Rise AI API Key") { self.service = service }

    func key(for provider: AIProvider) -> String {
        if let value = cache[provider] { return value }
        var query = item(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        let value = String(data: data, encoding: .utf8) ?? ""
        cache[provider] = value
        return value
    }

    func set(_ value: String, for provider: AIProvider) throws {
        let query = item(provider)
        let status: OSStatus
        if value.isEmpty {
            let removed = SecItemDelete(query as CFDictionary)
            status = removed == errSecItemNotFound ? errSecSuccess : removed
        } else {
            let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updated == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            } else { status = updated }
        }
        guard status == errSecSuccess else { throw Failure.save }
        cache[provider] = value
    }

    private func item(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }
    enum Failure: LocalizedError {
        case save
        var errorDescription: String? { "Rise couldn’t save the API key securely. Please try again." }
    }
}

enum AIKeyValidation: Equatable {
    case unchecked, checking, valid, invalid, unavailable
}

/// Checking credentials makes no model request and incurs no generation charge.
enum AIKeyValidator {
    static func check(_ key: String, provider: AIProvider, session suppliedSession: URLSession? = nil) async -> AIKeyValidation {
        guard !key.isEmpty else { return .invalid }
        let session = suppliedSession ?? URLSession(configuration: .ephemeral)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let endpoint = provider == .openRouter ? "https://openrouter.ai/api/v1/key" : "https://api.openai.com/v1/models"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return .unavailable }
            if response.statusCode == 401 { return .invalid }
            guard response.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["data"] != nil else {
                return .unavailable
            }
            return .valid
        } catch { return .unavailable }
    }
}
