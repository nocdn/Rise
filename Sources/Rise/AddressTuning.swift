import AppKit
import CoreText

/// Every value the address palette is drawn with, as one set: Rise's own by default, changed live
/// in the palette lab (`PaletteLab`).
struct AddressTuning: Codable, Equatable {
    enum Family: String, Codable, CaseIterable {
        case inter = "Inter", sfPro = "SF Pro", sfRounded = "SF Pro Rounded", sfCompact = "SF Compact"
        case sfMono = "SF Mono", newYork = "New York"
    }
    /// A colour that, once set, replaces the theme's own.
    enum ColorRole: String, Codable, CaseIterable {
        case background, border, text, secondary, icon, rowSelection, textSelection, shadow
    }

    var family = Family.inter
    /// SF Pro's width axis: 30 condensed, 100 regular, 150 expanded.
    var sfWidth: CGFloat = 100

    var newTabWidth: CGFloat = 520
    var centeredNewTabWidth: CGFloat = 640
    var addressWidth: CGFloat = 600
    var cornerRadius: CGFloat = 12
    /// Round the rows: their sides, and below the last.
    var inset: CGFloat = 7
    var headerHeight: CGFloat = 46
    var newTabHeaderHeight: CGFloat = 50
    var fieldIconInset: CGFloat = 9
    var fieldTextInset: CGFloat = 35
    var fieldTrailingInset: CGFloat = 12
    /// Between the field and the first row.
    var rowsTop: CGFloat = 0

    var rowHeight: CGFloat = 40
    var rowSpacing: CGFloat = 4
    var rowRadius: CGFloat = 6
    var rowIconInset: CGFloat = 9
    var rowTextInset: CGFloat = 35
    var rowTrailingInset: CGFloat = 9

    var textSize: CGFloat = 13.5
    var textWeight: CGFloat = 450
    var placeholderSize: CGFloat = 13.5
    var placeholderWeight: CGFloat = 500
    var siteSearchSize: CGFloat = 13.5
    var siteSearchWeight: CGFloat = 550
    var rowSize: CGFloat = 13.5
    var rowWeight: CGFloat = 450
    var addressSize: CGFloat = 13.5
    var addressWeight: CGFloat = 450
    var rowKern: CGFloat = 0.15
    /// The space between a row's title and its address.
    var addressGap: CGFloat = 3

    var fieldIconSize: CGFloat = 16
    var rowIconSize: CGFloat = 16

    /// Left to the theme while unset.
    var shadowOpacity: CGFloat?
    var shadowBlur: CGFloat = 24
    var shadowOffset: CGFloat = 8
    var borderWidth: CGFloat = 0.5
    /// Hex colours, `#RRGGBBAA`, by `ColorRole`.
    var colors: [String: String] = [:]

    func color(_ role: ColorRole) -> NSColor? { colors[role.rawValue].flatMap(NSColor.init(rgbaHex:)) }
    mutating func setColor(_ role: ColorRole, _ color: NSColor?) { colors[role.rawValue] = color?.rgbaHex }

    /// The family at a weight on the 100–900 scale. Made through Core Text, as NSFont caches by
    /// name and size and would hand back the first weight asked for.
    @MainActor func font(size: CGFloat, weight: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size)
        func design(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        let base: NSFont
        switch family {
        case .inter: return InterFont.font(ofSize: size, weight: weight)
        case .sfPro: base = system
        case .sfRounded: base = design(.rounded)
        case .sfMono: base = design(.monospaced)
        case .newYork: base = design(.serif)
        case .sfCompact: base = NSFont(name: "SFCompact-Regular", size: size) ?? system
        }
        // 'wght', and for SF Pro 'wdth'.
        var axes: [NSNumber: CGFloat] = [NSNumber(value: 0x7767_6874): weight]
        if family == .sfPro { axes[NSNumber(value: 0x7764_7468)] = sfWidth }
        let variation = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: axes] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base as CTFont, size, nil, variation) as NSFont
    }

    /// What differs from Rise's own values, as JSON.
    var changes: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let mine = try? JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: encoder.encode(AddressTuning())) as? [String: Any] else { return "{}" }
        let changed = mine.filter { key, value in !((base[key] as? NSObject)?.isEqual(value) ?? false) }
        guard let data = try? JSONSerialization.data(withJSONObject: changed, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension NSColor {
    convenience init?(rgbaHex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces); if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 24 & 0xFF)/255, green: CGFloat(value >> 16 & 0xFF)/255,
                  blue: CGFloat(value >> 8 & 0xFF)/255, alpha: CGFloat(value & 0xFF)/255)
    }
    var rgbaHex: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        let parts = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { Int(($0*255).rounded()) }
        return "#" + parts.map { String(format: "%02X", max(0, min(255, $0))) }.joined()
    }
}
