import XCTest
import AppKit
import RiseCore
@testable import Rise

private final class TabMetadataProtocol: URLProtocol {
    struct Reply { var data: Data; var status = 200; var type = "text/html"; var delay = 0.0; var landed: URL? }
    private static let lock = NSLock()
    private static var replies: [URL: Reply] = [:]
    private static var requests: [URL] = []
    private static var active = Set<ObjectIdentifier>()
    private static var peak = 0
    private static var failFirst = Set<URL>()
    private var stopped = false
    static func reset() { lock.lock(); defer { lock.unlock() }; replies = [:]; requests = []; active = []; peak = 0; failFirst = [] }
    static func set(_ url: URL, _ reply: Reply, failOnce: Bool = false) {
        lock.lock(); defer { lock.unlock() }; replies[url] = reply
        if failOnce { failFirst.insert(url) }
    }
    static func snapshot() -> (requests: [URL], peak: Int) { lock.lock(); defer { lock.unlock() }; return (requests, peak) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(url); Self.active.insert(ObjectIdentifier(self)); Self.peak = max(Self.peak, Self.active.count)
        var reply = Self.replies[url] ?? Reply(data: Data(), status: 404)
        if Self.failFirst.remove(url) != nil { reply.status = 503 }
        Self.lock.unlock()
        let response = reply
        DispatchQueue.global().asyncAfter(deadline: .now()+reply.delay) { [self] in
            Self.lock.lock(); let deliver = !stopped; Self.active.remove(ObjectIdentifier(self)); Self.lock.unlock()
            guard deliver else { return }
            let header = HTTPURLResponse(url: response.landed ?? url, statusCode: response.status, httpVersion: nil,
                headerFields: ["Content-Type": response.type])!
            client?.urlProtocol(self, didReceive: header, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }; stopped = true; Self.active.remove(ObjectIdentifier(self))
    }
}

@MainActor final class SyncedTabMetadataTests: XCTestCase {
    private func fixture() -> (SyncedTabMetadata, SuggestionFavicons, URL, URLSession) {
        _ = NSApplication.shared; TabMetadataProtocol.reset()
        let directory = URL.temporaryDirectory.appendingPathComponent("RiseMetadata-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TabMetadataProtocol.self]
        let session = URLSession(configuration: configuration)
        let icons = SuggestionFavicons(storageURL: directory.appendingPathComponent("icons.json"), session: session)
        let loader = SyncedTabMetadata(icons: icons, session: session, retryDelay: 0.05)
        addTeardownBlock { @MainActor in loader.cancel(); icons.cancel(); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        return (loader, icons, directory, session)
    }
    private func image(_ color: NSColor) -> Data {
        FaviconSnapshot.encode(NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in color.setFill(); bounds.fill(); return true })!
    }
    private func page(_ url: URL, title: String = "New Tab", icon: URL? = nil, delay: Double = 0, failOnce: Bool = false) -> BrowserTab {
        let icon = icon ?? URL(string: "/favicon.ico", relativeTo: url)!.absoluteURL
        TabMetadataProtocol.set(url, .init(data: Data("<title>Fetched &amp; ready &#x1F680;</title><link rel=icon href='\(icon)'>".utf8), delay: delay), failOnce: failOnce)
        TabMetadataProtocol.set(icon, .init(data: image(.systemBlue), type: "image/png"))
        return BrowserTab(saved: SavedTab(url: url.absoluteString, title: title))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Metadata did not settle"); throw URLError(.timedOut)
    }

    func testBatchImportIsBoundedAndDoesNotLoadTheRealPages() async throws {
        let (loader, _, _, _) = fixture()
        let tabs = (0..<12).map { page(URL(string: "https://site\($0).example/article")!, delay: 0.04) }
        loader.update(tabs: tabs)
        try await wait { tabs.allSatisfy { $0.favicon != nil } && loader.activeCount == 0 }
        XCTAssertLessThanOrEqual(TabMetadataProtocol.snapshot().peak, SyncedTabMetadata.concurrency)
        for tab in tabs {
            XCTAssertEqual(tab.title, "Fetched & ready 🚀")
            XCTAssertNil(tab.page.url); XCTAssertFalse(tab.hasAttemptedNavigation)
            XCTAssertEqual((tab.page as? BlankPage)?.loadCount, 0)
            XCTAssertNotNil(tab.saved.faviconData)
        }
        let count = TabMetadataProtocol.snapshot().requests.count
        loader.update(tabs: tabs); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(TabMetadataProtocol.snapshot().requests.count, count)
    }

    func testCancellationRejectsClosedNavigatedAndSelectedTabs() async throws {
        let (loader, _, _, _) = fixture()
        let tabs = (0..<3).map { page(URL(string: "https://cancel\($0).example/article")!, delay: 0.25) }
        loader.update(tabs: tabs)
        try await wait { TabMetadataProtocol.snapshot().requests.count == 3 }
        tabs[0].requestedURL = URL(string: "https://elsewhere.example/new")
        tabs[1].load(URL(string: "about:blank")!)
        loader.update(tabs: [tabs[1]])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(loader.activeCount, 0)
        XCTAssertTrue(tabs.allSatisfy { $0.title != "Fetched & ready 🚀" && $0.favicon == nil })
        XCTAssertEqual(TabMetadataProtocol.snapshot().requests.count, 3)
    }

    func testCustomAndMobileTitlesSurviveAndTheIconCacheRestoresWithoutNetwork() async throws {
        let (loader, icons, directory, session) = fixture()
        let a = page(URL(string: "https://names.example/a")!, title: "Title from iPhone")
        let b = page(URL(string: "https://names.example/b")!)
        b.rename("My name")
        loader.update(tabs: [a,b])
        try await wait { a.favicon != nil && b.favicon != nil && loader.activeCount == 0 }
        XCTAssertEqual(a.title, "Title from iPhone"); XCTAssertEqual(b.title, "My name")
        icons.save(); BackgroundFiles.flush()
        let restoredIcons = SuggestionFavicons(storageURL: directory.appendingPathComponent("icons.json"), session: session)
        let restored = SyncedTabMetadata(icons: restoredIcons, session: session)
        defer { restored.cancel(); restoredIcons.cancel() }
        let tab = BrowserTab(saved: SavedTab(url: a.url!.absoluteString, title: a.title))
        let count = TabMetadataProtocol.snapshot().requests.count
        restored.update(tabs: [tab])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(tab.favicon)
        XCTAssertEqual(TabMetadataProtocol.snapshot().requests.count, count)
    }

    func testRetriesFailedPagesWithoutAnotherSyncAndFetchesBothIconAppearances() async throws {
        let (loader, _, _, _) = fixture()
        let url = URL(string: "https://retry.example/article")!
        let tab = page(url, failOnce: true)
        TabMetadataProtocol.set(url, .init(data: Data("<title>Recovered</title><link rel=icon href='/light.png' media='(prefers-color-scheme: light)'><link rel=icon href='/dark.png' media='(prefers-color-scheme: dark)'>".utf8)), failOnce: true)
        TabMetadataProtocol.set(URL(string: "https://retry.example/light.png")!, .init(data: image(.systemRed), type: "image/png"))
        TabMetadataProtocol.set(URL(string: "https://retry.example/dark.png")!, .init(data: image(.systemGreen), type: "image/png"))
        loader.update(tabs: [tab])
        try await wait { tab.title == "Recovered" && tab.darkFavicon != nil && loader.activeCount == 0 }
        XCTAssertEqual(TabMetadataProtocol.snapshot().requests.filter { $0 == url }.count, 2)
        XCTAssertTrue(TabMetadataProtocol.snapshot().requests.contains(URL(string: "https://retry.example/light.png")!),
                      "A declared icon replaces the temporary root favicon after the document recovers")
        XCTAssertNotEqual(tab.saved.faviconData, tab.saved.darkFaviconData)
    }

    func testMetadataIgnoresScriptTitlesDecodesEntitiesAndDoesNotUseCrossSiteLoginTitles() async throws {
        let html = "<!--\n<title>wrong</title>\n--><script>\nconst example = '<title>wrong too</title>';\n</script><TITLE>  News\n &amp; updates &mdash; &#x1F680; </TITLE>"
        let metadata = TabPageMetadata(html: Data(html.utf8), url: URL(string: "https://parser.example")!)
        XCTAssertEqual(metadata.title, "News & updates — 🚀")
        XCTAssertNil(TabPageMetadata(html: Data(repeating: 65, count: 1_000_001), url: URL(string: "https://parser.example")!).title)
        let (loader, _, _, _) = fixture()
        let url = URL(string: "https://protected.example/account")!, tab = page(URL(string: "https://protected.example/account")!)
        TabMetadataProtocol.set(url, .init(data: Data("<title>SSO Login</title>".utf8), landed: URL(string: "https://login.example/signin")!))
        loader.update(tabs: [tab])
        try await wait { tab.favicon != nil && loader.activeCount == 0 }
        XCTAssertEqual(tab.title, "New Tab")
        XCTAssertTrue(TabMetadataProtocol.snapshot().requests.allSatisfy { $0.host != "login.example" })
    }

    func testBrowserAdapterUpdatesTheSidebarAndSavedSessionWithoutAddingVisits() async throws {
        let (loader, _, directory, _) = fixture()
        let browser = BrowserController(sessionURL: directory.appendingPathComponent("session.json"), restore: false)
        let selected = browser.addTab()
        browser.syncedTabMetadata = loader
        loader.onChange = { [weak browser] in browser?.update() }
        defer { browser.syncedTabMetadata?.cancel(); browser.saveWork?.cancel(); browser.window?.orderOut(nil) }
        let url = URL(string: "https://adapter.example/article")!, id = UUID()
        _ = page(url)
        browser.applySharedTabs([.init(id: id, url: url.absoluteString, title: "adapter.example"), .init(id: selected.id, url: nil, title: selected.title)])
        let imported = try XCTUnwrap(browser.tabs.first { $0.id == id })
        try await wait { imported.favicon != nil && loader.activeCount == 0 }
        browser.update(); browser.saveNow()
        XCTAssertEqual(browser.selectedID, selected.id)
        XCTAssertEqual(imported.title, "Fetched & ready 🚀")
        XCTAssertNil(imported.page.url)
        XCTAssertTrue(browser.sidebar.rows[id]?.icon.image === imported.favicon)
        XCTAssertTrue(browser.browsingHistory.entries.isEmpty)
        let saved = SessionStorage.read(from: browser.sessionURL)
        XCTAssertEqual(saved?.tabs.first { $0.id == id }?.title, imported.title)
        XCTAssertNotNil(saved?.tabs.first { $0.id == id }?.faviconData)
    }

    func testLargeDocumentsStayBoundedAndNonWebLocalAndCredentialAddressesAreExcluded() async throws {
        let (loader, _, _, _) = fixture()
        let url = URL(string: "https://large.example/article")!, tab = BrowserTab(saved: SavedTab(url: "https://large.example/article", title: "New Tab"))
        var data = Data("<title>Large document</title>".utf8); data.append(Data(repeating: 65, count: 1_100_000))
        TabMetadataProtocol.set(url, .init(data: data))
        let excluded = ["file:///tmp/private.html", "rise://settings", "about:blank", "http://localhost/private", "https://user:password@credentials.example/account"]
            .map { BrowserTab(saved: SavedTab(url: $0, title: "New Tab")) }
        loader.update(tabs: [tab]+excluded)
        try await wait { tab.title == "Large document" && loader.activeCount == 0 }
        XCTAssertEqual(Set(TabMetadataProtocol.snapshot().requests), [url, URL(string: "https://large.example/favicon.ico")!])
        let count = TabMetadataProtocol.snapshot().requests.count
        loader.update(tabs: [tab]+excluded); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(TabMetadataProtocol.snapshot().requests.count, count, "A genuine missing favicon is not retried continuously")
    }
}
