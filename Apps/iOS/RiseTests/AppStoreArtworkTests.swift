import UIKit
import WebKit
import XCTest
@testable import RiseiOS

final class AppStoreArtworkTests: XCTestCase {
    @MainActor private func service() -> AppStoreArtwork {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        return AppStoreArtwork(session: URLSession(configuration: config))
    }
    private func link(_ id: String = "6737119425") -> AppStoreLink {
        AppStoreLink(URL(string: "https://apps.apple.com/uk/app/gov-uk-one-login/id\(id)?pt=private&ct=qr")!)!
    }

    @MainActor func testLookupUsesProductIDAndStorefrontWithoutTrackingParameters() {
        let url = AppStoreArtwork.lookupURL(for: link())
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(url.host, "itunes.apple.com")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) }),
                       ["id": "6737119425", "country": "gb", "entity": "software"])
        let noCountry = AppStoreLink(URL(string: "https://apps.apple.com/app/id123")!)!
        XCTAssertTrue(AppStoreArtwork.lookupURL(for: noCountry).absoluteString.contains("country=us"))
    }

    @MainActor func testArtworkDownloadsAndCachesOnlyTheMatchingApp() async throws {
        let service = service(), link = link()
        let before = ArtworkProtocol.requests.count(for: AppStoreArtwork.lookupURL(for: link))
        let fetched = await service.image(for: link)
        let image = try XCTUnwrap(fetched)
        XCTAssertGreaterThan(image.size.width, 0)
        let cached = await service.image(for: link)
        XCTAssertTrue(cached === image)
        XCTAssertEqual(ArtworkProtocol.requests.count(for: AppStoreArtwork.lookupURL(for: link)), before+1)
    }

    @MainActor func testMissingWrongUntrustedCorruptAndOfflineArtworkReturnFallback() async {
        let service = service()
        for id in ["111", "112", "114", "115", "116", "117"] {
            let image = await service.image(for: link(id))
            XCTAssertNil(image, id)
        }
    }

    @MainActor func testToastShowsSuppliedFallbackThenFullColorArtwork() async throws {
        let page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        var pending: CheckedContinuation<UIImage?, Never>?
        let toast = AppStoreToast(link: link(), page: page, showsAppArtwork: true, artwork: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        let fallback = try XCTUnwrap(UIImage(named: "ToastAppStore"))
        XCTAssertEqual(toast.appIcon.image?.pngData(), fallback.pngData())
        for _ in 0..<20 where pending == nil { await Task.yield() }
        let icon = try XCTUnwrap(UIImage(data: ArtworkProtocol.png))
        try XCTUnwrap(pending).resume(returning: icon)
        for _ in 0..<20 where toast.appIcon.image?.renderingMode != .alwaysOriginal { await Task.yield() }
        XCTAssertEqual(toast.appIcon.image?.renderingMode, .alwaysOriginal)
        XCTAssertEqual(toast.appIcon.image?.pngData(), icon.pngData())
        XCTAssertEqual(toast.appIcon.layer.cornerRadius, 5)
    }

    @MainActor func testDismissedToastIgnoresLateArtworkAndFailureKeepsFallback() async throws {
        let page = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        var pending: CheckedContinuation<UIImage?, Never>?
        let toast = AppStoreToast(link: link(), page: page, showsAppArtwork: true, artwork: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        let original = toast.appIcon.image?.pngData()
        for _ in 0..<20 where pending == nil { await Task.yield() }
        toast.dismiss(animated: false)
        try XCTUnwrap(pending).resume(returning: UIImage(data: ArtworkProtocol.png))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(toast.appIcon.image?.pngData(), original)
        var requestedArtwork = false
        let failed = AppStoreToast(link: link(), page: page, artwork: { _ in requestedArtwork = true; return UIImage(data: ArtworkProtocol.png) })
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(failed.appIcon.image?.pngData(), original)
        XCTAssertFalse(requestedArtwork, "The default App Store icon must not trigger an artwork lookup")
        XCTAssertFalse(failed.dismissed)
    }
}

private final class ArtworkRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func note(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    func count(for url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return urls.filter { $0 == url }.count }
}

private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    static let requests = ArtworkRequests()
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGNQmHAXK2IYWhIAmMJjQXFQF3IAAAAASUVORK5CYII=")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.note(url)
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        if id == "117" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let data: Data
        if url.host == "itunes.apple.com" {
            let result: [String: Any] = ["trackId": Int64(id == "112" ? "113" : id)!, "kind": "software",
                                       "artworkUrl100": "https://\(id == "114" ? "untrusted.example" : "is1-ssl.mzstatic.com")/\(id).png"]
            data = try! JSONSerialization.data(withJSONObject: ["results": id == "111" ? [] : [result]])
        } else { data = url.path == "/116.png" ? Data("broken".utf8) : Self.png }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: id == "115" ? 503 : 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
