import Foundation
import Security

/// Chromium keeps the key it encrypts cookies and saved passwords with in the Keychain. Rise's
/// engine, unbranded, kept it in Chromium's item; Rise keeps it in its own, as Chrome keeps its
/// in "Chrome Safe Storage". Before the engine starts, the key is copied into Rise's item, and
/// Rise's is only used once it holds the same key, so nothing becomes unreadable. Chromium's
/// item stays, for an older Rise.
enum ChromiumKeychainKey {
    struct Item: Equatable { let service: String, account: String }
    static let chromium = Item(service: "Chromium Safe Storage", account: "Chromium")
    static let rise = Item(service: "Rise Safe Storage", account: "Rise")

    enum Lookup: Equatable { case found(Data), missing, failed }
    protocol Store {
        func password(_ item: Item) -> Lookup
        func setPassword(_ password: Data, for item: Item) -> Bool
    }

    /// Whether the engine can use Rise's item: it holds Chromium's key now, or there's no key
    /// in Chromium's to keep. Any doubt keeps Chromium's.
    static func prepareRiseItem(in store: Store) -> Bool {
        switch store.password(chromium) {
        case .failed: return false
        // Nothing was ever encrypted with Chromium's item: Rise's is used from the start.
        case .missing: return true
        case .found(let key):
            if store.password(rise) == .found(key) { return true }
            guard store.setPassword(key, for: rise) else { return false }
            return store.password(rise) == .found(key)
        }
    }

    /// The login keychain, where Chromium keeps its item.
    struct LoginKeychain: Store {
        private func query(_ item: Item) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service, kSecAttrAccount as String: item.account]
        }
        func password(_ item: Item) -> Lookup {
            var query = query(item)
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess: return (result as? Data).map(Lookup.found) ?? .failed
            case errSecItemNotFound: return .missing
            default: return .failed
            }
        }
        func setPassword(_ password: Data, for item: Item) -> Bool {
            let status = SecItemUpdate(query(item) as CFDictionary, [kSecValueData as String: password] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query(item); add[kSecValueData as String] = password
                return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            }
            return status == errSecSuccess
        }
    }
}
