#if DEBUG
import UIKit
import WebKit

/// Exercises real document commits, the address controls, and the shared toolbar animation.
@MainActor enum PageConnectionAudit {
    static let argument = "-RisePageConnectionAudit"
    struct Failure: Error { let name: String }

    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PageConnectionAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    /// The shackle's centre is left of the body on an actually left-opening lock.
    /// Inspect pixels, because a symbol's orientation metadata can be ignored by UIKit.
    private static func opensLeft(_ image: UIImage?) -> Bool {
        guard let image, let cg = image.cgImage else { return false }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width*height*4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drew else { return false }
        func centre(_ rows: Range<Int>) -> Double {
            var total = 0.0, weight = 0.0
            for y in rows { for x in 0..<width {
                let alpha = Double(pixels[(y*width+x)*4+3])
                total += Double(x)*alpha; weight += alpha
            } }
            return total/max(1, weight)
        }
        return centre(0..<height/3) < centre((height*2/3)..<height)
    }
    static func exercise(in window: UIWindow, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ passed: Bool) throws {
            checks[name] = passed
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !passed { throw Failure(name: name) }
        }
        func wait(_ name: String, _ ready: () -> Bool) async throws {
            for _ in 0..<250 {
                if ready() { try check(name, true); return }
                try await Task.sleep(for: .milliseconds(40))
            }
            try check(name, false)
        }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let previous = window.rootViewController
        defer { window.rootViewController = previous }
        let browser = BrowserViewController(startURL: nil, websiteDataStore: .nonPersistent())
        window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        let address = browser.bottomBar.menu.address
        address.show(URL(string: "https://www.example.com"), canGoBack: false, canGoForward: false)
        try check("https-shows-green-closed-lock", !address.lock.isHidden && address.lock.tintColor == .systemGreen && address.lock.image?.imageOrientation == .up)
        try check("https-is-accessibly-secure", address.host.accessibilityLabel == "Secure, example.com")
        address.show(URL(string: "HTTP://www.example.com"), canGoBack: false, canGoForward: false)
        address.bounds = CGRect(x: 0, y: 0, width: 350, height: 48); address.layoutIfNeeded()
        try check("http-shows-red-open-left-lock", !address.lock.isHidden && address.lock.tintColor == .systemRed && opensLeft(address.lock.image))
        try check("lock-is-to-the-left-of-the-host", address.lock.frame.maxX < address.host.frame.minX)
        try check("http-is-accessibly-not-secure", address.host.accessibilityLabel == "Not secure, example.com")
        for url in [nil, URL(string: "about:blank"), URL(string: "file:///test.html")] {
            address.show(url, canGoBack: false, canGoForward: false)
            try check("non-web-address-hides-lock-\(checks.count)", address.lock.isHidden)
        }
        let page = browser.webView
        let html = "<html lang='en'><body><h1>HTTP article</h1><p>This is an ordinary English page loaded over HTTP.</p></body></html>"
        page.loadHTMLString(html, baseURL: URL(string: "http://connection.test/first")!)
        try await wait("http-document-announces-in-the-toolbar") { browser.bottomBar.pageHint?.content == .insecureConnection }
        let hint = browser.bottomBar.pageHint!, landing = browser.bottomBar.moreLanding
        let reference = ToolbarPageHint(documentID: "reference", landing: landing, in: browser.bottomBar.home)
        try check("http-uses-the-shared-glyph-frame-and-origin", hint.glyph.bounds == reference.glyph.bounds && hint.origin == reference.origin && hint.destination == reference.destination)
        try check("http-glyph-is-red-and-open-left", hint.glyph.tintColor == .systemRed && opensLeft(hint.glyph.image))
        for time in [0.0, 0.07, ToolbarPageHint.flightStart+0.14, ToolbarPageHint.arrival] {
            let actual = hint.pose(at: time), expected = reference.pose(at: time)
            try check("http-has-the-identical-translation-flight-\(time)", actual.position == expected.position && actual.scale == expected.scale && actual.opacity == expected.opacity)
        }
        try check("cue-does-not-steal-menu-taps", !hint.isUserInteractionEnabled && hint.accessibilityElementsHidden)
        try check("http-keyframes-use-the-same-duration-and-frame-rate", hint.glyph.layer.animation(forKey: "page-hint.position")?.duration == ToolbarPageHint.duration && hint.glyph.layer.animation(forKey: "page-hint.position")?.preferredFrameRateRange.preferred == 120)
        try capture("http-warning")
        let untilImpact = hint.startTime+ToolbarPageHint.arrival+0.07-CACurrentMediaTime()
        if untilImpact > 0 { try await Task.sleep(for: .seconds(untilImpact)) }
        let impact = landing.layer.presentation()?.transform ?? CATransform3DIdentity
        try check("http-reuses-the-menus-rightward-impact", impact.m41 > 1 && impact.m41 < 4 && abs(impact.m42) < 0.01)
        try await wait("http-cue-cleans-up-at-rest") { browser.bottomBar.pageHint == nil && CATransform3DIsIdentity(landing.layer.transform) }
        browser.updateAddress(); browser.updateAddress()
        try check("address-refreshes-do-not-repeat-the-warning", browser.bottomBar.pageHint == nil)
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(650))
        try check("menu-keeps-the-red-unlocked-address", !address.lock.isHidden && address.lock.tintColor == .systemRed)
        try capture("http-address")
        let first = browser.tabs[0].insecureConnectionHintID
        page.loadHTMLString(html.replacingOccurrences(of: "lang='en'", with: "lang='fr'"), baseURL: URL(string: "http://connection.test/second")!)
        try await wait("new-http-document-has-a-fresh-warning") { browser.tabs[0].insecureConnectionHintID != first && !page.isLoading }
        try check("warning-defers-while-menu-is-open", browser.bottomBar.pageHint == nil)
        browser.closePanel()
        try await wait("closing-the-menu-plays-the-deferred-warning") { browser.bottomBar.pageHint?.content == .insecureConnection }
        browser.openPanel(.menu)
        try check("opening-menu-cleans-up-warning-and-impact", browser.bottomBar.pageHint == nil && landing.layer.animationKeys()?.contains(where: { $0.hasPrefix("page-hint-impact-") }) != true)
        browser.closePanel()
        try await Task.sleep(for: .milliseconds(600))
        page.loadHTMLString("<html lang='fr'><body><p>Bonjour le monde. Une page en français pour lire un article et découvrir une nouvelle histoire avec des amis.</p></body></html>", baseURL: URL(string: "http://connection.test/french")!)
        try await wait("foreign-http-page-still-prioritizes-the-red-lock") { browser.bottomBar.pageHint?.content == .insecureConnection }
        try await wait("http-translation-controls-remain-available") { browser.pageTranslation.state(for: page).available }
        var holdTranslation = true
        browser.pageTranslation.translator = { texts, _ in
            while holdTranslation { try await Task.sleep(for: .milliseconds(40)) }
            return texts
        }
        browser.pageTranslation.toggle(page)
        try check("translation-progress-does-not-overlap-the-red-warning", browser.bottomBar.pageHint?.content == .insecureConnection && browser.bottomBar.translationStatus == nil)
        try await wait("translation-progress-appears-after-the-warning-lands") { browser.bottomBar.pageHint == nil && browser.bottomBar.translationStatus != nil }
        holdTranslation = false
        browser.pageTranslation.toggle(page)
        page.loadHTMLString(html, baseURL: URL(string: "http://connection.test/cancel")!)
        try await wait("another-http-document-can-start-its-own-cue") { browser.bottomBar.pageHint?.content == .insecureConnection }
        page.loadHTMLString(html, baseURL: URL(string: "https://connection.test/secure")!)
        try await wait("https-navigation-removes-the-http-cue") { page.url?.scheme == "https" && !page.isLoading && browser.bottomBar.pageHint == nil }
        try check("https-restores-the-green-closed-address", !address.lock.isHidden && address.lock.tintColor == .systemGreen && address.lock.image?.imageOrientation == .up)
        try check("https-cleans-up-any-in-flight-impact", landing.layer.animationKeys()?.contains(where: { $0.hasPrefix("page-hint-impact-") }) != true)
        let privateBrowser = BrowserViewController(startURL: nil, isPrivateBrowsing: true)
        window.rootViewController = privateBrowser; privateBrowser.view.layoutIfNeeded()
        privateBrowser.webView.loadHTMLString(html, baseURL: URL(string: "http://connection.test/private")!)
        try await wait("private-http-tabs-show-the-same-warning") { privateBrowser.bottomBar.pageHint?.content == .insecureConnection }
        try check("private-warning-is-also-red", privateBrowser.bottomBar.pageHint?.glyph.tintColor == .systemRed)
    }
}
#endif
