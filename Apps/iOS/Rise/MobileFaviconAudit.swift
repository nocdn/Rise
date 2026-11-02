#if DEBUG
import UIKit
import WebKit

private final class FaviconProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.responses[request.url!.absoluteString]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: data == nil ? 404 : 200,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class MobileFaviconAudit {
    static let argument = "-RiseMobileFaviconAudit"
    struct Failure: Error { let check: String }
    private(set) var checks: [String: Bool] = [:]
    private func require(_ value: Bool, _ name: String) throws {
        checks[name] = value
        if !value { throw Failure(check: name) }
    }
    private func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(check: "Missing \(T.self)") }
        return value
    }
    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
    private func brightness(_ image: UIImage) throws -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let cgImage = try unwrap(image.cgImage)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try unwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CGFloat(pixel[0])/255
    }
    private func assertVariants(_ image: UIImage?, name: String) throws {
        let image = try unwrap(image)
        try require(brightness(MobileFavicon.variant(image, style: .light)) < 0.1, name+"-light")
        try require(brightness(MobileFavicon.variant(image, style: .dark)) > 0.9, name+"-dark")
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func waitForLoad(_ cache: MobileSuggestionFavicons, url: URL) async throws {
        var loaded = false
        cache.onLoad = { loaded = true }
        _ = cache.image(for: url)
        for _ in 0..<300 {
            if loaded, let image = cache.image(for: url, fetch: false),
               try brightness(MobileFavicon.variant(image, style: .dark)) > 0.9 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(check: "Appearance variants did not load")
    }

    func testLegacyGitHubCacheUpgradesAndPersistsBothAppearancesWithoutNetwork() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("icons.json")
        let light = try unwrap(image(.black).pngData()), dark = try unwrap(image(.white).pngData())
        let page = URL(string: "https://github.com/owner/repo")!
        try JSONEncoder().encode(["https://github.com/": light]).write(to: file)
        FaviconProtocol.responses = [
            "https://github.githubassets.com/favicons/favicon.png": light,
            "https://github.githubassets.com/favicons/favicon-dark.png": dark
        ]
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = MobileSuggestionFavicons(storageURL: file, session: session)
        try require(cache.image(for: page, fetch: false) != nil, "legacy-cache-remains-visible")
        try await waitForLoad(cache, url: page)
        try assertVariants(cache.image(for: page, fetch: false), name: "downloaded-variants")
        cache.remember(image(.black), for: page)
        cache.save(); cache.flush()
        let restored = MobileSuggestionFavicons(storageURL: file, allowsNetwork: false)
        try assertVariants(restored.image(for: page, fetch: false), name: "persisted-variants-survive-single-image-tab")
    }

    func testDeclaredDarkIconIsDiscoveredEvenWhenRootFaviconExists() async throws {
        let page = URL(string: "https://icons.example.org/page")!
        FaviconProtocol.responses = [
            "https://icons.example.org/favicon.ico": try unwrap(image(.black).pngData()),
            "https://icons.example.org/": Data("""
                <link rel="icon" href="/light.png" media="(prefers-color-scheme: light)">
                <link rel="icon" href="/dark.png" media="(prefers-color-scheme: dark)">
                """.utf8),
            "https://icons.example.org/light.png": try unwrap(image(.black).pngData()),
            "https://icons.example.org/dark.png": try unwrap(image(.white).pngData())
        ]
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = MobileSuggestionFavicons(storageURL: nil, session: session)
        try await waitForLoad(cache, url: page)
        try assertVariants(cache.image(for: page, fetch: false), name: "declared-variants")
    }

    func testVisibleSuggestionHistoryAndTabIconsFollowTheirOwnTraits() async throws {
        let scene = try unwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let adaptive = MobileFavicon.adaptive(light: image(.black), dark: image(.white))
        let row = AddressSuggestionRow(frame: CGRect(x: 10, y: 100, width: 320, height: 56))
        row.show(AddressCandidate(title: "GitHub", url: URL(string: "https://github.com")), image: adaptive)
        let tab = FaviconView(frame: CGRect(x: 10, y: 170, width: 20, height: 20)); tab.image = adaptive
        host.view.addSubview(row); host.view.addSubview(tab)
        for style in [UIUserInterfaceStyle.light, .dark, .light] {
            host.overrideUserInterfaceStyle = style
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            for view in [row.icon as UIView, tab] {
                let rendered = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                    view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                }
                try require(style == .dark ? brightness(rendered) > 0.8 : brightness(rendered) < 0.1,
                            "visible-\(view === tab ? "tab" : "suggestion")-\(style.rawValue)-\(checks.count)")
            }
        }
        // Private panels can be dark while the rest of the browser stays light.
        row.overrideUserInterfaceStyle = .dark
        try await Task.sleep(for: .milliseconds(50))
        let rendered = UIGraphicsImageRenderer(bounds: row.icon.bounds).image { _ in
            row.icon.drawHierarchy(in: row.icon.bounds, afterScreenUpdates: true)
        }
        try require(brightness(rendered) > 0.8, "private-panel-uses-its-own-dark-traits")
    }

    func testPageCandidatesSelectBothSchemesIndependentlyOfWebViewAppearance() async throws {
        let page = WKWebView()
        page.overrideUserInterfaceStyle = .light
        page.loadHTMLString("""
            <link rel="icon" href="/fallback.png">
            <link rel="icon" href="/light.png" media="(prefers-color-scheme: light)">
            <link rel="icon" href="/dark.png" media="(prefers-color-scheme: dark)">
            """, baseURL: URL(string: "https://icons.example.org"))
        for _ in 0..<300 {
            if !page.isLoading, page.url != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let candidates = await BrowserTab.faviconCandidates(for: page)
        try require(candidates.light.first?.lastPathComponent == "light.png", "page-selects-light-icon-first")
        try require(candidates.dark.first?.lastPathComponent == "dark.png", "page-selects-dark-icon-first")
        try require(!candidates.light.contains { $0.lastPathComponent == "dark.png" }, "light-candidates-exclude-dark-media")
        try require(!candidates.dark.contains { $0.lastPathComponent == "light.png" }, "dark-candidates-exclude-light-media")
    }

    func testTabPreviewCacheRetainsBothAppearances() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = TabPreviewCache(folder: folder), id = UUID(), url = URL(string: "https://github.com")!
        cache.save(id: id, url: url, picture: nil,
                   favicon: MobileFavicon.adaptive(light: image(.black), dark: image(.white)))
        cache.flush()
        let entry = await cache.load(id: id, url: url)
        try assertVariants(entry?.faviconImage, name: "tab-preview-cache")
    }

    func testSitesWithoutDarkArtworkKeepTheirOriginalColors() throws {
        let original = image(.systemOrange)
        let adaptive = MobileFavicon.adaptive(light: original, dark: nil)
        try require(adaptive === original, "unvaried-icons-keep-their-original-image")
        let saved = try unwrap(MobileFavicon.Saved(adaptive))
        try require(saved.dark == nil, "unvaried-icons-do-not-duplicate-persisted-bytes")
        try require(MobileFavicon.variant(adaptive, style: .light).pngData() == MobileFavicon.variant(adaptive, style: .dark).pngData(),
                    "unvaried-icons-keep-their-colors")
    }

    func testLargeDeclaredIconUpgradesSuggestionsAndSurvivesSmallTabIcons() async throws {
        func png(_ size: CGFloat) throws -> Data {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            return try unwrap(UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
                UIColor.systemRed.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }.pngData())
        }
        let root = URL(string: "https://quality.example.org/")!, small = try png(16), large = try png(144)
        let html = "<link rel='shortcut icon' href='/favicon.ico'><link rel='icon' href='/large.png' sizes='144x144'><link rel='icon' href='/32.png' sizes='32x32'>"
        FaviconProtocol.responses = [root.absoluteString: Data(html.utf8),
            root.appendingPathComponent("favicon.ico").absoluteString: small,
            root.appendingPathComponent("large.png").absoluteString: large]
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("icons.json")
        let session = session(); defer { session.invalidateAndCancel() }
        let cache = MobileSuggestionFavicons(storageURL: file, session: session)
        cache.remember(MobileFavicon.decode(small), for: root)
        _ = cache.image(for: root)
        for _ in 0..<300 {
            if cache.image(for: root, fetch: false)?.cgImage?.width == 64 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(cache.image(for: root, fetch: false)?.cgImage?.width == 64, "suggestions-upgrade-to-large-declared-icon")
        cache.remember(MobileFavicon.decode(small), for: root)
        try require(cache.image(for: root, fetch: false)?.cgImage?.width == 64, "small-tab-icon-cannot-downgrade-suggestions")
        cache.save(); cache.flush()
        let restored = MobileSuggestionFavicons(storageURL: file, allowsNetwork: false)
        try require(restored.image(for: root, fetch: false)?.cgImage?.width == 64, "sharp-icon-persists-offline")
        let page = WKWebView(); page.loadHTMLString(html, baseURL: root)
        for _ in 0..<300 {
            if !page.isLoading, page.url != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let candidates = await BrowserTab.faviconCandidates(for: page)
        try require(candidates.light.first?.lastPathComponent == "large.png", "page-selects-large-icon-before-ico")
        try require(candidates.dark.first?.lastPathComponent == "large.png", "page-selects-large-icon-in-dark-mode-too")
    }

    static func exercise() async throws -> [String: Bool] {
        let audit = MobileFaviconAudit()
        try await audit.testLegacyGitHubCacheUpgradesAndPersistsBothAppearancesWithoutNetwork()
        try await audit.testDeclaredDarkIconIsDiscoveredEvenWhenRootFaviconExists()
        try await audit.testVisibleSuggestionHistoryAndTabIconsFollowTheirOwnTraits()
        try await audit.testPageCandidatesSelectBothSchemesIndependentlyOfWebViewAppearance()
        try await audit.testTabPreviewCacheRetainsBothAppearances()
        try audit.testSitesWithoutDarkArtworkKeepTheirOriginalColors()
        try await audit.testLargeDeclaredIconUpgradesSuggestionsAndSurvivesSmallTabIcons()
        return audit.checks
    }
    private static func captureGitHub(in browser: BrowserViewController, folder: URL) async throws {
        let url = URL(string: "https://github.com/")!
        let icons = browser.addressSuggestions.icons
        _ = icons.image(for: url)
        var icon: UIImage?
        for _ in 0..<500 {
            if let loaded = icons.image(for: url, fetch: false), MobileFavicon.Saved(loaded)?.dark != nil {
                icon = loaded; break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard icon != nil else { throw Failure(check: "GitHub's published appearance icons did not load") }
        browser.addressSuggestions.history.record(url, title: "GitHub")
        browser.openPanel()
        let panel = browser.bottomBar.search
        panel.allowsRemoteSuggestions = false
        panel.field.text = "github.com"; panel.field.sendActions(for: .editingChanged)
        for style in [UIUserInterfaceStyle.light, .dark] {
            browser.overrideUserInterfaceStyle = style
            browser.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in
                browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: folder.appendingPathComponent(style == .dark ? "github-dark.png" : "github-light.png"))
        }
    }

    static func run(in browser: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("MobileFaviconAudit")
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let checks = try await exercise()
                try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("checks.json"))
                try await captureGitHub(in: browser, folder: folder)
                try "Passed \(checks.count) native checks\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
