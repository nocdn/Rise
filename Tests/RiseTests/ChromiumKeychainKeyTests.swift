import XCTest
@testable import Rise

final class ChromiumKeychainKeyTests: XCTestCase {
    private final class Keychain: ChromiumKeychainKey.Store {
        var items: [String: Data] = [:], failing: Set<String> = [], writable = true
        func password(_ item: ChromiumKeychainKey.Item) -> ChromiumKeychainKey.Lookup {
            if failing.contains(item.service) { return .failed }
            return items[item.service].map { .found($0) } ?? .missing
        }
        func setPassword(_ password: Data, for item: ChromiumKeychainKey.Item) -> Bool {
            guard writable else { return false }
            items[item.service] = password; return true
        }
    }
    func testTheKeyMovesIntoRisesItemOnlyOnceItHoldsIt() {
        let key = Data("chromium-key".utf8), stale = Data("old".utf8)
        let keychain = Keychain()
        keychain.items = [ChromiumKeychainKey.chromium.service: key, ChromiumKeychainKey.rise.service: stale]
        XCTAssertTrue(ChromiumKeychainKey.prepareRiseItem(in: keychain))
        XCTAssertEqual(keychain.items[ChromiumKeychainKey.rise.service], key, "Rise's item takes the key cookies are encrypted with")
        XCTAssertEqual(keychain.items[ChromiumKeychainKey.chromium.service], key, "Chromium's stays, for an older Rise")
        keychain.items[ChromiumKeychainKey.rise.service] = stale; keychain.writable = false
        XCTAssertFalse(ChromiumKeychainKey.prepareRiseItem(in: keychain), "Not copied: Chromium's is kept, so nothing becomes unreadable")
        keychain.failing = [ChromiumKeychainKey.chromium.service]; keychain.writable = true
        XCTAssertFalse(ChromiumKeychainKey.prepareRiseItem(in: keychain), "Chromium's unreadable, as when access is denied: it's kept")
        XCTAssertTrue(ChromiumKeychainKey.prepareRiseItem(in: Keychain()), "A new profile starts in Rise's")
    }
}
