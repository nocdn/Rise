import UIKit
import ImageIO
import WebKit

/// Keep the site's own artwork for each appearance. UIImageView resolves the asset
/// against its own traits, including private panels and changes while already visible.
enum MobileFavicon {
    struct Saved: Codable {
        let light: Data
        let dark: Data?

        init?(_ image: UIImage) {
            guard let light = MobileFavicon.variant(image, style: .light).pngData(), light.count <= 100_000 else { return nil }
            let dark = MobileFavicon.variant(image, style: .dark).pngData()
            self.light = light
            self.dark = dark != light && (dark?.count ?? 0) <= 100_000 ? dark : nil
        }

        var image: UIImage? {
            guard let light = MobileFavicon.decode(light) else { return nil }
            return MobileFavicon.adaptive(light: light, dark: dark.flatMap(MobileFavicon.decode))
        }
    }

    static func adaptive(light: UIImage, dark: UIImage?) -> UIImage {
        guard let dark else { return light }
        let asset = UIImageAsset()
        for (style, image) in [(UIUserInterfaceStyle.light, light), (.dark, dark)] {
            let image = variant(image, style: style)
            asset.register(image, with: UITraitCollection {
                $0.userInterfaceStyle = style; $0.displayScale = image.scale
            })
        }
        return asset.image(with: UITraitCollection(userInterfaceStyle: .light))
    }

    static func variant(_ image: UIImage, style: UIUserInterfaceStyle) -> UIImage {
        image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: style)) ?? image
    }

    static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 1_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // An ICO can start with a 16-pixel image; preserve the sharper size for Retina displays.
        let index = (0..<CGImageSourceGetCount(source)).max { left, right in
            let a = CGImageSourceCopyPropertiesAtIndex(source, left, nil) as? [CFString: Any]
            let b = CGImageSourceCopyPropertiesAtIndex(source, right, nil) as? [CFString: Any]
            return (a?[kCGImagePropertyPixelWidth] as? Int ?? 0) < (b?[kCGImagePropertyPixelWidth] as? Int ?? 0)
        } ?? 0
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// WebKit supplies iOS's public SVG renderer. Artwork is loaded as an image, so SVG
/// scripts cannot run; the disposable, cookieless document cannot contact a site.
@MainActor private final class MobileSVGIcon: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var ready: CheckedContinuation<Bool, Never>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    private func finish(_ loaded: Bool) {
        let pending = ready; ready = nil; pending?.resume(returning: loaded)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }

    func render(_ data: Data) async -> UIImage? {
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)); self?.finish(false) } catch { }
        }
        defer { deadline.cancel(); web.stopLoading(); web.navigationDelegate = nil }
        let loaded = await withCheckedContinuation { continuation in
            ready = continuation
            web.loadHTMLString("""
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
                <body></body>
                """, baseURL: nil)
        }
        guard loaded, !Task.isCancelled else { return nil }
        let script = """
            const draw = async dark => {
              document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
              const image = new Image();
              image.style.colorScheme = dark ? 'dark' : 'light';
              document.body.append(image);
              try {
                await new Promise((resolve, reject) => {
                  const timer = setTimeout(() => reject(new Error('Icon timeout')), 2000);
                  image.onload = () => { clearTimeout(timer); resolve(); };
                  image.onerror = () => { clearTimeout(timer); reject(new Error('Invalid icon')); };
                  image.src = 'data:image/svg+xml;base64,' + encoded + (dark ? '#dark' : '#light');
                });
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = 64;
                const context = canvas.getContext('2d');
                const scale = 64 / Math.max(image.naturalWidth, image.naturalHeight);
                const width = image.naturalWidth * scale, height = image.naturalHeight * scale;
                context.drawImage(image, (64-width)/2, (64-height)/2, width, height);
                return canvas.toDataURL('image/png').split(',')[1];
              } finally { image.remove(); }
            };
            return await draw(dark);
            """
        func variant(dark: Bool) async -> UIImage? {
            web.overrideUserInterfaceStyle = dark ? .dark : .light
            guard let png = await MobileFavicon.evaluate(script, arguments: ["encoded": (FaviconSVG.resolve(data, dark: dark) ?? data).base64EncodedString(), "dark": dark], in: web) as? String,
                  !Task.isCancelled, let bytes = Data(base64Encoded: png) else { return nil }
            return MobileFavicon.decode(bytes)
        }
        guard let light = await variant(dark: false) else { return nil }
        let dark = await variant(dark: true)
        return MobileFavicon.adaptive(light: light, dark: dark)
    }
}

extension MobileFavicon {
    /// Keep discovery and fetches in an isolated world, with an awaited result.
    @MainActor static func evaluate(_ script: String, arguments: [String: Any] = [:], in web: WKWebView) async -> Any? {
        try? await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    @MainActor static func artwork(_ data: Data) async -> UIImage? {
        guard data.count <= 1_000_000 else { return nil }
        if String(data: data, encoding: .utf8)?.lowercased().contains("<svg") == true {
            return await MobileSVGIcon().render(data)
        }
        return decode(data)
    }
}
