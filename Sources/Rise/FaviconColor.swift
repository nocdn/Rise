import AppKit

/// A favicon's main color: the hue most of its colorful pixels share, averaged.
enum FaviconColor {
    static func dominant(_ image: NSImage) -> NSColor? {
        let side = 24, bins = 24
        var pixels = [UInt8](repeating: 0, count: side*side*4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side*4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var weight = [CGFloat](repeating: 0, count: bins), sums = [(CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0), count: bins)
        var opaque: CGFloat = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[i+3])/255
            guard alpha > 0.5 else { continue }
            opaque += 1
            let r = CGFloat(pixels[i])/255/alpha, g = CGFloat(pixels[i+1])/255/alpha, b = CGFloat(pixels[i+2])/255/alpha
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high-low)/high : 0
            // Grays, black and white say nothing about the brand.
            guard saturation > 0.3, high > 0.25 else { continue }
            var hue: CGFloat
            if high == r { hue = (g-b)/(high-low) } else if high == g { hue = 2+(b-r)/(high-low) } else { hue = 4+(r-g)/(high-low) }
            hue = (hue/6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
            let bin = min(bins-1, Int(hue*CGFloat(bins))), w = saturation*alpha
            weight[bin] += w; sums[bin].0 += r*w; sums[bin].1 += g*w; sums[bin].2 += b*w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), opaque > 0,
              weight[best] > opaque*0.04 else { return nil }
        let w = weight[best]
        return NSColor(srgbRed: sums[best].0/w, green: sums[best].1/w, blue: sums[best].2/w, alpha: 1)
    }

    /// Keeps a brand color legible as text: very light ones darken on a light background,
    /// very dark ones lighten on a dark one.
    static func readable(_ color: NSColor, theme: RiseTheme) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4) }
        let luminance = 0.2126*linear(rgb.redComponent)+0.7152*linear(rgb.greenComponent)+0.0722*linear(rgb.blueComponent)
        if theme == .dark, luminance < 0.08 { return rgb.blended(withFraction: 0.45, of: .white) ?? rgb }
        if theme != .dark, luminance > 0.55 { return rgb.blended(withFraction: 0.3, of: .black) ?? rgb }
        return rgb
    }
}
