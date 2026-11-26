// Any site's floating video, the tab's play and sound buttons, page full screen, Gmail's inbox
// and Google Calendar's readers, someone's calendar from their Google profile card, pausing
// downloads, what Page Assistant reads, site search learning, the swipe's page probe and hard
// reloads, on Chromium: the XCTest cases these were written as, run in Rise windows
// (Tests/Live/LiveXCTest.swift), with pages at the addresses they name. Run with
// scripts/test-chromium-live.py media; RISE_CASES=<names> runs some.
import AppKit
import Network
import RiseCore
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumMediaMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+1200) { print("DONE timeout"); exit(0) }
        let app = RCApplication.shared
        _ = RCEngine.start(withCachePath: LiveFixtures.folder.path + "/chromium", keychain: false)
        let run = ChromiumMediaRun()
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumMediaRun: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await PageFullscreenCases().runAll()
            await VideoPictureInPictureCases().runAll()
            await TabMediaCases().runAll()
            await TabAudioCases().runAll()
            await GmailReaderCases().runAll()
            await ProtonMailReaderCases().runAll()
            await CalendarReaderCases().runAll()
            await PersonCalendarCases().runAll()
            await DownloadCases().runAll()
            await PageAssistantCases().runAll()
            await SiteSearchLearningCases().runAll()
            await HistorySwipeCases().runAll()
            await HardReloadCases().runAll()
            liveFinish()
        }
    }
}

private final class SlowDownloadServer {
    let listener: NWListener
    let size = 4 * 1024 * 1024
    private let queue = DispatchQueue(label: "Rise.DownloadControlsTests")
    private let lock = NSLock()
    private var offsets: [Int] = []
    var ranges: [Int] { lock.lock(); defer { lock.unlock() }; return offsets }
    var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/file.bin") } }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue); self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, _, _ in
            guard let self else { connection.cancel(); return }
            var buffer = data; if let chunk { buffer.append(chunk) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") else { self.receive(connection, data: buffer); return }
            let range = text.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("range: bytes=") }
            let offset = range.flatMap { Int($0.dropFirst("range: bytes=".count).split(separator: "-").first ?? "0") } ?? 0
            self.lock.lock(); self.offsets.append(offset); self.lock.unlock()
            let status = offset == 0 ? "200 OK" : "206 Partial Content"
            let contentRange = offset == 0 ? "" : "Content-Range: bytes \(offset)-\(self.size-1)/\(self.size)\r\n"
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=test-file.bin\r\nContent-Length: \(self.size-offset)\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\nETag: \"rise-test-v1\"\r\nLast-Modified: Mon, 05 Oct 2026 10:00:00 GMT\r\n\(contentRange)Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                if error == nil { self?.send(connection, offset: offset) } else { connection.cancel() }
            })
        }
    }
    private func send(_ connection: NWConnection, offset: Int) {
        guard offset < size else { connection.cancel(); return }
        let count = min(16384, size-offset)
        connection.send(content: Data(repeating: 0x5a, count: count), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now()+0.02) { [weak self] in self?.send(connection, offset: offset+count) }
        })
    }
}

/// Real downloads in Rise's list: pausing, resuming and cancelling a running one, from a server
/// that sends slowly.
@MainActor final class DownloadCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("ActualDownloadPauseResumeCompletionAndPopoverUpdates") ?? true {
            await liveCase("ActualDownloadPauseResumeCompletionAndPopoverUpdates") { try await testActualDownloadPauseResumeCompletionAndPopoverUpdates() }
        }
        if only?.contains("CancellingDuringPauseRemovesOnlyTheActiveDownload") ?? true {
            await liveCase("CancellingDuringPauseRemovesOnlyTheActiveDownload") { try await testCancellingDuringPauseRemovesOnlyTheActiveDownload() }
        }
    }
    @MainActor private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor private func begin(_ server: SlowDownloadServer, browser: BrowserController) async throws -> DownloadList.Item {
        try await waitUntil("HTTP server listening") { server.url != nil }
        let tab = browser.selectedTab ?? browser.addTab()
        // An attachment, so opening it downloads it, as a click on its link would.
        tab.load(server.url!)
        try await waitUntil("An unfinished file must appear in the list") { !browser.downloads.visible.isEmpty }
        return try XCTUnwrap(browser.downloads.visible.first)
    }
    @MainActor func testActualDownloadPauseResumeCompletionAndPopoverUpdates() async throws {
        let server = try SlowDownloadServer(); defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let item = try await begin(server, browser: browser)
        let controller = DownloadsController(list: browser.downloads); _ = controller.view
        browser.downloads.onChange = { [weak controller] in controller?.reload() }
        try await waitUntil("Byte counts and transfer speed update") { item.receivedBytes > 0 && item.bytesPerSecond > 0 }
        let row = try XCTUnwrap(controller.rows.first)
        row.isHighlighted = false
        XCTAssertFalse(row.progressRing.isHidden); XCTAssertTrue(row.pauseButton.isHidden)
        XCTAssertTrue(row.previewButton.isHidden); XCTAssertTrue(row.removeButton.isHidden)
        row.isHighlighted = true
        XCTAssertFalse(row.pauseButton.isHidden); XCTAssertFalse(row.removeButton.isHidden)
        row.isHighlighted = false
        XCTAssertFalse(row.canPreview)
        browser.downloads.togglePause(item.record.id)
        let ringFill = try XCTUnwrap(row.progressRing.layer?.sublayers?.last as? CAShapeLayer)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertEqual(ringFill.animation(forKey: "pauseColor")?.duration, 0.16)
        }
        try await waitUntil("Pause has captured resume data") { item.state == .paused }
        let bytes = item.receivedBytes
        XCTAssertGreaterThan(bytes, 0); XCTAssertLessThan(bytes, Int64(server.size))
        XCTAssertEqual(item.bytesPerSecond, 0)
        XCTAssertEqual(row.pauseButton.toolTip, "Resume Download")
        XCTAssertFalse(row.pauseButton.isHidden); XCTAssertFalse(row.removeButton.isHidden, "Paused controls remain visible without a hover")
        row.progressRing.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(ringFill.strokeColor, NSColor.secondaryLabelColor.cgColor)
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(item.receivedBytes, bytes, "Paused transfers must stop receiving")
        XCTAssertEqual(browser.downloads.visible.first?.record.id, item.record.id)
        browser.downloads.togglePause(item.record.id)
        try await waitUntil("Resumed download hides controls away from hover") { item.state == .downloading }
        XCTAssertTrue(row.pauseButton.isHidden); XCTAssertTrue(row.removeButton.isHidden)
        row.progressRing.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(ringFill.strokeColor, NSColor.systemBlue.cgColor)
        }
        try await waitUntil("Resume finishes the same list entry") { item.isFinished }
        XCTAssertEqual(browser.downloads.items.count, 1)
        let data = try Data(contentsOf: item.record.url)
        XCTAssertEqual(data.count, server.size); XCTAssertTrue(data.allSatisfy { $0 == 0x5a })
        XCTAssertEqual(item.receivedBytes, Int64(server.size)); XCTAssertEqual(item.totalBytes, Int64(server.size))
        XCTAssertTrue(controller.rows.first === row, "Progress and completion preserve the row")
        XCTAssertTrue(row.progressRing.isHidden); XCTAssertTrue(row.pauseButton.isHidden)
        XCTAssertTrue(DownloadList(storeURL: folder.appendingPathComponent("downloads.json")).visible.first?.isFinished == true)
    }
    @MainActor func testCancellingDuringPauseRemovesOnlyTheActiveDownload() async throws {
        let server = try SlowDownloadServer(); defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: folder) }
        let item = try await begin(server, browser: browser)
        try await waitUntil("Download receives bytes") { item.receivedBytes > 0 }
        browser.downloads.togglePause(item.record.id); browser.downloads.cancel(item.record.id)
        try await waitUntil("Cancellation removes the row even while pausing") { browser.downloads.visible.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.record.path))
        XCTAssertTrue(browser.downloads.pendingDestinations.isEmpty)
    }
}

/// Serves a page and records each request's headers.
private final class HeaderRecordingServer {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Rise.HeaderRecordingServer")
    private let lock = NSLock()
    private var recorded: [String] = []
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global()); self?.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    var url: URL? { listener.port.flatMap { URL(string: "http://[::1]:\($0.rawValue)/") } }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let chunk { data.append(chunk) }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, data: data) }; return
            }
            // Chromium also asks for the site's icon, which isn't a load of the page.
            if request.lowercased().hasPrefix("get /favicon.ico") {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            self.lock.lock(); self.recorded.append(request.lowercased()); let first = self.recorded.count == 1; self.lock.unlock()
            let content = "<!doctype html><title>Hard reload</title><p>Page</p>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: max-age=3600\r\nContent-Length: \(content.utf8.count)\r\nConnection: close\r\n\r\n\(content)"
            // Later loads answer slowly, so a test can watch them in progress.
            self.queue.asyncAfter(deadline: .now()+(first ? 0 : 0.5)) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

@MainActor final class HardReloadCases {
    func tearDown() {}
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("CommandShiftRReloadsTheSelectedTabWithoutTheCache") ?? true { await liveCase("CommandShiftRReloadsTheSelectedTabWithoutTheCache") { try await self.testCommandShiftRReloadsTheSelectedTabWithoutTheCache(); self.tearDown() } }
    }
    @MainActor private func waitUntil(_ message: String, timeout: TimeInterval = 15, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor func testCommandShiftRReloadsTheSelectedTabWithoutTheCache() async throws {
        let server = try HeaderRecordingServer(); defer { server.stop() }
        try await waitUntil("HTTP fixture listening") { server.url != nil }
        let suite = "Rise.HardReloadTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), restore: false, preferences: defaults)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
            defaults.removePersistentDomain(forName: suite)
        }
        let tab = browser.addTab()
        tab.load(server.url!)
        try await waitUntil("Page loads") { server.requests.count == 1 && !tab.isLoading }
        browser.hardReload()
        try await waitUntil("Hard reload requests the page again") { server.requests.count == 2 }
        // The tab's progress stays red for the whole load, then returns to the accent.
        XCTAssertTrue(tab.isLoading); XCTAssertTrue(tab.isHardReloading)
        try await waitUntil("Hard reload finishes") { !tab.isLoading }
        try await waitUntil("Finishing clears the hard reload") { !tab.isHardReloading }
        // WebKit marks a reload from origin with no-cache, not just max-age=0 revalidation.
        let hard = server.requests[1]
        XCTAssertTrue(hard.contains("cache-control: no-cache") || hard.contains("pragma: no-cache"), hard)
    }
}

/// Rise's probe that decides whether a horizontal swipe goes back, on real pages.
@MainActor final class HistorySwipeCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        for (name, run) in [("DOMProbePreservesHorizontalContainersShadowDOMIframesAndZoom", testDOMProbePreservesHorizontalContainersShadowDOMIframesAndZoom),
                            ("PagesThatTakeTheWheelKeepTheGesture", testPagesThatTakeTheWheelKeepTheGesture)] where only?.contains(name) ?? true {
            await liveCase(name) { try await run() }
        }
    }
    private func browser() -> BrowserController {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.SwipeChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        return browser
    }
    private func clean(_ browser: BrowserController) { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
    private func page(_ html: String, in browser: BrowserController) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://example.com/swipe"))
        for _ in 0..<200 where tab.page.isLoading || tab.page.url?.host != "example.com" { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(300))
        return tab
    }
    /// The probe at `point`, in CSS pixels, as the swipe asks it.
    private func probe(_ tab: BrowserTab, _ point: NSPoint) async throws -> Bool? {
        let size = tab.page.view.bounds.size
        return try await tab.page.evaluate(HistorySwipeController.scrollProbe, arguments: ["x": point.x, "y": point.y, "width": size.width, "height": size.height],
                                           in: nil, world: .named(HistorySwipeController.worldName)) as? Bool
    }
    func testDOMProbePreservesHorizontalContainersShadowDOMIframesAndZoom() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
        <!doctype html><style>body{margin:0} .scroll{width:200px;height:100px;overflow-x:auto}
        .wide{width:1000px;height:40px}</style>
        <div class=scroll><div class=wide>Carousel</div></div>
        <div id=shadow></div><iframe style='width:200px;height:100px' srcdoc='page'></iframe>
        <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML=
        '<div style="width:200px;height:100px;overflow:auto"><div style="width:1000px">Shadow scroll</div></div>'</script>
        """, in: browser)
        for (point, allowed) in [(NSPoint(x: 40, y: 30), false), (.init(x: 40, y: 130), false),
                                 (.init(x: 40, y: 240), false), (.init(x: 400, y: 400), true)] {
            let result = try await probe(tab, point)
            XCTAssertEqual(result, allowed, "At \(point)")
        }
        tab.page.zoom = 1.5
        try await Task.sleep(for: .milliseconds(300))
        let zoomed = try await probe(tab, NSPoint(x: 40, y: 30))
        XCTAssertEqual(zoomed, false)
    }
    func testPagesThatTakeTheWheelKeepTheGesture() async throws {
        let browser = browser(); defer { clean(browser) }
        // Like Excalidraw, a canvas pans by cancelling wheel events instead of scrolling.
        let tab = try await page("""
        <!doctype html><style>body{margin:0} canvas{display:block;width:100vw;height:100vh}</style>
        <canvas></canvas><script>window.pans = 0; document.querySelector('canvas').addEventListener('wheel',
        e => { e.preventDefault(); pans++ }, {passive: false})</script>
        """, in: browser)
        let point = NSPoint(x: 400, y: 300)
        let permitted = try await probe(tab, point)
        XCTAssertEqual(permitted, true, "A page that hasn't cancelled any wheel still swipes")
        let wheel = "document.querySelector('canvas').dispatchEvent(new WheelEvent('wheel', {deltaX: -40, bubbles: true, cancelable: true}))"
        _ = try await tab.web.evaluateJavaScript(wheel)
        let panning = try await probe(tab, point)
        XCTAssertEqual(panning, false, "The page cancelled the gesture's wheel, so it pans instead")
        let pans = try await tab.web.evaluateJavaScript("pans") as? Int
        XCTAssertEqual(pans, 1)
        let hidden = try await tab.web.evaluateJavaScript("typeof window.riseWheel") as? String
        XCTAssertEqual(hidden, "undefined", "Rise's watcher stays out of the page's world")
        try await Task.sleep(for: .milliseconds(350))
        let later = try await probe(tab, point)
        XCTAssertEqual(later, true, "An old pan doesn't hold back a later swipe")
    }
}

@MainActor final class SiteSearchLearningCases {
    func tearDown() {}
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("SearchingOnASiteTeachesTheAddressBarToSearchItWithTab") ?? true { await liveCase("SearchingOnASiteTeachesTheAddressBarToSearchItWithTab") { try await self.testSearchingOnASiteTeachesTheAddressBarToSearchItWithTab(); self.tearDown() } }
        if only?.contains("ChoosingASearchBoxsShowAllResultsTeachesItsSearch") ?? true { await liveCase("ChoosingASearchBoxsShowAllResultsTeachesItsSearch") { try await self.testChoosingASearchBoxsShowAllResultsTeachesItsSearch(); self.tearDown() } }
        if only?.contains("TypingASiteFillsInTheSiteNotItsLastPage") ?? true { await liveCase("TypingASiteFillsInTheSiteNotItsLastPage") { try self.testTypingASiteFillsInTheSiteNotItsLastPage(); self.tearDown() } }
    }
    @MainActor private func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), message)
    }
    @MainActor func testSearchingOnASiteTeachesTheAddressBarToSearchItWithTab() async throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer {
            browser.hidePalette(); browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        }
        let tab = browser.addTab(), web = tab.web
        // A site that shows its results in place, as YouTube and GitHub do, with the search in the address.
        web.loadHTMLString("""
        <!doctype html><meta property="og:site_name" content="Lamp Shop"><title>Lamps</title>
        <form><input name=user value=someone><input type=search name=find><button>Search</button></form>
        <script>document.querySelector('form').addEventListener('submit', event => {
          event.preventDefault(); history.pushState({}, '', '/results/?sort=new&term=' + encodeURIComponent(event.target.find.value))
        })</script>
        """, baseURL: URL(string: "https://lamps.example/"))
        try await waitUntil("Shop loaded") { !web.isLoading && web.title == "Lamps" }
        XCTAssertNil(browser.siteSearchLearner.searches.site(forAddress: "lamps.example"))
        _ = try await web.evaluateJavaScript("document.querySelector('[name=find]').value = 'desk lamp'; document.querySelector('form').requestSubmit(); location.href")
        try await waitUntil("Learned from the search") { browser.siteSearchLearner.searches.site(forAddress: "lamps.example") != nil }
        let site = try XCTUnwrap(browser.siteSearchLearner.searches.site(forAddress: "lamps.example"))
        XCTAssertEqual(site.name, "Lamp Shop")
        XCTAssertEqual(site.searchURL(for: "floor lamp")?.absoluteString, "https://lamps.example/results/?term=floor%20lamp")

        browser.showWindow(nil); browser.newTab()
        let palette = browser.palette, editor = try XCTUnwrap(palette.input.currentEditor() as? NSTextView)
        editor.insertText("lamps.example", replacementRange: editor.selectedRange())
        XCTAssertEqual(palette.offeredSite?.name, "Lamp Shop", "The learned search is offered with Tab")
        editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(palette.siteSearch?.name, "Lamp Shop")
        editor.insertText("floor lamp", replacementRange: editor.selectedRange())
        var opened: URL?
        palette.submit = { _, suggestion in opened = suggestion?.url }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(opened?.absoluteString, "https://lamps.example/results/?term=floor%20lamp")
    }
    /// As on speedrun.com: a search box's suggestions offer a "Show all results" link, and the box
    /// closes as it's chosen. A suggestion leading elsewhere teaches nothing.
    @MainActor func testChoosingASearchBoxsShowAllResultsTeachesItsSearch() async throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer {
            browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }
            browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
        }
        let tab = browser.addTab(), web = tab.web
        let page = """
        <!doctype html><meta property="og:site_name" content="Runs"><title>Runs</title>
        <div id=box><input role=combobox autocomplete=off aria-label=Search placeholder="Search for anything..."></div>
        <div role=listbox><a role=option id=game href="/game">Jump to the game</a><a role=option id=all href="/search">Show all results</a></div>
        <script>
          const box = document.querySelector('input')
          box.addEventListener('input', () => all.href = '/search?q=' + box.value.trim().split(/ +/).map(encodeURIComponent).join('+'))
          for (const link of document.querySelectorAll('a')) link.addEventListener('pointerdown', () => document.getElementById('box').remove())
          addEventListener('click', event => { const link = event.target.closest('a'); if (!link) return
            event.preventDefault(); history.pushState({}, '', link.getAttribute('href')) })
        </script>
        """
        web.loadHTMLString(page, baseURL: URL(string: "https://runs.example/"))
        try await waitUntil("Runs loaded") { !web.isLoading && web.title == "Runs" }
        let type = "const box = document.querySelector('input'); box.value = 'gta 6'; box.dispatchEvent(new Event('input', {bubbles: true}));"
        func choose(_ id: String) -> String { "const link = document.getElementById('\(id)'); link.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true})); link.click(); location.href" }
        _ = try await web.evaluateJavaScript(type + choose("game"))
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(browser.siteSearchLearner.searches.site(forAddress: "runs.example"), "A suggestion going elsewhere teaches nothing")
        web.loadHTMLString(page, baseURL: URL(string: "https://runs.example/?again"))
        try await waitUntil("Runs loaded again") { !web.isLoading && web.url?.query == "again" }
        _ = try await web.evaluateJavaScript(type + choose("all"))
        try await waitUntil("Learned from Show all results") { browser.siteSearchLearner.searches.site(forAddress: "runs.example") != nil }
        let site = try XCTUnwrap(browser.siteSearchLearner.searches.site(forAddress: "runs.example"))
        XCTAssertEqual(site.name, "Runs")
        XCTAssertEqual(site.searchURL(for: "mario 64")?.absoluteString, "https://runs.example/search?q=mario%2064")
    }
    @MainActor func testTypingASiteFillsInTheSiteNotItsLastPage() throws {
        _ = NSApplication.shared
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false)
        defer { browser.saveWork?.cancel(); browser.window?.orderOut(nil); try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent()) }
        browser.browsingHistory.record(URL(string: "https://www.youtube.com/watch?v=Y0tR-1WUxCo")!, title: "It's Finally Happened")
        let youtube = try XCTUnwrap(browser.suggestions(for: "yout").first)
        XCTAssertEqual(youtube.completion, "youtube.com")
        XCTAssertEqual(youtube.title, "YouTube")
        browser.browsingHistory.record(URL(string: "https://szukaj.onet.pl/wyniki/?qt=atak")!, title: "atak - Szukaj w Onet.pl")
        let onet = try XCTUnwrap(browser.suggestions(for: "szu").first)
        XCTAssertEqual(onet.completion, "szukaj.onet.pl"); XCTAssertEqual(onet.url, URL(string: "https://szukaj.onet.pl/"))
        XCTAssertTrue(onet.isTypedAction)
        XCTAssertEqual(browser.suggestions(for: "youtube.com/w").first?.completion, "youtube.com/watch?v=Y0tR-1WUxCo")
    }
}

/// What Page Assistant reads of a page.
@MainActor final class PageAssistantCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("AssistantSeesCodeThatGitHubDrawsFromAttributes") ?? true {
            await liveCase("AssistantSeesCodeThatGitHubDrawsFromAttributes") { try await testAssistantSeesCodeThatGitHubDrawsFromAttributes() }
        }
    }
    func testAssistantSeesCodeThatGitHubDrawsFromAttributes() async throws {
        // Like GitHub's file view: the lines are empty spans painted from an attribute,
        // under a transparent aria-readonly text area, inside display: contents wrappers.
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.AssistantChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <style>[data-code-text]::before{content:attr(data-code-text)} textarea{color:transparent;background:none}</style>
        <h1>1-4</h1>
        <div style="display:contents"><div style="display:contents">
        <textarea aria-readonly="true">int main ()\n{\n    printf("%6.1f", celsius);\n}</textarea></div></div>
        <div style="display:contents"><p>Wrapped paragraph</p></div>
        <div><span data-code-text="int main ()"></span></div><div><span data-code-text="printf"></span></div>
        <textarea>a draft comment</textarea>
        """, baseURL: URL(string: "https://github.com/a/b/blob/master/1-4"))
        for _ in 0..<100 where web.isLoading || web.url?.host != "github.com" { try await Task.sleep(nanoseconds: 50_000_000) }
        let page = try await PageAssistant.snapshot(of: tab.page)
        XCTAssertTrue(page.text.contains("1-4"), page.text)
        XCTAssertTrue(page.text.contains("printf(\"%6.1f\", celsius);"), page.text)
        XCTAssertTrue(page.text.contains("Wrapped paragraph"), page.text)
        XCTAssertFalse(page.text.contains("a draft comment"), page.text)
    }
}

/// The scripts Gmail's card reads the inbox with, on a page made like Gmail's.
@MainActor final class GmailReaderCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("ExtractionOnlyIncludesMailTextAndPagingState") ?? true {
            await liveCase("ExtractionOnlyIncludesMailTextAndPagingState") { try await testExtractionOnlyIncludesMailTextAndPagingState() }
        }
    }
    func testExtractionOnlyIncludesMailTextAndPagingState() async throws {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.GmailChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <table><tr class="zA zE"><td class="yW"><span email="a@example.com" name="Alice">Ali…</span></td>
        <td><span class="bog"><span data-legacy-thread-id="abcdef">Subject &amp; details</span><img alt="image"></span>
        <span class="y2"><span class="Zt"> - </span>Hello <b>there</b><img alt="ignored"><span aria-hidden="true">hidden</span>!\u{200b} More text.</span></td></tr></table>
        <div role="button" id="older"><img class="amJ"></div>
        <script>older.onclick = () => older.setAttribute('aria-disabled', 'true')</script>
        """, baseURL: URL(string: "https://mail.google.com/mail/u/0/#search/in%3Ainbox+category%3Aupdates"))
        for _ in 0..<200 where web.isLoading || web.url?.host != "mail.google.com" { try await Task.sleep(for: .milliseconds(25)) }
        // As the reader runs them: in Rise's own world, and the pop-out in the page's.
        func reader(_ script: String) async throws -> Any? {
            try await tab.page.evaluate("return " + script, arguments: [:], in: nil, world: .named(GmailPageReader.world))
        }
        let snapshot = try await reader(GmailPageReader.snapshot)
        let raw = try XCTUnwrap(snapshot as? [String: Any])
        let page = try JSONDecoder().decode(GmailPage.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(page.emails, [GmailEmail(id: "abcdef", sender: "Alice", subject: "Subject & details", preview: "Hello there! More text.", unread: true)])
        XCTAssertTrue(page.hasMore); XCTAssertEqual(raw["ready"] as? Bool, true)
        XCTAssertEqual(raw["query"] as? String, "in:inbox category:updates")
        _ = try await web.evaluateJavaScript("window.shifted = []; document.querySelector('tr.zA').addEventListener('click', e => shifted.push(e.shiftKey)); 0")
        let popped = try await web.evaluateJavaScript(GmailPageReader.popOut("abcdef")) as? Bool
        XCTAssertEqual(popped, true)
        let shifted = try await web.evaluateJavaScript("JSON.stringify(window.shifted)") as? String
        XCTAssertEqual(shifted, "[true]", "Gmail gets one shift-click on the conversation's row")
        let missing = try await web.evaluateJavaScript(GmailPageReader.popOut("123456")) as? Bool
        XCTAssertEqual(missing, false, "No row, no click")
        let advanced = try await reader(GmailPageReader.nextPage) as? Bool
        XCTAssertEqual(advanced, true)
        let stopped = try await reader(GmailPageReader.nextPage) as? Bool
        XCTAssertEqual(stopped, false)
        _ = try await web.evaluateJavaScript("document.body.innerHTML = '<div class=ae4><div class=TC>No conversations found.</div></div>'; 0")
        let empty = try await reader(GmailPageReader.snapshot) as? [String: Any]
        XCTAssertEqual(empty?["ready"] as? Bool, true, "An empty category finishes loading")
        XCTAssertEqual(empty?["hasMore"] as? Bool, false)
    }
}

/// The scripts Proton Mail's card reads the inbox and opens an email with, on a page made like Proton's.
@MainActor final class ProtonMailReaderCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("ProtonListReadsSendersSubjectsAndPages") ?? true {
            await liveCase("ProtonListReadsSendersSubjectsAndPages") { try await testProtonListReadsSendersSubjectsAndPages() }
        }
    }
    func testProtonListReadsSendersSubjectsAndPages() async throws {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.ProtonMailChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <div data-shortcut-target="item-container" data-element-id="Ab_c-1==" class="item-container unread"><div class="item-senders">
        <span data-testid="message-column:sender-address"><span title="a@example.com" data-testid="message-column:sender-address">Alice\u{200b}</span></span>,
        <span data-testid="message-column:sender-address"><span title="b@example.com" data-testid="message-column:sender-address">Bob</span></span></div>
        <time>7:05 PM</time><span data-testid="message-column:subject" title="Subject &amp; details">Subject &amp; details</span></div>
        <div data-shortcut-target="item-container" data-element-id="bad/id"><span data-testid="message-column:subject">Skipped</span></div>
        <button data-testid="toolbar:next-page" id="next">Next page</button>
        <script>
        next.onclick = () => { history.pushState({}, '', location.pathname + '#category=primary&page=2'); next.disabled = true };
        addEventListener('popstate', () => document.body.dataset.opened = location.pathname);
        </script>
        """, baseURL: URL(string: "https://mail.proton.me/u/1/inbox#category=primary"))
        for _ in 0..<200 where web.isLoading || web.url?.host != "mail.proton.me" { try await Task.sleep(for: .milliseconds(25)) }
        func reader(_ script: String) async throws -> Any? {
            try await tab.page.evaluate("return " + script, arguments: [:], in: nil, world: .named(ProtonMailPageReader.world))
        }
        let snapshot = try await reader(ProtonMailPageReader.snapshot)
        let raw = try XCTUnwrap(snapshot as? [String: Any])
        let page = try JSONDecoder().decode(GmailPage.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(page.emails, [GmailEmail(id: "Ab_c-1==", sender: "Alice, Bob", subject: "Subject & details", preview: "", unread: true)])
        XCTAssertTrue(page.hasMore); XCTAssertEqual(raw["ready"] as? Bool, true); XCTAssertEqual(raw["page"] as? Int, 1)
        let advanced = try await reader(ProtonMailPageReader.nextPage) as? Bool
        XCTAssertEqual(advanced, true)
        let second = try await reader(ProtonMailPageReader.snapshot) as? [String: Any]
        XCTAssertEqual(second?["page"] as? Int, 2); XCTAssertEqual(second?["hasMore"] as? Bool, false)
        let stopped = try await reader(ProtonMailPageReader.nextPage) as? Bool
        XCTAssertEqual(stopped, false)
        // Opening goes through Proton's own router, from Rise's world, without a reload.
        let opened = try await tab.page.evaluate(ProtonMailPageReader.open, arguments: ["route": "/u/1/inbox/Ab_c-1=="], in: nil,
                                                 world: .named(ProtonMailPageReader.world)) as? Bool
        XCTAssertEqual(opened, true)
        let route = try await web.evaluateJavaScript("document.body.dataset.opened") as? String
        XCTAssertEqual(route, "/u/1/inbox/Ab_c-1==", "Proton hears the change of route")
        let loading = try await reader(ProtonMailPageReader.snapshot) as? [String: Any]
        XCTAssertEqual(loading?["ready"] as? Bool, false, "An open conversation isn't the inbox's list")
        _ = try await web.evaluateJavaScript("history.pushState({}, '', '/u/1/inbox'); document.body.innerHTML = '<h3 data-testid=\"empty-view-placeholder--empty-title\">No messages found</h3>'; 0")
        let empty = try await reader(ProtonMailPageReader.snapshot) as? [String: Any]
        XCTAssertEqual(empty?["ready"] as? Bool, true, "An empty inbox finishes loading")
        XCTAssertEqual(empty?["hasMore"] as? Bool, false)
        _ = try await web.evaluateJavaScript("document.body.innerHTML = '<div class=item-is-loading></div>'; 0")
        let app = try await tab.page.evaluate(ProtonMailPageReader.open, arguments: ["route": "/u/1/inbox/x"], in: nil,
                                              world: .named(ProtonMailPageReader.world)) as? Bool
        XCTAssertEqual(app, false, "Until Proton shows its mailbox, the tab loads the email instead")
    }
}

/// The scripts Google Calendar's card reads and opens events with, on a page made like Calendar's
/// day view: a column of 60-point hours under a 1-point border, chips placed by their style as Calendar
/// places them, and an all-day row above.
@MainActor final class CalendarReaderCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("ChipsAreReadFromTheDayViewAndOpenedWithAClick") ?? true {
            await liveCase("ChipsAreReadFromTheDayViewAndOpenedWithAClick") { try await testChipsAreReadFromTheDayViewAndOpenedWithAClick() }
        }
    }
    func testChipsAreReadFromTheDayViewAndOpenedWithAClick() async throws {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.CalendarChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <style>body { margin: 0 } .scroll { height: 400px; overflow: auto; position: relative }
        .BiKU4b { position: relative; height: 1440px; border-top: 1px solid #dadce0 } [data-eventchip] { position: absolute; left: 0; width: 90% }</style>
        <header><button jsname="P6mm8" id="today">Today</button><button jsname="OCpkoe" id="next">Next day</button></header>
        <div role="row"><div role="gridcell" class="qLWd9c" style="height: 24px; position: relative">
          <div data-eventchip data-eventid="QUxMREFZ" style="border-color: rgb(11, 128, 67); top: 0">
            <div role="button" style="background-color: rgb(11, 128, 67)"><span class="WBi6vc">Bank holiday</span>
            <span class="XuJrye">All day, Bank holiday, Holidays in United Kingdom, 18 October 2026</span></div></div></div></div>
        <div class="scroll"><div role="gridcell" data-datekey="29010" class="BiKU4b">
          <div role="button" data-eventchip data-eventid="VEVTVElORw" style="top: 629px; height: 58px; background-color: rgb(158, 105, 175); border-color: rgb(158, 105, 175)">
            <div class="XuJrye">10:30am to 11:30am, testing event in rise, Bartek Bak, No location, 18 October 2026</div>
            <div aria-hidden="true"><span class="I0UMhf">testing event in rise</span><div>10:30 – 11:30am</div></div>
            <div aria-hidden="true" class="leOeGd" data-eventid="VEVTVElORw"></div></div>
          <div role="button" data-eventchip data-eventid="VElOWQ" style="top: 899px; height: 13px; background-color: rgb(242, 179, 179); border-color: rgb(234, 128, 128)">
            <div class="XuJrye">3pm to 3:05pm, Tiny, Bartek Bak, No location, 18 October 2026</div><span class="I0UMhf">Tiny</span></div>
        </div></div>
        <script>
          window.opened = [];
          for (const chip of document.querySelectorAll('[data-eventchip]'))
            (chip.matches('[role=button]') ? chip : chip.querySelector('[role=button]')).addEventListener('click', () => opened.push(chip.dataset.eventid));
          next.onclick = () => document.querySelector('[data-datekey]').setAttribute('data-datekey', '29011');
        </script>
        """, baseURL: URL(string: "https://calendar.google.com/calendar/u/0/r/day/2026/10/18"))
        for _ in 0..<200 where web.isLoading || web.url?.host != "calendar.google.com" { try await Task.sleep(for: .milliseconds(25)) }
        func reader(_ script: String) async throws -> Any? {
            try await tab.page.evaluate("return " + script, arguments: [:], in: nil, world: .named(CalendarPageReader.world))
        }
        let snapshot = try await reader(CalendarPageReader.snapshot)
        let raw = try XCTUnwrap(snapshot as? [String: Any])
        XCTAssertEqual(raw["ready"] as? Bool, true)
        let day = try JSONDecoder().decode(CalendarDay.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(day.key, 29010); XCTAssertEqual(day.height, 1441)
        XCTAssertEqual(day.chips.map(\.id), ["QUxMREFZ", "VEVTVElORw", "VElOWQ"], "Each chip once, not its resize handle")
        XCTAssertEqual(day.chips.map(\.title), ["Bank holiday", "testing event in rise", "Tiny"])
        XCTAssertEqual(day.chips.map(\.allDay), [true, false, false])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let events = CalendarSchedule.events([day], calendar: calendar)
        let minutes = events.map { [$0.start, $0.end].map { Int($0.timeIntervalSince(calendar.date(from: day.date)!)/60) } }
        XCTAssertEqual(minutes, [[0, 1440], [630, 690], [900, 905]])
        XCTAssertEqual(events.map(\.color), [0x0B8043, 0x9E69AF, 0xD50101])
        let opened = try await reader(CalendarPageReader.open("VEVTVElORw")) as? Bool
        XCTAssertEqual(opened, true)
        let allDay = try await reader(CalendarPageReader.open("QUxMREFZ")) as? Bool
        XCTAssertEqual(allDay, true)
        let clicks = try await web.evaluateJavaScript("JSON.stringify(window.opened)") as? String
        XCTAssertEqual(clicks, #"["VEVTVElORw","QUxMREFZ"]"#, "One click on each chip's button")
        let missing = try await reader(CalendarPageReader.open("TUlTU0lORw")) as? Bool
        XCTAssertEqual(missing, false, "No chip, no click")
        let stepped = try await reader(CalendarPageReader.step(CalendarPageReader.nextButton)) as? Bool
        XCTAssertEqual(stepped, true)
        let tomorrow = try await reader(CalendarPageReader.snapshot) as? [String: Any]
        XCTAssertEqual(tomorrow?["key"] as? Int, 29011)
    }
}

/// Someone's day, from Schedule 1:1 in Google's profile card, which Chat holds in a frame of
/// contacts.google.com, read from Calendar's API at clients6.google.com.
@MainActor final class PersonCalendarCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("ScheduleOneToOneShowsTheirDayOutOfTheButtonsCorner") ?? true {
            await liveCase("ScheduleOneToOneShowsTheirDayOutOfTheButtonsCorner") { try await testScheduleOneToOneShowsTheirDayOutOfTheButtonsCorner() }
        }
    }
    func testScheduleOneToOneShowsTheirDayOutOfTheButtonsCorner() async throws {
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: "Rise.PersonCalendarChecks.\(UUID().uuidString)")!)
        browser.window?.setFrameAutosaveName(""); browser.window?.setFrame(NSRect(x: 0, y: 0, width: 1300, height: 900), display: true)
        browser.window?.center(); browser.showWindow(nil)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let today = Calendar.current.startOfDay(for: Date()), format = ISO8601DateFormatter()
        func at(_ hour: Double) -> String { format.string(from: today.addingTimeInterval(hour*3600)) }
        // Busy only, but for a meeting you're invited to, and one in full.
        try LiveFixtures.register(#"{"accessRole": "freeBusyReader", "items": [{"id": "standup", "start": {"dateTime": "\#(at(10))"}, "end": {"dateTime": "\#(at(11))"}}, {"id": "busy", "start": {"dateTime": "\#(at(12))"}, "end": {"dateTime": "\#(at(13))"}}, {"id": "office", "summary": "Office", "eventType": "workingLocation", "start": {"date": "2026-01-01"}, "end": {"date": "2026-01-02"}}]}"#,
                                  at: URL(string: "https://clients6.google.com/calendar/v3/calendars/dkezi%40example.com/events")!)
        try LiveFixtures.register(#"{"items": [{"id": "standup", "summary": "Stand-up", "start": {"dateTime": "\#(at(10))"}, "end": {"dateTime": "\#(at(11))"}}]}"#,
                                  at: URL(string: "https://clients6.google.com/calendar/v3/calendars/primary/events")!)
        let card = "https://contacts.google.com/widget/hovercard/v/2?hl=en&origin=https%3A%2F%2Fchat.google.com"
        try LiveFixtures.register("""
        <!doctype html><body style="margin: 0; font: 14px system-ui">
        <div jsname="a4WWq" data-email="DKezi@example.com">David Kezi</div>
        <button jsname="LyTtqb" jslog="133090; track:click" data-tooltip-id="tt-c16" aria-label="Schedule 1:1"
          style="position: absolute; left: 288px; top: 100px; width: 40px; height: 40px; border-radius: 50%; border: 0; padding: 0"><svg width="20" height="20"></svg></button>
        <div id="tt-c16" style="position: absolute; left: 260px; top: 146px">Schedule 1:1</div>
        </body>
        """, at: URL(string: card)!)
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <!doctype html><body style="margin: 0"><h1>Home</h1>
        <iframe name="I__HC_1" src="\(card)" style="position: absolute; left: 300px; top: 200px; width: 340px; height: 274px; border: 0"></iframe>
        <script>document.cookie = 'SAPISID=fixture; Secure; path=/';</script>
        """, baseURL: URL(string: "https://chat.google.com/u/0/app/home"))
        for _ in 0..<200 where web.isLoading || web.url?.host != "chat.google.com" { try await Task.sleep(for: .milliseconds(25)) }
        try await Task.sleep(for: .milliseconds(500))
        func wait(_ seconds: Double = 5, _ ready: () async -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !(await ready()), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
            return await ready()
        }
        let cards = browser.personCalendars
        _ = await tab.page.devTools("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 100, "y": 100])
        _ = await tab.page.devTools("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 608, "y": 320])
        let shown = await wait { cards.shown == CalendarPerson(email: "dkezi@example.com", authUser: 0) && !cards.card.isHidden }
        XCTAssertTrue(shown, "Resting on Schedule 1:1 shows their day")
        var button = NSRect(x: 588, y: 300, width: 40, height: 40)
        if !web.isFlipped { button.origin.y = web.bounds.height-button.maxY }
        button = web.convert(button, to: browser.root)
        XCTAssertEqual(cards.buttonFrame.minX, button.minX, accuracy: 1); XCTAssertEqual(cards.buttonFrame.minY, button.minY, accuracy: 1)
        XCTAssertEqual(cards.card.frame.minX, button.maxX, accuracy: 1, "Its left edge at the button's right")
        XCTAssertEqual(cards.card.frame.minY, button.maxY, accuracy: 1, "Its top at the button's foot")
        let read = await wait { cards.card.chips.count == 2 }
        XCTAssertTrue(read, "Both timed events, not where they work")
        XCTAssertEqual(cards.card.chips.map(\.event.title), ["Stand-up", "Busy"], "Your own title for a meeting you share with them")
        XCTAssertEqual(cards.card.chips.map(\.event.color), [0xF09300, 0xF09300])
        func tooltip() async -> String? {
            guard let frame = cards.shownFrame else { return nil }
            return try? await tab.page.evaluate("return getComputedStyle(document.getElementById('tt-c16')).visibility", arguments: [:],
                                                in: frame, world: .named(PersonCalendarScript.world)) as? String
        }
        let quiet = await wait { await tooltip() == "hidden" }
        XCTAssertTrue(quiet, "The button's own tooltip doesn't show half under the card")
        let frame = try XCTUnwrap(cards.shownFrame)
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                                     windowNumber: browser.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        browser.personCalendarPagePressed(press)
        XCTAssertNil(cards.shown, "A press on the page closes it")
        let back = await wait {
            (try? await tab.page.evaluate("return getComputedStyle(document.getElementById('tt-c16')).visibility", arguments: [:],
                                          in: frame, world: .named(PersonCalendarScript.world)) as? String) == "visible"
        }
        XCTAssertTrue(back, "And the button's tooltip is its own again")
    }
}

/// Rise's full-screen script, in a Rise tab.
@MainActor final class PageFullscreenCases {
    private var suites: [String] = []
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        for (name, run) in [("SimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly", testSimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly),
                            ("NativeModeLeavesTheFullscreenAPIToChromium", testNativeModeLeavesTheFullscreenAPIToChromium),
                            ("ScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser", testScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser),
                            ("SwitchingModesChangesTheScriptForLaterPages", testSwitchingModesChangesTheScriptForLaterPages)]
        where only?.contains(name) ?? true {
            await liveCase(name) { try await run() }
            suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }; suites = []
        }
    }
    private func browser(simulated: Bool) -> BrowserController {
        let suite = "Rise.FullscreenChecks.\(UUID().uuidString)"; suites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(simulated, forKey: PageFullscreen.simulatedKey)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        return browser
    }
    private func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    private func page(in browser: BrowserController) async throws -> NSView {
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <style> #box:fullscreen { outline: 3px solid rgb(0, 128, 0) } .wrap { transform: scale(0.5); overflow: hidden; width: 300px; height: 200px } </style>
        <div class=wrap><div id=box style="width:100px;height:50px">box</div></div>
        <script> window.events = []; document.addEventListener('fullscreenchange', () => events.push(document.fullscreenElement?.id || 'null')); </script>
        """, baseURL: URL(string: "https://fullscreen.example/"))
        for _ in 0..<200 {
            if !web.isLoading, web.url?.host == "fullscreen.example", (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        return web
    }
    private func value(_ web: NSView, _ source: String) async throws -> String {
        let result = try await web.evaluateJavaScript(source)
        return result.map { "\($0)" } ?? "nil"
    }

    func testSimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly() async throws {
        let browser = browser(simulated: true); defer { clean(browser) }
        let web = try await page(in: browser)
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let size = try await value(web, "[innerWidth, innerHeight].join()")
        let rect = try await value(web, "const r = box.getBoundingClientRect(); [r.left, r.top, r.width, r.height].join()")
        XCTAssertEqual(rect, "0,0,\(size)", "A transformed, clipped ancestor can't hold the element back")
        let element = try await value(web, "document.fullscreenElement.id")
        XCTAssertEqual(element, "box")
        let outline = try await value(web, "getComputedStyle(box).outlineColor")
        XCTAssertEqual(outline, "rgb(0, 128, 0)", "The page's :fullscreen rule applies")
        XCTAssertFalse(browser.window?.styleMask.contains(.fullScreen) == true, "The window stays as it was")
        _ = try await web.evaluateJavaScript("document.exitFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let events = try await value(web, "events.join()")
        XCTAssertEqual(events, "box,null")
        let leftovers = try await value(web, "document.querySelectorAll('[data-rise-fullscreen], [data-rise-fullscreen-ancestor], [popover]').length")
        XCTAssertEqual(leftovers, "0")
    }

    func testNativeModeLeavesTheFullscreenAPIToChromium() async throws {
        let browser = browser(simulated: false); defer { clean(browser) }
        let web = try await page(in: browser)
        let simulated = try await value(web, "String(window.__riseFullscreen.simulated)")
        XCTAssertEqual(simulated, "false")
        // Long after the script's click, which Chromium honours for 5 s, so it refuses rather
        // than taking over the screen.
        _ = try await web.evaluateJavaScript("setTimeout(() => box.requestFullscreen().catch(e => window.refused = e.name), 5500); 0")
        try await Task.sleep(for: .milliseconds(6000))
        let refused = try await value(web, "window.refused")
        XCTAssertEqual(refused, "TypeError", "Chromium's own requestFullscreen answered")
        let pinned = try await value(web, "document.querySelectorAll('[data-rise-fullscreen]').length")
        XCTAssertEqual(pinned, "0", "Native mode never pins the element itself")
    }

    func testScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser() async throws {
        let browser = browser(simulated: true); defer { clean(browser) }
        let fullscreen = browser.pageFullscreen
        let web = try await page(in: browser)
        var changes: [Bool] = []
        let previous = fullscreen.onChange
        fullscreen.onChange = { previous?(); changes.append(fullscreen.isActive(in: web)) }
        defer { fullscreen.onChange = previous }
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fullscreen.isActive(in: web))
        _ = try await web.evaluateJavaScript("const next = document.createElement('div'); next.id = 'next'; document.body.append(next); next.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, [true], "Replacing the element must not briefly reopen the sidebar")
        _ = try await web.evaluateJavaScript("document.exitFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, [true, false])
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript("box.remove(); 0")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testSwitchingModesChangesTheScriptForLaterPages() async throws {
        let browser = browser(simulated: false); defer { clean(browser) }
        XCTAssertFalse(browser.pageFullscreen.isSimulated, "Simulated fullscreen is off unless chosen")
        let web = try await page(in: browser)
        let before = try await value(web, "String(window.__riseFullscreen.simulated)")
        XCTAssertEqual(before, "false")
        browser.pageFullscreen.setSimulated(true, in: browser.tabs.map(\.page))
        let reloaded = try await page(in: browser)
        let after = try await value(reloaded, "String(window.__riseFullscreen.simulated) + ' ' + document.querySelectorAll('script').length")
        XCTAssertEqual(after, "true 1", "Later pages get the simulated script, once")
    }
}
@MainActor final class VideoPictureInPictureCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("AnySitesVideoWithSoundFloatsAndReturnsUntouched") ?? true { await liveCase("AnySitesVideoWithSoundFloatsAndReturnsUntouched") { try await self.testAnySitesVideoWithSoundFloatsAndReturnsUntouched(); self.tearDown() } }
        if only?.contains("MutedPausedAndBlockedVideosStayInline") ?? true { await liveCase("MutedPausedAndBlockedVideosStayInline") { try await self.testMutedPausedAndBlockedVideosStayInline(); self.tearDown() } }
        if only?.contains("VideoInAFrameFloatsWithItsFrameLiftedAndPutBack") ?? true { await liveCase("VideoInAFrameFloatsWithItsFrameLiftedAndPutBack") { try await self.testVideoInAFrameFloatsWithItsFrameLiftedAndPutBack(); self.tearDown() } }
        if only?.contains("VideoTwoFramesDownFloats") ?? true { await liveCase("VideoTwoFramesDownFloats") { try await self.testVideoTwoFramesDownFloats(); self.tearDown() } }
        if only?.contains("VideoInAShadowRootFloats") ?? true { await liveCase("VideoInAShadowRootFloats") { try await self.testVideoInAShadowRootFloats(); self.tearDown() } }
        if only?.contains("RemovingTheFloatingFramePutsThePageBack") ?? true { await liveCase("RemovingTheFloatingFramePutsThePageBack") { try await self.testRemovingTheFloatingFramePutsThePageBack(); self.tearDown() } }
        if only?.contains("TheFrameHeardLastFloatsAndPausingInThePictureReachesIt") ?? true { await liveCase("TheFrameHeardLastFloatsAndPausingInThePictureReachesIt") { try await self.testTheFrameHeardLastFloatsAndPausingInThePictureReachesIt(); self.tearDown() } }
        if only?.contains("MinimizingLeavesNoOtherPictureBehind") ?? true { await liveCase("MinimizingLeavesNoOtherPictureBehind") { try await self.testMinimizingLeavesNoOtherPictureBehind(); self.tearDown() } }
        if only?.contains("AFrameNavigatingAwayWhileFloatingPutsThePageBack") ?? true { await liveCase("AFrameNavigatingAwayWhileFloatingPutsThePageBack") { try await self.testAFrameNavigatingAwayWhileFloatingPutsThePageBack(); self.tearDown() } }
        if only?.contains("SandboxedFrameFloats") ?? true { await liveCase("SandboxedFrameFloats") { try await self.testSandboxedFrameFloats(); self.tearDown() } }
        if only?.contains("AFrameInAHiddenContainerStaysInline") ?? true { await liveCase("AFrameInAHiddenContainerStaysInline") { try await self.testAFrameInAHiddenContainerStaysInline(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.VideoPiPTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil); browser.pictureInPicture.reduceMotion = { true }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.pictureInPicture.tearDown(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "VideoPiPTests", code: 1)
    }
    private func videoSource() throws -> String {
        let file = LiveFixtures.repository("Tests/RiseTests/Resources/PiPTestVideo.mp4")
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    /// A page whose `playing` expression turns true once its video plays.
    @MainActor private func page(_ html: String, in browser: BrowserController, playing: String) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString("<!doctype html><title>Video</title><body style='margin:0;background:rgb(144,80,64)'>\(html)",
                                   baseURL: URL(string: "https://videos.example/"))
        try await wait("video plays") {
            guard !tab.web.isLoading else { return false }
            return try await tab.web.evaluateJavaScript("(() => { try { return \(playing) } catch { return false } })()") as? Bool == true
        }
        return tab
    }
    @MainActor private func value(_ script: String, in tab: BrowserTab) async throws -> Any? { try await tab.web.evaluateJavaScript(script) }

    @MainActor private func picture(in tab: BrowserTab, panel: FloatingVideoWindow) async throws -> Data {
        let image = try await tab.web.takeSnapshot(rect: panel.videoHost.bounds)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8,
                bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return Data(bytes)
    }
    /// The window shows the moving video, not the page around it.
    @MainActor private func assertShowsVideo(_ tab: BrowserTab, _ panel: FloatingVideoWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        let first = try await picture(in: tab, panel: panel)
        func near(_ index: Int, _ value: Int) -> Bool { abs(Int(first[index])-value) < 6 }
        let pageColor = stride(from: 0, to: first.count, by: 4).filter { (i: Int) -> Bool in near(i, 144) && near(i+1, 80) && near(i+2, 64) }
        XCTAssertLessThan(pageColor.count, 8, "The page's own background shows in the picture", file: file, line: line)
        let frames = panel.renderedFrameCount
        // Long enough for the clip's clock to move, which is most of what changes between frames.
        try await wait("the picture advances") { panel.renderedFrameCount > frames+30 }
        let later = try await picture(in: tab, panel: panel)
        XCTAssertNotEqual(first, later, "The picture moves with the video", file: file, line: line)
    }
    @MainActor private func floatAway(_ tab: BrowserTab, in browser: BrowserController) async throws -> FloatingVideoWindow {
        _ = browser.addTab()
        try await wait("the video floats") { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.hasVideoFrame == true }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, tab.id)
        XCTAssertTrue(tab.web.window === browser.pictureInPicture.panel)
        return try XCTUnwrap(browser.pictureInPicture.panel)
    }
    @MainActor private func returnHome(_ tab: BrowserTab, in browser: BrowserController) async throws {
        browser.pictureInPicture.returnToTab()
        try await wait("the page is back in its tab") { browser.pictureInPicture.panel == nil && tab.web.superview === browser.pageClip }
    }

    @MainActor func testAnySitesVideoWithSoundFloatsAndReturnsUntouched() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("<p id=original>Article</p><video id=v loop autoplay playsinline style='width:320px;height:180px' src='\(try videoSource())'></video>",
                                 in: browser, playing: "v.currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let playing = try await value("!v.paused", in: tab) as? Bool
        XCTAssertEqual(playing, true, "It keeps playing through the return")
        let canvases = try await value("document.querySelectorAll('canvas').length", in: tab) as? Int
        XCTAssertEqual(canvases, 0)
        let style = try await value("v.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, "width:320px;height:180px")
    }

    @MainActor func testMutedPausedAndBlockedVideosStayInline() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let muted = try await page("<video id=v muted loop autoplay playsinline src='\(source)'></video>", in: browser, playing: "v.currentTime > 0.1")
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "A muted video stays a background loop")

        // Unmuting it while it plays counts as sound.
        browser.select(muted.id)
        _ = try await value("v.muted = false; 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        _ = browser.addTab()
        try await wait("the unmuted video floats") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.pictureInPicture.returnToTab()
        try await wait("back") { browser.pictureInPicture.panel == nil }

        _ = try await value("v.pause(); 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "A paused video stays")

        browser.select(muted.id)
        _ = try await value("v.play(); 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        browser.sitePermissions.setAutomaticPictureInPicture(false, origin: try XCTUnwrap(SitePermissions.origin(muted.url)))
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "The site's Automatic Picture-In-Picture setting is respected")
    }

    @MainActor func testVideoInAFrameFloatsWithItsFrameLiftedAndPutBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let frameStyle = "width:320px;height:180px;border:3px solid red;transform:scale(0.7);margin:200px 0 0 300px"
        let tab = try await page("""
          <div style="overflow:hidden;width:200px;height:100px;position:relative;z-index:1">
          <iframe id=frame style="\(frameStyle)" srcdoc='<body style="margin:0;background:rgb(144,80,64)"><video loop autoplay playsinline style="width:100%" src="\(try videoSource())"></video>'></iframe>
          </div><div style="position:fixed;inset:0;z-index:999;background:rgba(144,80,64,1);pointer-events:none"></div>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("frame.matches(':popover-open')", in: tab) as? Bool
        XCTAssertEqual(lifted, true, "The frame is lifted over its clipped, covered page")
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let style = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, frameStyle, "The frame's own style is back exactly")
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false)
        let playing = try await value("!frame.contentDocument.querySelector('video').paused", in: tab) as? Bool
        XCTAssertEqual(playing, true)
        let canvases = try await value("frame.contentDocument.querySelectorAll('canvas').length", in: tab) as? Int
        XCTAssertEqual(canvases, 0)

        // Again, so a second float finds the frame as it was.
        let again = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, again)
        try await returnHome(tab, in: browser)
        let styleAgain = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(styleAgain, frameStyle)
    }

    @MainActor func testVideoTwoFramesDownFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let inner = "<body style=&quot;margin:0&quot;><video loop autoplay playsinline src=&quot;\(try videoSource())&quot;></video>"
        let tab = try await page("""
          <iframe id=outer style="width:400px;height:300px" srcdoc="<body style='margin:0'><iframe id=inner style='width:320px;height:180px' srcdoc='\(inner)'></iframe>"></iframe>
          """, in: browser, playing: "outer.contentDocument.querySelector('#inner').contentDocument.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("[outer.matches(':popover-open'), outer.contentDocument.querySelector('#inner').matches(':popover-open')].join()", in: tab) as? String
        XCTAssertEqual(lifted, "true,true", "Each frame on the way down is lifted")
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let after = try await value("[outer.hasAttribute('popover'), outer.contentDocument.querySelector('#inner').hasAttribute('popover'), outer.getAttribute('style')].join()", in: tab) as? String
        XCTAssertEqual(after, "false,false,width:400px;height:300px")
    }

    @MainActor func testVideoInAShadowRootFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <rise-player id=host></rise-player>
          <script>
          host.attachShadow({mode:'open'}).innerHTML = '<video loop autoplay playsinline src="\(try videoSource())"></video>';
          </script>
          """, in: browser, playing: "host.shadowRoot.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
    }

    @MainActor func testRemovingTheFloatingFramePutsThePageBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <iframe id=frame style="width:320px;height:180px" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        _ = try await value("frame.remove(); 0", in: tab)
        try await wait("the picture closes with its frame") { browser.pictureInPicture.panel == nil }
        XCTAssertNil(tab.web.window, "The page goes back to its hidden tab")
    }

    @MainActor func testTheFrameHeardLastFloatsAndPausingInThePictureReachesIt() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <video id=page loop autoplay playsinline style="width:160px" src="\(source)"></video>
          <iframe id=frame style="width:320px;height:180px" srcdoc='<video loop playsinline src="\(source)"></video>'></iframe>
          """, in: browser, playing: "page.currentTime > 0.1")
        _ = try await value("page.pause(); frame.contentDocument.querySelector('video').play(); 0", in: tab)
        try await wait("frame plays") { try await self.value("frame.contentDocument.querySelector('video').currentTime > 0.2", in: tab) as? Bool == true }
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("frame.matches(':popover-open')", in: tab) as? Bool
        XCTAssertEqual(lifted, true, "The playing frame floats, not the page's paused video")
        panel.onTogglePlayback?()
        try await wait("the frame's video pauses") { try await self.value("frame.contentDocument.querySelector('video').paused", in: tab) as? Bool == true }
        let pagePaused = try await value("page.paused", in: tab) as? Bool
        XCTAssertEqual(pagePaused, true)
        panel.onTogglePlayback?()
        try await wait("and plays") { try await self.value("frame.contentDocument.querySelector('video').paused", in: tab) as? Bool == false }
    }

    @MainActor func testMinimizingLeavesNoOtherPictureBehind() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("<video id=v loop autoplay playsinline src='\(try videoSource())'></video>", in: browser, playing: "v.currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        browser.pictureInPicture.minimizeVideo()
        try await wait("hidden") { browser.pictureInPicture.panel == nil }
        try await Task.sleep(for: .milliseconds(400))
        let mode = try await value("[document.pictureInPictureElement ? 'picture-in-picture' : 'inline', !v.paused].join()", in: tab) as? String
        XCTAssertEqual(mode, "inline,true", "It keeps playing in its tab without Chromium's own picture in picture")
    }

    @MainActor func testAFrameNavigatingAwayWhileFloatingPutsThePageBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let frameStyle = "width:320px;height:180px"
        let tab = try await page("""
          <iframe id=frame style="\(frameStyle)" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        _ = try await value("frame.srcdoc = '<p>Next</p>'; 0", in: tab)
        try await wait("the picture closes as its frame moves on") { browser.pictureInPicture.panel == nil }
        try await wait("the frame is put back") { try await self.value("frame.hasAttribute('popover')", in: tab) as? Bool == false }
        let style = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, frameStyle)
    }

    @MainActor func testSandboxedFrameFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <iframe id=frame sandbox="allow-scripts" style="width:320px;height:180px" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "true")
        // Its opaque origin hides its document from the page, so wait on the frame's own report.
        try await wait("the frame's video plays") { browser.pictureInPicture.isPlaying(tab) }
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false)
    }

    @MainActor func testAFrameInAHiddenContainerStaysInline() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <div style="display:none"><iframe id=frame srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe></div>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(browser.pictureInPicture.panel, "Its picture can't be shown, so nothing floats")
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false, "The frame is put back")
    }
}
@MainActor final class TabMediaCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("TabPlayButtonPausesAndResumesAnySitesMedia") ?? true { await liveCase("TabPlayButtonPausesAndResumesAnySitesMedia") { try await self.testTabPlayButtonPausesAndResumesAnySitesMedia(); self.tearDown() } }
        if only?.contains("PlayButtonReachesMediaInFramesAndOutsideTheDocument") ?? true { await liveCase("PlayButtonReachesMediaInFramesAndOutsideTheDocument") { try await self.testPlayButtonReachesMediaInFramesAndOutsideTheDocument(); self.tearDown() } }
        if only?.contains("ANotificationsChimeIsNoMediaButLongerAudioIs") ?? true { await liveCase("ANotificationsChimeIsNoMediaButLongerAudioIs") { try await self.testANotificationsChimeIsNoMediaButLongerAudioIs(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabMediaTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil); browser.pictureInPicture.reduceMotion = { true }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.pictureInPicture.tearDown(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "TabMediaTests", code: 1)
    }
    private func videoSource() throws -> String {
        let file = LiveFixtures.repository("Tests/RiseTests/Resources/PiPTestVideo.mp4")
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    @MainActor private func page(_ html: String, in browser: BrowserController) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://media.example/"))
        try await wait("page loads") {
            guard !tab.web.isLoading else { return false }
            return try await tab.web.evaluateJavaScript("document.readyState") as? String == "complete"
        }
        return tab
    }
    @MainActor private func paused(_ script: String, in tab: BrowserTab) async throws -> Bool? {
        try await tab.web.evaluateJavaScript(script) as? Bool
    }

    @MainActor func testTabPlayButtonPausesAndResumesAnySitesMedia() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <video id=loop muted loop autoplay playsinline src="\(source)"></video>
          <video id=main loop playsinline src="\(source)"></video>
          """, in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        try await wait("silent loop plays") { try await self.paused("loop.paused", in: tab) == false }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(row.playbackPaused, "Silent background video doesn't give the tab a play button")

        _ = try await tab.web.evaluateJavaScript("main.play(); 0")
        try await wait("row knows the media plays") { row.playbackPaused == false }
        // Over the row itself: a row hovers only where it's in front.
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: row.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: hover); row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.playback.isHidden, "Shows beside the close button on hover")

        _ = row.playback.accessibilityPerformPress()
        XCTAssertTrue(row.playback.paused, "The button swaps at once")
        try await wait("media pauses") { try await self.paused("main.paused", in: tab) == true }
        let loopPaused = try await paused("loop.paused", in: tab)
        XCTAssertEqual(loopPaused, false, "Only media with sound is paused")
        XCTAssertEqual(row.playbackPaused, true, "Paused media keeps its button")

        _ = row.playback.accessibilityPerformPress()
        try await wait("media resumes") { try await self.paused("main.paused", in: tab) == false }
        try await wait("row follows") { row.playbackPaused == false && !row.playback.paused }

        _ = try await tab.web.evaluateJavaScript("main.pause(); 0")
        try await wait("row follows the page's own pause") { row.playbackPaused == true && row.playback.paused }

        _ = try await tab.web.evaluateJavaScript("main.remove(); 0")
        try await wait("removed media takes its button with it", timeout: 5) { row.playbackPaused == nil }

        tab.web.loadHTMLString("<p>Next page</p>", baseURL: URL(string: "https://other.example/"))
        try await wait("next page") { tab.web.url?.host == "other.example" && !tab.web.isLoading }
        XCTAssertNil(row.playbackPaused)
    }

    @MainActor func testPlayButtonReachesMediaInFramesAndOutsideTheDocument() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <iframe id=frame srcdoc='<video loop playsinline src="\(source)"></video>'></iframe>
          """, in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        let framed = "frame.contentDocument.querySelector('video').paused"
        try await wait("frame ready") { try await self.paused(framed, in: tab) == true }
        _ = try await tab.web.evaluateJavaScript("frame.contentDocument.querySelector('video').play(); 0")
        try await wait("row knows the frame plays") { row.playbackPaused == false }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media pauses") { try await self.paused(framed, in: tab) == true }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media resumes") { try await self.paused(framed, in: tab) == false }
        _ = try await tab.web.evaluateJavaScript("frame.contentDocument.querySelector('video').pause(); 0")
        try await wait("row follows") { row.playbackPaused == true }

        // Media the page plays without adding it to the document.
        _ = try await tab.web.evaluateJavaScript("window.loose = document.createElement('video'); loose.loop = true; loose.src = '\(source)'; loose.play(); 0")
        try await wait("row knows the loose media plays") { row.playbackPaused == false }
        _ = row.playback.accessibilityPerformPress()
        try await wait("loose media pauses") { try await self.paused("loose.paused", in: tab) == true }
        let framePaused = try await paused(framed, in: tab)
        XCTAssertEqual(framePaused, true)
        _ = row.playback.accessibilityPerformPress()
        try await wait("loose media resumes, as it played last") { try await self.paused("loose.paused", in: tab) == false }
        let frameStill = try await paused(framed, in: tab)
        XCTAssertEqual(frameStill, true, "Play resumes only what played last")

        browser.closeTab(tab.id)
        XCTAssertNil(browser.tabMedia.paused(tab.id))
    }

    /// A page's notification chime, as Google Meet plays before a meeting, is no media to show:
    /// no play button on the tab and no Now Playing card once you've left it. Audio that runs
    /// longer still is.
    @MainActor func testANotificationsChimeIsNoMediaButLongerAudioIs() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <audio id=element></audio>
          <script>
          // A quiet tone, `seconds` long.
          window.wav = seconds => {
            const rate = 8000, samples = rate*seconds, buffer = new ArrayBuffer(44 + samples*2), view = new DataView(buffer);
            const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset+i, c.charCodeAt(0)));
            text(0, 'RIFF'); view.setUint32(4, 36 + samples*2, true); text(8, 'WAVEfmt ');
            view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
            view.setUint32(24, rate, true); view.setUint32(28, rate*2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
            text(36, 'data'); view.setUint32(40, samples*2, true);
            for (let i = 0; i < samples; i++) view.setInt16(44 + i*2, Math.round(Math.sin(i*2*Math.PI*440/rate)*3000), true);
            return URL.createObjectURL(new Blob([buffer], {type: 'audio/wav'}));
          };
          </script>
          """, in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        let other = browser.addTab(); browser.select(other.id); browser.update()
        // Played as pages play their chimes: a new Audio, and an element of the page's own.
        _ = try await tab.web.evaluateJavaScript("window.chime = new Audio(wav(1)); chime.play(); element.src = wav(1); element.play(); 0")
        try await wait("the chimes play") { try await self.paused("chime.currentTime > 0.2 && element.currentTime > 0.2", in: tab) == true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.tabMedia.paused(tab.id), "A chime is no media")
        XCTAssertNil(row.playbackPaused, "The tab gets no play button for it")
        XCTAssertFalse(browser.sidebar.nowPlaying.isShown, "Nor does Now Playing show it")
        // Over, or paused at its end, it still isn't: a chime left paused gave Now Playing its card.
        try await Task.sleep(for: .milliseconds(1200))
        let over = try await tab.web.evaluateJavaScript("[chime.paused || chime.ended, element.paused || element.ended, chime.currentTime, element.currentTime].join(' ')") as? String
        XCTAssertTrue(over?.hasPrefix("true true") == true, "The chimes are over: \(over ?? "")")
        XCTAssertNil(browser.tabMedia.paused(tab.id), "Over, it still isn't media")
        XCTAssertFalse(browser.sidebar.nowPlaying.isShown)

        _ = try await tab.web.evaluateJavaScript("window.song = new Audio(wav(15)); song.play(); 0")
        try await wait("longer audio is media") { browser.tabMedia.paused(tab.id) == false && row.playbackPaused == false }
        try await wait("and Now Playing shows it") { browser.sidebar.nowPlaying.isShown }
        _ = try await tab.web.evaluateJavaScript("song.pause(); 0")
    }
}
@MainActor final class TabAudioCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("TheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing") ?? true { await liveCase("TheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing") { try await self.testTheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabAudioTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil)
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "TabAudioTests", code: 1)
    }
    /// A page looping a silent clip: WebKit counts any audible track as sound,
    /// whatever its samples, so the test makes no noise.
    @MainActor private func soundTab(in browser: BrowserController) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString("""
          <!doctype html><title>Sound fixture</title><script>
          const rate = 8000, samples = rate, buffer = new ArrayBuffer(44 + samples*2), view = new DataView(buffer);
          const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset+i, c.charCodeAt(0)));
          text(0, 'RIFF'); view.setUint32(4, 36 + samples*2, true); text(8, 'WAVEfmt ');
          view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
          view.setUint32(24, rate, true); view.setUint32(28, rate*2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
          text(36, 'data'); view.setUint32(40, samples*2, true);
          // A quiet tone: Chromium only counts a tab as making sound when it isn't silent.
          for (let i = 0; i < samples; i++) view.setInt16(44 + i*2, Math.round(Math.sin(i*2*Math.PI*440/rate)*3000), true);
          const audio = new Audio(URL.createObjectURL(new Blob([buffer], {type: 'audio/wav'})));
          audio.loop = true; audio.play(); window.sound = audio;
          </script>
          """, baseURL: URL(string: "https://example.com/sound"))
        try await wait("page plays sound") { tab.isPlayingAudio }
        return tab
    }

    @MainActor func testTheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing() async throws {
        let browser = browser(); defer { clean(browser) }
        let quiet = browser.addTab()
        let tab = try await soundTab(in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        try await wait("row shows the audio button") { row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.audio.isHidden)
        XCTAssertGreaterThan(row.audio.frame.minX, row.icon.frame.maxX, "After the favicon")
        XCTAssertLessThan(row.audio.frame.maxX, row.titleField.frame.minX, "Before the title")
        XCTAssertEqual(row.audio.frame.size, row.close.frame.size, "The same square as the close button")
        XCTAssertEqual(row.audio.frame.midY, row.icon.frame.midY, accuracy: 0.5)
        let quietRow = try XCTUnwrap(browser.sidebar.rows[quiet.id]); quietRow.layoutSubtreeIfNeeded()
        XCTAssertFalse(quietRow.showsAudio); XCTAssertTrue(quietRow.audio.isHidden)
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX+24, "The title moves over to make room")
        XCTAssertTrue(row.hitTest(row.convert(NSPoint(x: row.audio.frame.midX, y: row.audio.frame.midY), to: row.superview)) === row.audio)

        _ = row.audio.accessibilityPerformPress()
        XCTAssertTrue(row.audio.muted, "The slash appears at once")
        XCTAssertTrue(tab.isAudioMuted)
        XCTAssertTrue((tab.page as? ChromiumPage)?.browserView.isAudioMuted == true, "Chromium mutes the page")
        try await Task.sleep(for: .milliseconds(300))
        let paused = try await tab.web.evaluateJavaScript("window.sound.paused") as? Bool
        XCTAssertEqual(paused, false, "Muting keeps it playing")
        XCTAssertTrue(row.showsAudio, "A muted tab keeps its button")

        _ = row.audio.accessibilityPerformPress()
        XCTAssertFalse(row.audio.muted); XCTAssertFalse(tab.isAudioMuted)
        XCTAssertTrue((tab.page as? ChromiumPage)?.browserView.isAudioMuted == false)

        _ = try await tab.web.evaluateJavaScript("window.sound.pause()")
        try await wait("tab stops playing") { !tab.isPlayingAudio }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(row.showsAudio, "A short pause keeps the title where it is")
        try await wait("button leaves after the sound stops", timeout: 4) { !row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX)
    }
}
