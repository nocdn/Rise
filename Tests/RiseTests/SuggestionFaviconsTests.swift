import XCTest
import AppKit
import RiseCore
@testable import Rise

private final class IconProtocol: URLProtocol {
    static var png = Data()
    static var largePNG = Data()
    static var requests: [URL] = []
    static let lock = NSLock()
    static func snapshotRequests() -> [URL] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url!); Self.lock.unlock()
        let invalid = request.url!.host == "invalid.example"
        let url = request.url!
        let missing = ["root-only.example", "redirect-only.example"].contains(url.host ?? "") && url.path == "/favicon.ico"
        var bytes = invalid ? Data("not an image".utf8) : Self.png
        if url.host == "quality.example.org", url.path == "/" {
            bytes = Data("<link rel='shortcut icon' href='/favicon.ico'><link rel='icon' href='/large.png' sizes='144x144'>".utf8)
        } else if url.host == "quality.example.org", url.path == "/large.png" {
            bytes = Self.largePNG
        } else if url.host == "calendar.example" && url.path == "/favicon.ico" {
            bytes = Data("<link rel='shortcut icon' href='https://cdn.example/calendar.png'>".utf8)
        } else if missing { bytes = Data() }
        else if url.host == "root-only.example" && url.path == "/" {
            bytes = Data("<base HREF='https://cdn.example/assets/'><link type='image/svg+xml' rel='icon' href='icon.svg'><link href='calendar.png?x=1&amp;y=2' REL='shortcut icon'>".utf8)
        }
        let redirected = url.host == "redirect-only.example" && url.path == "/"
        if redirected { bytes = Data("<title>Sign in</title>".utf8) }
        let response = HTTPURLResponse(url: redirected ? URL(string: "https://login.example/signin?flow=server")! : url, statusCode: missing ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SuggestionFaviconsTests: XCTestCase {
    @MainActor private func bitmap(_ size: Int, color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<size { for x in 0..<size {
            let at = y*bitmap.bytesPerRow+x*4
            pixels[at] = UInt8(rgb.redComponent*255); pixels[at+1] = UInt8(rgb.greenComponent*255)
            pixels[at+2] = UInt8(rgb.blueComponent*255); pixels[at+3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor func testLowResolutionFallbackUpgradesAndLegacySnapshotsCannotReplaceSharpArtwork() async throws {
        _ = NSApplication.shared
        IconProtocol.png = try bitmap(16, color: .red)
        IconProtocol.largePNG = try bitmap(144, color: .green)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IconProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = URL(string: "https://quality.example.org/watch?private=query")!, origin = SitePermissions.origin(url)!
        for legacy in [false, true] {
            IconProtocol.requests = []
            let file = folder.appendingPathComponent(legacy ? "legacy.json" : "new.json")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stale = try bitmap(32, color: .red)
            if legacy { try JSONEncoder().encode([origin: stale]).write(to: file) }
            let cache = SuggestionFavicons(storageURL: file, session: session); defer { cache.cancel() }
            if legacy { XCTAssertNotNil(cache.image(for: url, fetch: false), "Keep the old icon visible during migration") }
            _ = cache.image(for: url)
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                if let image = cache.image(for: url, fetch: false), FaviconImage.pixels(image) >= 64 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let sharp = try XCTUnwrap(cache.image(for: url, fetch: false))
            XCTAssertGreaterThanOrEqual(FaviconImage.pixels(sharp), 64)
            let expected = legacy ? [URL(string: origin+"/")!, URL(string: origin+"/large.png")!]
                : [URL(string: "https://quality.example.org/favicon.ico")!, URL(string: origin+"/")!, URL(string: origin+"/large.png")!]
            XCTAssertEqual(IconProtocol.snapshotRequests(), expected, "Discovery must not send the suggested page's path or query")
            let snapshot = try XCTUnwrap(FaviconSnapshot.encode(sharp))
            cache.save(); BackgroundFiles.flush()
            let restored = SuggestionFavicons(storageURL: file, session: session); defer { restored.cancel() }
            let staleTab = BrowserTab(saved: SavedTab(url: url.absoluteString, title: "YouTube-style page", faviconData: stale, faviconOrigin: origin))
            restored.remember(staleTab)
            XCTAssertEqual(staleTab.faviconData, snapshot, "A restored blurry tab adopts the sharper cache instead of overwriting it")
            XCTAssertEqual(FaviconSnapshot.encode(restored.image(for: url)), snapshot)
            XCTAssertTrue(restored.storePageIcon(IconProtocol.png, for: url))
            XCTAssertEqual(FaviconSnapshot.encode(restored.image(for: url, fetch: false)), snapshot, "A later 16px default icon cannot downgrade the cache")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(IconProtocol.snapshotRequests(), expected, "The upgraded cache must survive relaunch without another request")
        }
    }

    @MainActor func testTypedAddressesDebounceCancelAndDiscoverHTMLIconsWithoutSendingTheTypedPath() async throws {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.systemBlue.setFill(); rect.fill(); return true }
        IconProtocol.png = FaviconSnapshot.encode(image)!; IconProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IconProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("icons.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = SuggestionFavicons(storageURL: file, session: session); defer { cache.cancel() }
        cache.preview(URL(string: "https://partial.example"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(IconProtocol.snapshotRequests().isEmpty)
        cache.preview(nil)
        cache.preview(URL(string: "https://calendar.g"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(IconProtocol.snapshotRequests().isEmpty, "Search text, incomplete hosts, and cancelled edits do not fetch")
        let url = URL(string: "https://calendar.example/private/path?draft=secret#fragment")!
        cache.preview(url)
        let deadline = Date().addingTimeInterval(3)
        while cache.image(for: url, fetch: false) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(cache.image(for: url, fetch: false))
        XCTAssertEqual(IconProtocol.snapshotRequests(), [URL(string: "https://calendar.example/favicon.ico")!, URL(string: "https://cdn.example/calendar.png")!])
        cache.preview(url); try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(IconProtocol.snapshotRequests().count, 2, "A cached origin never refetches for more typing")
    }
    @MainActor func testMissingDefaultIconDiscoversRelativeRasterLinkAtTheOriginRoot() async throws {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in NSColor.systemGreen.setFill(); rect.fill(); return true }
        IconProtocol.png = FaviconSnapshot.encode(image)!; IconProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IconProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("icons.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = SuggestionFavicons(storageURL: file, session: session); defer { cache.cancel() }
        let url = URL(string: "https://root-only.example/private?draft=secret")!
        _ = cache.image(for: url)
        let deadline = Date().addingTimeInterval(3)
        while cache.image(for: url, fetch: false) == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(cache.image(for: url, fetch: false))
        XCTAssertEqual(IconProtocol.snapshotRequests(), [URL(string: "https://root-only.example/favicon.ico")!, URL(string: "https://root-only.example:443/")!, URL(string: "https://cdn.example/assets/calendar.png?x=1&y=2")!, URL(string: "https://cdn.example/assets/icon.svg")!])
        let redirect = URL(string: "https://redirect-only.example")!
        _ = cache.image(for: redirect)
        let redirectDeadline = Date().addingTimeInterval(3)
        while cache.image(for: redirect, fetch: false) == nil && Date() < redirectDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(cache.image(for: redirect, fetch: false))
        XCTAssertEqual(Array(IconProtocol.snapshotRequests().suffix(3)), [URL(string: "https://redirect-only.example/favicon.ico")!, URL(string: "https://redirect-only.example:443/")!, URL(string: "https://login.example/favicon.ico")!])
    }
    @MainActor func testFetchesOncePerOriginUpdatesSelectedRowInPlaceAndPersistsWithoutTint() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { bounds in NSColor.systemOrange.setFill(); bounds.fill(); return true }
        IconProtocol.png = FaviconSnapshot.encode(image)!; IconProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IconProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("icons.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = SuggestionFavicons(storageURL: file, session: session)
        defer { cache.cancel() }
        let palette = AddressPalette(), url = URL(string: "https://example.com/docs")!
        palette.suggestions = [AddressSuggestion(title: "Docs", subtitle: "", symbol: "globe", url: url, tabID: nil, command: nil)]
        palette.input.stringValue = "draft"; palette.render()
        let button = palette.buttons[0]
        cache.onLoad = { palette.updateFavicon($1, origin: $0) }
        XCTAssertNil(cache.image(for: url)); XCTAssertNil(cache.image(for: URL(string: "https://example.com/other")))
        let deadline = Date().addingTimeInterval(3)
        while palette.suggestions[0].favicon == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(palette.suggestions[0].favicon)
        XCTAssertTrue(palette.buttons[0] === button, "An arriving icon must not rebuild rows or reset selection/input")
        XCTAssertEqual(palette.input.stringValue, "draft"); XCTAssertEqual(palette.selectedIndex, -1)
        XCTAssertNil((button.subviews.first as? NSImageView)?.contentTintColor)
        XCTAssertEqual(IconProtocol.snapshotRequests().count, 1)
        cache.save(); BackgroundFiles.flush()
        let restored = SuggestionFavicons(storageURL: file, session: session); defer { restored.cancel() }
        XCTAssertNotNil(restored.image(for: url))
        XCTAssertNil(restored.image(for: URL(string: "https://example.com:8443/docs")))
        XCTAssertNil(restored.image(for: URL(string: "https://invalid.example")))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(restored.image(for: URL(string: "https://invalid.example")), "Invalid image payloads never enter the cache")
    }
    @MainActor func testDeclaredCDNIconsReplaceTheFallbackForTheirPageOrigin() async throws {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in NSColor.systemGreen.setFill(); bounds.fill(); return true }
        IconProtocol.png = FaviconSnapshot.encode(image)!; IconProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IconProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("icons.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = SuggestionFavicons(storageURL: file, session: session); defer { cache.cancel() }
        let page = URL(string: "https://site.example/docs")!, icon = URL(string: "https://cdn.example/assets/icon.png")!
        var loaded: String?
        cache.onLoad = { origin, _ in loaded = origin }
        cache.loadPageIcon(icon, for: page); cache.loadPageIcon(icon, for: page)
        let deadline = Date().addingTimeInterval(3)
        while loaded == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loaded, "https://site.example:443")
        XCTAssertNotNil(cache.image(for: page))
        XCTAssertEqual(IconProtocol.snapshotRequests(), [icon])
    }
}
