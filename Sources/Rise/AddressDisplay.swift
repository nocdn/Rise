import Foundation

/// How Rise writes an address it shows: without `https://` and `www.` unless turned off in
/// rise://settings. Only what's shown; pages still open at their own addresses.
enum AddressDisplay {
    static let schemeKey = "Rise.HideAddressScheme", wwwKey = "Rise.HideAddressWWW"
    nonisolated(unsafe) static var hidesScheme = true, hidesWWW = true

    /// `address` as shown: `https://www.youtube.com/watch` as `youtube.com/watch`.
    static func text(_ address: String) -> String {
        var text = address, scheme = ""
        if let range = text.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) {
            scheme = String(text[range]); text.removeSubrange(range)
        }
        if hidesWWW, text.lowercased().hasPrefix("www."), text.count > 4 { text.removeFirst(4) }
        return hidesScheme ? text : scheme+text
    }
}

extension BrowserController {
    var hidesAddressScheme: Bool { preferences.object(forKey: AddressDisplay.schemeKey) as? Bool ?? true }
    var hidesAddressWWW: Bool { preferences.object(forKey: AddressDisplay.wwwKey) as? Bool ?? true }
    func loadAddressDisplay() {
        AddressDisplay.hidesScheme = hidesAddressScheme; AddressDisplay.hidesWWW = hidesAddressWWW
    }
    func setHidesAddressScheme(_ hides: Bool) { preferences.set(hides, forKey: AddressDisplay.schemeKey); addressDisplayChanged() }
    func setHidesAddressWWW(_ hides: Bool) { preferences.set(hides, forKey: AddressDisplay.wwwKey); addressDisplayChanged() }
    private func addressDisplayChanged() {
        loadAddressDisplay()
        if palette.isPresented { palette.render() }
    }
}
