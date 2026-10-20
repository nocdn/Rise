import AppKit
import CoreText

/// Inter, the variable font bundled with Rise (Inter 4.1, SIL Open Font License), registered for
/// Rise alone. It's used where named, at any weight on its 100–900 axis.
@MainActor enum InterFont {
    private static let postScriptName = "InterVariable"
    private static let available: Bool = {
        if let url = Bundle.main.url(forResource: "InterVariable", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: postScriptName, size: 12) != nil
    }()
    /// Inter at `weight`, or the system font at the nearest weight where it isn't bundled, as in tests.
    static func font(ofSize size: CGFloat, weight: CGFloat) -> NSFont {
        guard available else { return .systemFont(ofSize: size, weight: weight >= 550 ? .medium : .regular) }
        // Made through Core Text: NSFont caches a font by name and size, so every weight came back
        // as whichever was made first. 'wght' is the weight axis.
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: postScriptName,
                                                               kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): weight]] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }
}
