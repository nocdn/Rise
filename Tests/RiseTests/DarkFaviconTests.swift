import XCTest
import AppKit
import RiseCore
@testable import Rise

private final class AdaptiveIconProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/svg+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: DarkFaviconTests.svg)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class DarkFaviconTests: XCTestCase {
    fileprivate static let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">
        <style>rect { fill: #24292e; }
        @media (prefers-color-scheme: dark) { rect { fill: white; } }
        @media (prefers-color-scheme: light) { rect { fill: #24292e; } }
        </style><rect width="32" height="32"/></svg>
        """.utf8)
    @MainActor private func color(_ image: NSImage) throws -> NSColor {
        let png = try XCTUnwrap(FaviconSnapshot.encode(image))
        return try XCTUnwrap(NSBitmapImageRep(data: png)?.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
    }
    func testMediaIconsPreferTheRequestedSchemeAndRespectRelativeBaseURLs() {
        let base = URL(string: "https://example.com/page")!
        let html = Data("""
            <base href="https://cdn.example/icons/">
            <link rel="icon" href="fallback.png">
            <link rel="icon" media="(prefers-color-scheme: light)" href="light.png">
            <link rel="icon" media="(prefers-color-scheme: dark)" href="dark.png">
            """.utf8)
        XCTAssertEqual(FaviconDiscovery.icon(in: html, baseURL: base)?.absoluteString, "https://cdn.example/icons/light.png")
        XCTAssertEqual(FaviconDiscovery.icon(in: html, baseURL: base, dark: true)?.absoluteString, "https://cdn.example/icons/dark.png")
        XCTAssertEqual(FaviconDiscovery.darkIcon(for: URL(string: "https://github.com/org/repo"))?.lastPathComponent, "favicon-dark.png")
        let github = URL(string: "https://github.com/org/repo")!
        let rewrittenLink = Data("<link rel='icon' href='https://github.githubassets.com/favicons/favicon-dark.svg'>".utf8)
        XCTAssertEqual(FaviconDiscovery.icon(in: rewrittenLink, baseURL: github)?.lastPathComponent, "favicon.png", "A site's live dark link must not overwrite its light icon")
        XCTAssertNil(FaviconDiscovery.darkIcon(for: URL(string: "https://github.com.example/repo")))
    }
    @MainActor func testSVGAppearanceRulesUseTheSitesColorsAndPersistAsTwoIndependentImages() throws {
        let light = try XCTUnwrap(FaviconImage.decode(Self.svg, dark: false))
        let dark = try XCTUnwrap(FaviconImage.decode(Self.svg, dark: true))
        XCTAssertLessThan(try color(light).redComponent, 0.2)
        XCTAssertGreaterThan(try color(dark).redComponent, 0.95)
        let tab = BrowserTab()
        tab.requestedURL = URL(string: "https://example.com/page")
        tab.iconOrigin = SitePermissions.origin(tab.url); tab.favicon = light; tab.darkFavicon = dark
        let encoded = try JSONEncoder().encode(tab.saved)
        let restored = BrowserTab(saved: try JSONDecoder().decode(SavedTab.self, from: encoded))
        XCTAssertLessThan(try color(XCTUnwrap(restored.favicon(for: .neutral))).redComponent, 0.2)
        XCTAssertGreaterThan(try color(XCTUnwrap(restored.favicon(for: .dark))).redComponent, 0.95)
        restored.requestedURL = URL(string: "about:blank"); restored.updateIcon()
        XCTAssertNil(restored.darkFavicon); XCTAssertNil(restored.saved.darkFaviconData)
    }
    @MainActor func testSuggestionCacheRestoresBothVariantsWithoutRefetchAndSidebarFollowsTheme() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("icons.json")
        let cache = SuggestionFavicons(storageURL: file); defer { cache.cancel() }
        let tab = BrowserTab()
        tab.requestedURL = URL(string: "https://example.com/page")
        tab.iconOrigin = SitePermissions.origin(tab.url)
        tab.favicon = FaviconImage.decode(Self.svg, dark: false); tab.darkFavicon = FaviconImage.decode(Self.svg, dark: true)
        cache.remember(tab); cache.save()
        let restored = SuggestionFavicons(storageURL: file); defer { restored.cancel() }
        XCTAssertGreaterThan(try color(XCTUnwrap(restored.image(for: tab.url, fetch: false, dark: true))).redComponent, 0.95)
        XCTAssertLessThan(try color(XCTUnwrap(restored.image(for: tab.url, fetch: false))).redComponent, 0.2)
        let row = TabRow(tab: tab, onClose: {})
        row.update(tab: tab, selected: true, theme: .dark, configuration: .forTab(tab, theme: .dark))
        XCTAssertTrue(row.icon.image === tab.darkFavicon)
        row.update(tab: tab, selected: true, theme: .neutral, configuration: .forTab(tab, theme: .neutral))
        XCTAssertTrue(row.icon.image === tab.favicon)
        tab.darkFavicon = nil
        row.update(tab: tab, selected: true, theme: .dark, configuration: .forTab(tab, theme: .dark))
        XCTAssertTrue(row.icon.image === tab.favicon, "Sites with no variant keep their original favicon")
    }
    @MainActor func testOneAdaptiveSVGDownloadProducesBothAppearancesWithoutOverwritingLight() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AdaptiveIconProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SuggestionFavicons(storageURL: directory.appendingPathComponent("icons.json"), session: session)
        defer { cache.cancel() }
        let page = URL(string: "https://example.com/docs")!
        var appearances: [Bool] = []
        cache.onVariantLoad = { _, _, dark in appearances.append(dark) }
        cache.loadPageIcon(URL(string: "https://cdn.example/favicon.svg")!, for: page)
        let deadline = Date().addingTimeInterval(3)
        while appearances.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(appearances, [false, true])
        XCTAssertLessThan(try color(XCTUnwrap(cache.image(for: page, fetch: false))).redComponent, 0.2)
        XCTAssertGreaterThan(try color(XCTUnwrap(cache.image(for: page, fetch: false, dark: true))).redComponent, 0.95)
    }
}
