import Foundation

/// Colours in any common notation — hex, rgb(a), hsl(a), hsv/hsb, cmyk, oklch, oklab and CSS names —
/// written in another, and what can be done to them on the way: mixed, lightened, darkened, made
/// transparent, inverted, or measured for contrast. "#ff6600" alone reads as rgb; "rgb(…)" as hex.
enum ColorCalculation {
    /// sRGB, each channel 0…1.
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double, a: Double = 1
    }

    static let formats = #"hex(?:adecimal)?(?: ?8| with alpha)?|rgba?|hsla?|hsva?|hsb|cmyk|oklch|oklab|(?:css |colou?r )?names?|named colou?r"#

    static func evaluate(_ query: String) -> AddressCalculation? {
        if let contrast = contrast(query) { return contrast }
        var text = query
        if let match = AddressCalculation.groups("^(" + formats + #")(?: code| value| format)? (?:for|of) (.+)$"#, in: text) {
            text = match[2] + " to " + match[1]
        } else if let match = AddressCalculation.groups("^(" + formats + ") (?:to|into|in) (" + formats + #")(?: converter| conversion| code)?:? (.+)$"#, in: text) {
            // "hex to rgb #3366cc", "rgb to hex 255 0 0": bare numbers are in the first notation.
            let bare = !match[1].hasPrefix("hex") && !match[3].hasPrefix(match[1].prefix(3))
            text = (bare ? match[1] + " " : "") + match[3] + " to " + match[2]
        } else if let match = AddressCalculation.groups(#"^(?:what|which) (?:css )?(?:colou?r|name) is (.+?)(?: called)?$|^(?:name of|what is the name of) (?:the )?(?:colou?r )?(.+)$"#, in: text) {
            text = (match[1].isEmpty ? match[2] : match[1]) + " to name"
        }
        // Formats come last, any number of times; the last ones decide, and there may be several:
        // "tomato to hex and rgb".
        let list = "(?:" + formats + #")(?: code| value| format| notation)?"#
        var targets: [String] = []
        while let match = AddressCalculation.groups(#"^(.+?) (?:(?:then )?(?:to|in|as|into)|then) (?:a |the )?("# + list + #"(?:(?:,? and |, | & )"# + list + ")*)$", in: text) {
            if targets.isEmpty {
                targets = match[2].components(separatedBy: ",").flatMap { $0.components(separatedBy: " and ") }.flatMap { $0.components(separatedBy: " & ") }
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    .compactMap { AddressCalculation.groups("^(" + formats + ")", in: $0)?[1] }
            }
            text = match[1]
        }
        guard let parsed = expression(text, target: targets.first) else { return nil }
        if targets.isEmpty, parsed.standsAlone { targets = [parsed.otherFormat] }
        let written = targets.compactMap { write(parsed.color, as: $0) }
        guard !written.isEmpty, written.count == targets.count else { return nil }
        return AddressCalculation(written.joined(separator: " · "), color: swatch(parsed.color))
    }

    struct Parsed {
        var color: RGB
        /// Written in a colour's own notation, or worked out: worth an answer without a format asked for.
        var standsAlone: Bool
        /// The notation to show when none is asked for: rgb for hex, hex for the rest.
        var otherFormat: String
    }

    // MARK: - Reading

    static func expression(_ text: String, target: String?) -> Parsed? {
        func worked(_ color: RGB) -> Parsed { Parsed(color: color, standsAlone: true, otherFormat: "hex") }
        // "mix red and blue", "mix #fff 25% with black"
        if let match = AddressCalculation.groups(#"^mix (.+?)(?: (\d{1,3})%)? (?:and|with|\+|&) (.+?)(?: (\d{1,3})%)?$"#, in: text),
           let first = expression(match[1], target: "hex"), let second = expression(match[3], target: "hex") {
            let weight = (Double(match[2]) ?? Double(match[4]).map { 100-$0 } ?? 50)/100
            guard (0...1).contains(weight) else { return nil }
            let a = first.color, b = second.color
            func blend(_ x: Double, _ y: Double) -> Double { x*weight+y*(1-weight) }
            return worked(RGB(r: blend(a.r, b.r), g: blend(a.g, b.g), b: blend(a.b, b.b), a: blend(a.a, b.a)))
        }
        // "lighten tomato by 20%", "#ff6600 darker", "20% darker navy"
        var adjustment: (String, String, Double)?
        if let match = AddressCalculation.groups(#"^(lighten|darken|saturate|desaturate|brighten) (.+?)(?: by (\d{1,3}(?:\.\d+)?) ?%?)?$"#, in: text) {
            adjustment = (match[1], match[2], Double(match[3]) ?? 10)
        } else if let match = AddressCalculation.groups(#"^(.+?) (lighter|darker|brighter)(?: by (\d{1,3}(?:\.\d+)?) ?%?)?$"#, in: text) {
            adjustment = (match[2], match[1], Double(match[3]) ?? 10)
        } else if let match = AddressCalculation.groups(#"^(\d{1,3}(?:\.\d+)?) ?% (lighter|darker|brighter) (.+)$"#, in: text), let amount = Double(match[1]) {
            adjustment = (match[2], match[3], amount)
        }
        if let (verb, colorText, amount) = adjustment, let base = expression(colorText, target: "hex") {
            var (h, s, l) = hsl(base.color)
            switch verb {
            case "lighten", "lighter", "brighten", "brighter": l = min(1, l+amount/100)
            case "darken", "darker": l = max(0, l-amount/100)
            case "saturate": s = min(1, s+amount/100)
            default: s = max(0, s-amount/100)
            }
            var color = fromHSL(h, s, l); color.a = base.color.a
            return worked(color)
        }
        if let match = AddressCalculation.groups(#"^(?:invert(?:ed)?|inverse(?: of)?|negative(?: of)?|opposite of) (.+)$"#, in: text),
           let base = expression(match[1], target: "hex") {
            let c = base.color
            return worked(RGB(r: 1-c.r, g: 1-c.g, b: 1-c.b, a: c.a))
        }
        if let match = AddressCalculation.groups(#"^complement(?:ary)?(?: colou?r)?(?: of| for| to)? (.+)$|^(.+) complement(?:ary)?(?: colou?r)?$"#, in: text),
           let base = expression(match[1].isEmpty ? match[2] : match[1], target: "hex") {
            let (h, s, l) = hsl(base.color)
            var color = fromHSL((h+180).truncatingRemainder(dividingBy: 360), s, l); color.a = base.color.a
            return worked(color)
        }
        if let match = AddressCalculation.groups(#"^(?:grayscale|greyscale|desaturated?|gray|grey)(?: version)?(?: of)? (.+)$|^(.+?) (?:in )?(?:grayscale|greyscale)$"#, in: text),
           let base = expression(match[1].isEmpty ? match[2] : match[1], target: "hex") {
            // The grey as bright as the colour reads, so its contrast against anything stays the same.
            let grey = gamma(luminance(base.color))
            return worked(RGB(r: grey, g: grey, b: grey, a: base.color.a))
        }
        // "#ff6600 at 50% opacity", "red with alpha 0.3", "navy 20% transparent"
        if let match = AddressCalculation.groups(#"^(.+?) (?:at |with )?(\d{1,3}(?:\.\d+)?)% (opacity|opaque|alpha|transparency|transparent)$|^(.+?) (?:at |with )(?:opacity|alpha)(?: of)? (\d*\.\d+|[01]|\d{1,3}%)$"#, in: text) {
            let colorText = match[1].isEmpty ? match[4] : match[1]
            guard let base = expression(colorText, target: "hex") else { return nil }
            var alpha: Double
            if !match[2].isEmpty, let percent = Double(match[2]) {
                alpha = percent/100
                if match[3].hasPrefix("transparen") { alpha = 1-alpha }
            } else if match[5].hasSuffix("%"), let percent = Double(match[5].dropLast()) { alpha = percent/100 }
            else { alpha = Double(match[5]) ?? 1 }
            guard (0...1).contains(alpha) else { return nil }
            var color = base.color; color.a = alpha
            return worked(color)
        }
        return literal(text, target: target)
    }

    private static let channel = #"(\d{1,3}(?:\.\d+)?)"#
    private static let alpha = #"(\d*\.?\d+)"#
    private static let gap = #" ?(?:, ?| )"#

    static func literal(_ text: String, target: String?) -> Parsed? {
        // "#ff6600", "#f60", "#ff660080", "hex ff6600", "0xff6600", and "ff6600 to rgb"
        if let match = AddressCalculation.groups(#"^(?:hex(?:adecimal)? ?)?(#|0x)?([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})(?: colou?r)?$"#, in: text) {
            let marked = !match[1].isEmpty || text.hasPrefix("hex")
            let digits = match[2]
            if !marked {
                // Bare digits read as a colour only when a colour notation is asked for; "123 to hex" is a number.
                guard let target, digits.count == 3 || digits.count == 6,
                      !(digits.allSatisfy(\.isNumber) && target.hasPrefix("hex")) else { return nil }
            }
            if match[1] == "0x", target == nil { return nil }
            let full = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
            guard let value = UInt64(full, radix: 16) else { return nil }
            let hasAlpha = full.count == 8
            let rgb = hasAlpha ? value >> 8 : value
            return Parsed(color: RGB(r: Double(rgb >> 16 & 255)/255, g: Double(rgb >> 8 & 255)/255, b: Double(rgb & 255)/255,
                                     a: hasAlpha ? Double(value & 255)/255 : 1),
                          standsAlone: !match[1].isEmpty || text.hasPrefix("hex "), otherFormat: hasAlpha ? "rgba" : "rgb")
        }
        // "rgb(255, 102, 0)", "rgba(255 102 0 / 50%)", "rgb 255 102 0", "rgb(100%, 40%, 0%)"
        if let match = AddressCalculation.groups("^rgba? ?\\(? ?" + channel + "(%)?" + gap + channel + "(%)?" + gap + channel + "(%)?(?: ?(?:,|/) ?" + alpha + "(%)?)? ?\\)?$", in: text) {
            var values: [Double] = []
            for index in [1, 3, 5] {
                guard let value = Double(match[index]) else { return nil }
                let scaled = match[index+1].isEmpty ? value/255 : value/100
                guard scaled <= 1 else { return nil }
                values.append(scaled)
            }
            guard let a = alphaValue(match[7], match[8]) else { return nil }
            return Parsed(color: RGB(r: values[0], g: values[1], b: values[2], a: a), standsAlone: true, otherFormat: "hex")
        }
        // "hsl(24, 100%, 50%)", "hsl(24deg 100% 50% / 0.5)", "hsl 24 100 50", and hsv/hsb alike
        if let match = AddressCalculation.groups("^(hsla?|hsva?|hsba?) ?\\(? ?(-?\\d{1,4}(?:\\.\\d+)?)(deg|°|turn)?" + gap + channel + "%?" + gap + channel + "%?(?: ?(?:,|/) ?" + alpha + "(%)?)? ?\\)?$", in: text),
           var hue = Double(match[2]), let second = Double(match[4]), let third = Double(match[5]), second <= 100, third <= 100 {
            if match[3] == "turn" { hue *= 360 }
            hue = (hue.truncatingRemainder(dividingBy: 360)+360).truncatingRemainder(dividingBy: 360)
            guard let a = alphaValue(match[6], match[7]) else { return nil }
            var color = match[1].hasPrefix("hsl") ? fromHSL(hue, second/100, third/100) : fromHSV(hue, second/100, third/100)
            color.a = a
            return Parsed(color: color, standsAlone: true, otherFormat: "hex")
        }
        // "cmyk(0%, 60%, 100%, 0%)", "cmyk 0 0.6 1 0"
        if let match = AddressCalculation.groups("^cmyk ?\\(? ?" + channel + "%?" + gap + channel + "%?" + gap + channel + "%?" + gap + channel + "%? ?\\)?$", in: text) {
            let values = [1, 2, 3, 4].compactMap { Double(match[$0]) }
            let fractions = !text.contains("%") && values.allSatisfy { $0 <= 1 }
            let parts = values.map { fractions ? $0 : $0/100 }
            guard parts.count == 4, parts.allSatisfy({ (0...1).contains($0) }) else { return nil }
            let (c, m, y, k) = (parts[0], parts[1], parts[2], parts[3])
            return Parsed(color: RGB(r: (1-c)*(1-k), g: (1-m)*(1-k), b: (1-y)*(1-k)), standsAlone: true, otherFormat: "hex")
        }
        // "oklch(70% 0.19 41)", "oklab(0.7 0.15 0.11 / 50%)"
        if let match = AddressCalculation.groups(#"^(oklch|oklab) ?\( ?(\d*\.?\d+)(%)? (-?\d*\.?\d+)(%)? (-?\d*\.?\d+)(deg|%)?(?: ?/ ?(\d*\.?\d+)(%)?)? ?\)$"#, in: text),
           var lightness = Double(match[2]), var second = Double(match[4]), var third = Double(match[6]) {
            if !match[3].isEmpty { lightness /= 100 }
            if !match[5].isEmpty { second = second/100*0.4 }
            if match[7] == "%" { third = third/100*0.4 }
            guard (0...1).contains(lightness), let a = alphaValue(match[8], match[9]) else { return nil }
            let (labA, labB) = match[1] == "oklch" ? (second*cos(third * .pi/180), second*sin(third * .pi/180)) : (second, third)
            var color = fromOKLab(lightness, labA, labB); color.a = a
            return Parsed(color: color, standsAlone: true, otherFormat: "hex")
        }
        // "rebecca purple", "css dark slate gray", "navy blue colour"
        if target != nil, let match = AddressCalculation.groups(#"^(?:css )?(.+?)(?: colou?r)?$"#, in: text),
           let value = CSSNamedColors.value(for: match[1]) {
            return Parsed(color: RGB(r: Double(value >> 16 & 255)/255, g: Double(value >> 8 & 255)/255, b: Double(value & 255)/255),
                          standsAlone: false, otherFormat: "hex")
        }
        return nil
    }

    private static func alphaValue(_ digits: String, _ percent: String) -> Double? {
        guard !digits.isEmpty else { return 1 }
        guard let value = Double(digits) else { return nil }
        let alpha = percent.isEmpty ? value : value/100
        return (0...1).contains(alpha) ? alpha : nil
    }

    // MARK: - Contrast

    /// "contrast black on white", "#777 on #fff contrast ratio": the WCAG ratio and the level it meets.
    static func contrast(_ query: String) -> AddressCalculation? {
        let pair: String
        if let match = AddressCalculation.groups(#"^(?:wcag )?(?:colou?r )?contrast(?: ratio)?(?: (?:of|between|for|checker|check))? (.+)$"#, in: query) { pair = match[1] }
        else if let match = AddressCalculation.groups(#"^(.+) (?:wcag )?contrast(?: ratio)?$"#, in: query) { pair = match[1] }
        else { return nil }
        for separator in [" on ", " and ", " vs ", " versus ", " with ", " against ", " over ", " / ", " & "] {
            for (left, right) in splits(pair, around: separator) {
                guard let foreground = expression(left, target: "hex")?.color, let background = expression(right, target: "hex")?.color else { continue }
                // Translucent text shows the background through it.
                let shown = RGB(r: foreground.r*foreground.a+background.r*(1-foreground.a),
                                g: foreground.g*foreground.a+background.g*(1-foreground.a),
                                b: foreground.b*foreground.a+background.b*(1-foreground.a))
                let lighter = max(luminance(shown), luminance(background)), darker = min(luminance(shown), luminance(background))
                let ratio = (lighter+0.05)/(darker+0.05)
                // Rounded down, so 4.499 never reads as the 4.5 it falls short of.
                let shownRatio = (ratio*100).rounded(.down)/100
                let level = ratio >= 7 ? "AAA" : ratio >= 4.5 ? "AA" : ratio >= 3 ? "AA large text" : "Fails AA"
                return AddressCalculation("\(AddressCalculation.number(shownRatio, digits: 2)):1 · \(level)", color: swatch(foreground))
            }
        }
        return nil
    }

    static func luminance(_ color: RGB) -> Double {
        0.2126*linear(color.r)+0.7152*linear(color.g)+0.0722*linear(color.b)
    }

    // MARK: - Writing

    static func write(_ color: RGB, as format: String) -> String? {
        let r = byte(color.r), g = byte(color.g), b = byte(color.b)
        let translucent = color.a < 0.9995
        let alpha = AddressCalculation.number(color.a, digits: 2)
        switch format {
        case let hex where hex.hasPrefix("hex"):
            let withAlpha = translucent || hex.hasSuffix("8") || hex.hasSuffix("alpha")
            return String(format: "#%02X%02X%02X", r, g, b) + (withAlpha ? String(format: "%02X", byte(color.a)) : "")
        case "rgb", "rgba":
            return translucent || format == "rgba" ? "rgba(\(r), \(g), \(b), \(alpha))" : "rgb(\(r), \(g), \(b))"
        case "hsl", "hsla":
            let (h, s, l) = hsl(color)
            let body = "\(Int(h.rounded())%360), \(Int((s*100).rounded()))%, \(Int((l*100).rounded()))%"
            return translucent || format == "hsla" ? "hsla(\(body), \(alpha))" : "hsl(\(body))"
        case "hsv", "hsva", "hsb":
            let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b)
            let (h, _, _) = hsl(color)
            let s = high == 0 ? 0 : (high-low)/high
            let name = format == "hsb" ? "hsb" : "hsv"
            return "\(name)(\(Int(h.rounded())%360), \(Int((s*100).rounded()))%, \(Int((high*100).rounded()))%)"
        case "cmyk":
            let k = 1-max(color.r, color.g, color.b)
            let part = { (channel: Double) in k >= 1 ? 0 : (1-channel-k)/(1-k) }
            let percents = [part(color.r), part(color.g), part(color.b), k].map { "\(Int(($0*100).rounded()))%" }
            return "cmyk(\(percents.joined(separator: ", ")))"
        case "oklch", "oklab":
            let (l, a, bb) = okLab(color)
            let suffix = translucent ? " / \(alpha)" : ""
            let lightness = AddressCalculation.number(l*100, digits: 1) + "%"
            if format == "oklab" {
                return "oklab(\(lightness) \(AddressCalculation.number(a, digits: 3)) \(AddressCalculation.number(bb, digits: 3))\(suffix))"
            }
            let chroma = (a*a+bb*bb).squareRoot()
            let hue = chroma < 0.0005 ? 0 : (atan2(bb, a)*180 / .pi+360).truncatingRemainder(dividingBy: 360)
            return "oklch(\(lightness) \(AddressCalculation.number(chroma, digits: 3)) \(AddressCalculation.number(hue, digits: 1))\(suffix))"
        default:
            // A CSS name: the colour's own, or the nearest one's.
            let exact = CSSNamedColors.all.first { $0.value == (r << 16 | g << 8 | b) }
            if let exact { return exact.name }
            let (l, a, bb) = okLab(color)
            let nearest = CSSNamedColors.all.min { first, second in
                func distance(_ value: Int) -> Double {
                    let named = okLab(RGB(r: Double(value >> 16 & 255)/255, g: Double(value >> 8 & 255)/255, b: Double(value & 255)/255))
                    return pow(named.0-l, 2)+pow(named.1-a, 2)+pow(named.2-bb, 2)
                }
                return distance(first.value) < distance(second.value)
            }
            return nearest.map { "≈ " + $0.name }
        }
    }

    static func swatch(_ color: RGB) -> AddressCalculation.Color {
        AddressCalculation.Color(red: byte(color.r), green: byte(color.g), blue: byte(color.b), alpha: color.a)
    }

    private static func byte(_ value: Double) -> Int { Int((min(1, max(0, value))*255).rounded()) }

    // MARK: - Colour spaces

    static func hsl(_ color: RGB) -> (Double, Double, Double) {
        let high = max(color.r, color.g, color.b), low = min(color.r, color.g, color.b), delta = high-low
        let lightness = (high+low)/2
        let saturation = delta == 0 ? 0 : delta/(1-abs(2*lightness-1))
        var hue: Double
        if delta == 0 { hue = 0 }
        else if high == color.r { hue = ((color.g-color.b)/delta).truncatingRemainder(dividingBy: 6) }
        else if high == color.g { hue = (color.b-color.r)/delta+2 }
        else { hue = (color.r-color.g)/delta+4 }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, min(1, saturation), lightness)
    }

    static func fromHSL(_ hue: Double, _ saturation: Double, _ lightness: Double) -> RGB {
        let chroma = (1-abs(2*lightness-1))*saturation
        let h = hue/60
        let x = chroma*(1-abs(h.truncatingRemainder(dividingBy: 2)-1))
        let (r, g, b) = sector(h, chroma, x)
        let offset = lightness-chroma/2
        return RGB(r: r+offset, g: g+offset, b: b+offset)
    }

    static func fromHSV(_ hue: Double, _ saturation: Double, _ value: Double) -> RGB {
        let chroma = value*saturation
        let h = hue/60
        let x = chroma*(1-abs(h.truncatingRemainder(dividingBy: 2)-1))
        let (r, g, b) = sector(h, chroma, x)
        let offset = value-chroma
        return RGB(r: r+offset, g: g+offset, b: b+offset)
    }

    private static func sector(_ h: Double, _ chroma: Double, _ x: Double) -> (Double, Double, Double) {
        switch Int(h) % 6 {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel/12.92 : pow((channel+0.055)/1.055, 2.4)
    }

    private static func gamma(_ channel: Double) -> Double {
        let value = channel <= 0.0031308 ? 12.92*channel : 1.055*pow(channel, 1/2.4)-0.055
        return min(1, max(0, value))
    }

    /// Björn Ottosson's OKLab, from linear sRGB.
    static func okLab(_ color: RGB) -> (Double, Double, Double) {
        let r = linear(color.r), g = linear(color.g), b = linear(color.b)
        let l = cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b)
        let m = cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b)
        let s = cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
        return (0.2104542553*l+0.7936177850*m-0.0040720468*s,
                1.9779984951*l-2.4285922050*m+0.4505937099*s,
                0.0259040371*l+0.7827717662*m-0.8086757660*s)
    }

    static func fromOKLab(_ lightness: Double, _ a: Double, _ b: Double) -> RGB {
        let l = pow(lightness+0.3963377774*a+0.2158037573*b, 3)
        let m = pow(lightness-0.1055613458*a-0.0638541728*b, 3)
        let s = pow(lightness-0.0894841775*a-1.2914855480*b, 3)
        return RGB(r: gamma(4.0767416621*l-3.3077115913*m+0.2309699292*s),
                   g: gamma(-1.2684380046*l+2.6097574011*m-0.3413193965*s),
                   b: gamma(-0.0041960863*l-0.7034186147*m+1.7076147010*s))
    }
}

extension AddressCalculation.Color {
    /// The ring around this colour's swatch on `background`: the colour, faint, as a ring usually
    /// is. A colour that would hardly stand out there, as near-white does on white or near-black
    /// in the dark, gets a ring of a shade of itself further from the background instead, darker
    /// on a light one and lighter on a dark one, to part it from the background.
    public func swatchRing(on background: Self) -> Self {
        typealias RGB = ColorCalculation.RGB
        func rgb(_ color: Self) -> RGB { RGB(r: Double(color.red)/255, g: Double(color.green)/255, b: Double(color.blue)/255) }
        // As the screen blends them: in sRGB's own values.
        func mix(_ top: RGB, _ amount: Double, over bottom: RGB) -> RGB {
            RGB(r: top.r*amount+bottom.r*(1-amount), g: top.g*amount+bottom.g*(1-amount), b: top.b*amount+bottom.b*(1-amount))
        }
        let back = rgb(background), faint = mix(rgb(self), 0.18, over: back)
        let backLightness = ColorCalculation.okLab(back).0
        let (lightness, a, b) = ColorCalculation.okLab(mix(rgb(self), min(1, max(0, alpha)), over: back))
        // How far it stands out: by lightness mostly, and by colourfulness some.
        let apart = abs(lightness-backLightness) + (a*a+b*b).squareRoot()/2
        let outline = min(1, max(0, (0.16-apart)/0.05))
        var ring = faint
        if outline > 0 {
            // Past the background as well as the colour, so it shows against both.
            let shade = ColorCalculation.fromOKLab(backLightness < 0.5 ? min(1, max(lightness, backLightness)+0.14)
                                                   : max(0, min(lightness, backLightness)-0.14), a, b)
            ring = mix(shade, outline, over: faint)
        }
        return Self(red: Int((ring.r*255).rounded()), green: Int((ring.g*255).rounded()), blue: Int((ring.b*255).rounded()))
    }
}
