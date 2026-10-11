import UIKit
import WebKit

/// Finds the colour along a row of a page, usually an edge, so a strip beside it reads as part of
/// the page. What's painted there wins when one colour fills most of the row, as on a header bar
/// or a plain background. Otherwise, as under text or an image, the site's theme colour stands in,
/// then the background WebKit shows past the page's edges.
@MainActor enum PageEdgeColor {
    /// Samples across the edge, and the share of them that must agree.
    static let samples = 48
    static let agreement = 0.6

    /// Samples the one-point row at `y` in the web view's coordinates.
    static func sample(_ webView: WKWebView, row y: CGFloat = 0, completion: @escaping @MainActor (UIColor?) -> Void) {
        let fallback = webView.themeColor ?? webView.underPageBackgroundColor
        // A page that hasn't painted yet shows what's behind it, which isn't its colour.
        guard !PagePaintWatcher.shared.isTransparent(webView) else { completion(nil); return }
        guard webView.bounds.width > 0, webView.window != nil else { completion(fallback); return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: min(max(0, y), webView.bounds.height-1), width: webView.bounds.width, height: 1)
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

    /// Whether white contrasts more with the colour than black does, by WCAG's relative
    /// luminance: below about 0.18, white wins. HN's orange takes black, as in Safari and Arc.
    static func isDark(_ color: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        let linear = { (c: CGFloat) in c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4) }
        let luminance = 0.2126*linear(r)+0.7152*linear(g)+0.0722*linear(b)
        return 1.05/(luminance+0.05) > (luminance+0.05)/0.05
    }

    /// Whether two colours look the same, whatever their colour spaces, as a page's white
    /// sampled through a snapshot comes back a hair off white.
    static func isClose(_ a: UIColor, _ b: UIColor) -> Bool {
        func components(_ color: UIColor) -> [CGFloat]? {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            return color.getRed(&r, green: &g, blue: &b, alpha: &alpha) ? [r, g, b, alpha] : nil
        }
        guard let first = components(a), let second = components(b) else { return a == b }
        return zip(first, second).allSatisfy { abs($0-$1) < 2.0/255 }
    }
}

/// Keeps a colour in step with a page's top or bottom edge as it loads, paints and scrolls.
@MainActor final class PageEdgeTint {
    enum Edge { case top, bottom }
    let edge: Edge
    /// The row sampled, in the page's coordinates: its first visible row by default.
    var row: @MainActor () -> CGFloat = { 0 }
    private(set) var color: UIColor?
    /// Whether pulling the page down past its top shows this colour in the gap, so a strip
    /// above the page just grows instead of meeting WebKit's background.
    var fillsOverscroll = false
    /// Set while the gap above the page is held open, as for a reload's spinner: it's coloured
    /// like a pull, and the page's top edge isn't sampled until it closes.
    var gapHeld = false { didSet { if gapHeld != oldValue { scrolled() } } }
    private var filling = false
    /// While the page is pulled past this edge, the edge is WebKit's background, not the page.
    private var gapShowing: Bool {
        guard let scrollView = webView?.scrollView else { return false }
        switch edge {
        case .top: return gapHeld || scrollView.topOverscroll > 0
        case .bottom: return scrollView.bottomOverscroll > 0
        }
    }
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    /// A page that was see-through until it painted is sampled as it first paints.
    private var paintObserver: NSObjectProtocol?
    private var sampling = false, sampleAgain = false
    private let onChange: @MainActor (UIColor) -> Void

    init(edge: Edge = .top, onChange: @escaping @MainActor (UIColor) -> Void) {
        self.edge = edge
        self.onChange = onChange
    }

    /// Follows a page, starting from `color` when its top edge is already known.
    func track(_ webView: WKWebView, from color: UIColor? = nil) {
        if filling { self.webView?.underPageBackgroundColor = nil; filling = false }
        self.webView = webView
        if let color { self.color = color }
        // Whatever can change the page's top edge: loading, scrolling, and the page's own colours.
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.sample()
                    // Late paints, such as web fonts and images, can still change the top edge.
                    guard webView.estimatedProgress >= 1 else { return }
                    for delay in [0.3, 1.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now()+delay) { [weak self] in self?.sample() }
                    }
                }
            },
            webView.observe(\.themeColor) { [weak self] _, _ in MainActor.assumeIsolated { self?.sample() } },
            webView.observe(\.underPageBackgroundColor) { [weak self] _, _ in MainActor.assumeIsolated { self?.sample() } },
            webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in MainActor.assumeIsolated { self?.scrolled() } },
        ]
        if let paintObserver { NotificationCenter.default.removeObserver(paintObserver) }
        paintObserver = NotificationCenter.default.addObserver(forName: PagePaintWatcher.didPaint, object: webView,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    private func scrolled() {
        guard let webView else { return }
        let overscrolled = gapShowing
        if fillsOverscroll, overscrolled != filling, !overscrolled || color != nil {
            filling = overscrolled
            // nil gives WebKit's own colour back, which the bottom edge keeps showing throughout.
            webView.underPageBackgroundColor = overscrolled ? color : nil
        }
        sample()
    }

    /// Samples again once the current sample finishes, so bursts of changes cost one snapshot each.
    /// While the page is pulled past its top, its edge is the gap above it, so nothing is sampled.
    func sample() {
        guard let webView, !gapShowing else { return }
        guard !sampling else { sampleAgain = true; return }
        sampling = true
        PageEdgeColor.sample(webView, row: row()) { [weak self, weak webView] color in
            guard let self else { return }
            sampling = false
            // A sample of a page no longer tracked, or taken as it was pulled past the edge, is stale.
            if let color, let webView, webView === self.webView, !gapShowing,
               self.color.map({ !PageEdgeColor.isClose($0, color) }) ?? true {
                self.color = color
                onChange(color)
            }
            if sampleAgain { sampleAgain = false; sample() }
        }
    }
}
