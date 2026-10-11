import UIKit
import WebKit

/// Finds the colour along a page's top edge, so a strip above it reads as part of the page.
/// What's painted there wins when one colour fills most of the edge, as on a header bar or a
/// plain background. Otherwise, as under text or an image, the site's theme colour stands in,
/// then the background WebKit shows past the page's edges.
@MainActor enum PageTopColor {
    /// Samples across the edge, and the share of them that must agree.
    static let samples = 48
    static let agreement = 0.6

    static func sample(_ webView: WKWebView, completion: @escaping @MainActor (UIColor?) -> Void) {
        let fallback = webView.themeColor ?? webView.underPageBackgroundColor
        guard webView.bounds.width > 0, webView.window != nil else { completion(fallback); return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: 1)
        configuration.snapshotWidth = NSNumber(value: samples)
        // Waits for WebKit's next paint, so a page that just loaded or scrolled is what's sampled.
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image?.cgImage.flatMap(dominantColor) ?? fallback)
        }
    }

    /// The average of the largest group of near-identical pixels in the image's top row,
    /// if that group is large enough.
    static func dominantColor(of image: CGImage) -> UIColor? {
        let width = image.width
        guard width > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width*4)
        guard let context = CGContext(data: &pixels, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: width*4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draws the top row into the one-pixel-high context.
        context.draw(image, in: CGRect(x: 0, y: 1-image.height, width: width, height: image.height))
        var groups: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for x in 0..<width {
            let r = Int(pixels[x*4]), g = Int(pixels[x*4+1]), b = Int(pixels[x*4+2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | b >> 3
            let group = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (group.count+1, group.r+r, group.g+g, group.b+b)
        }
        guard let top = groups.values.max(by: { $0.count < $1.count }),
              Double(top.count) >= Double(width)*agreement else { return nil }
        let n = CGFloat(top.count)*255
        return UIColor(red: CGFloat(top.r)/n, green: CGFloat(top.g)/n, blue: CGFloat(top.b)/n, alpha: 1)
    }

    static func isDark(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return 0.2126*r+0.7152*g+0.0722*b < 0.5
    }
}
