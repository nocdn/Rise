import AppKit
import CoreText

/// Ioskeley Mono Regular, bundled with Rise (Ioskeley Mono 2.2.0, SIL Open Font License),
/// registered for Rise alone: developer mode's address, and what a notice says in its place.
@MainActor enum IoskeleyMonoFont {
    private static let postScriptName = "Ioskeley-Mono"
    private static let available: Bool = {
        if let url = Bundle.main.url(forResource: "IoskeleyMono-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: postScriptName, size: 12) != nil
    }()
    /// Developer mode's address, and the notices that take its place.
    static var developerAddress: NSFont { regular(ofSize: 12) }
    /// Ioskeley Mono, or the system's monospaced font where it isn't bundled, as in tests.
    static func regular(ofSize size: CGFloat) -> NSFont {
        (available ? NSFont(name: postScriptName, size: size) : nil) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
