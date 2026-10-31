// Save from Rise's actual Chromium context menu, not an HTML download attribute.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumDownloadMenuChecks.swift
// RISE_DOWNLOAD_LENS_ONLY=1 checks just the reported public page.
import AppKit
import AVFoundation
import Network
@testable import Rise
import RiseChromium

/// The embedded player needs the clicked frame's cookie and referrer, rather than
/// its parent's. No cache, so the saving request itself must be authorized too.
private final class DownloadMenuServer {
    let listener: NWListener
    let clip: Data
    private let queue = DispatchQueue(label: "Rise.DownloadMenuChecks")
    private let lock = NSLock()
    private var recorded: [String] = []
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    var base: String? {
        guard let port = listener.port?.rawValue, port != 0 else { return nil }
        return "http://127.0.0.1:\(port)"
    }
    init(clip: Data) throws {
        self.clip = clip
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue); self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var data = data; if let chunk { data.append(chunk) }
            let request = String(decoding: data, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { self.receive(connection, data: data) }; return
            }
            self.lock.lock(); self.recorded.append(request); self.lock.unlock()
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let media = path.hasPrefix("/private.mp4"), hiddenReferrer = path.hasPrefix("/no-referrer")
            let authorized = request.contains("rise_download=approved") && request.contains("Referer: \(self.base!)/frame.html")
            let body: Data, mime: String, status: String
            if media {
                status = authorized ? "200 OK" : "403 Forbidden"
                mime = authorized ? "video/mp4" : "text/plain"
                body = authorized ? self.clip : Data("Missing frame credentials".utf8)
            } else if path.hasPrefix("/policy.mp4") {
                status = "200 OK"; mime = "video/mp4"; body = self.clip
            } else {
                status = "200 OK"; mime = "text/html"
                body = Data("""
                <!doctype html><title>Player</title><meta name=referrer content=\(hiddenReferrer ? "no-referrer" : "same-origin")>
                <video id=video controls preload=metadata style='width:600px;height:340px' src='\(hiddenReferrer ? "/policy.mp4" : "/private.mp4")?v=1'></video>
                """.utf8)
            }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nSet-Cookie: rise_download=approved; Path=/; SameSite=Lax\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8)+body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@main @MainActor struct ChromiumDownloadMenuMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+180) { print("FAIL download-menu checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumDownloadMenuRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumDownloadMenuRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description)
        if !condition { failures += 1 }
    }
    func wait(_ description: String, seconds: Double = 10, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !(await condition()), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
        let passed = await condition()
        check(passed, description)
        if !passed { throw NSError(domain: description, code: 1) }
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        await page.evaluate(script, arguments: [:], world: nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.downloadFlight?.finish()
            browser?.saveWork?.cancel()
            browser?.tabs.forEach { $0.cancelLoad() }
            browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func menu(in page: ChromiumPage, locate: String) async throws -> (NSMenu, RCContextMenu) {
        if let tab = browser.tabs.first(where: { $0.page === page }) { browser.select(tab.id) }
        browser.root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        guard let window = browser.window,
              let at = await value(locate, in: page) as? [Double] else { throw NSError(domain: "Missing context-menu target", code: 1) }
        let view = page.view
        let point = view.convert(NSPoint(x: at[0], y: view.isFlipped ? at[1] : view.bounds.height-at[1]), to: nil)
        var shown: NSMenu?, context: RCContextMenu?
        let handler = page.onContextMenu
        page.onContextMenu = { info in context = info; handler?(info) }
        browser.presentContextMenu = { menu, _, _ in shown = menu }
        defer { page.onContextMenu = handler }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .rightMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        try await wait("Right-click reaches Rise's native context menu") { shown != nil && context != nil }
        return (shown!, context!)
    }
    func choose(_ title: String, in menu: NSMenu) throws {
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
            throw NSError(domain: "Missing \(title): \(menu.items.map(\.title))", code: 1)
        }
        check(NSApp.sendAction(action, to: item.target, from: item), "Choose \(title)")
    }
    func download(_ title: String, from menu: NSMenu, page: ChromiumPage) async throws -> DownloadList.Item {
        let before = Set(browser.downloads.items.map(\.record.id)), tabs = browser.tabs.count, url = page.url
        var flights = 0
        let handler = page.onDownload
        page.onDownload = { [self] download, name in
            let count = browser.downloadFlight?.flights ?? 0
            let destination = handler?(download, name)
            if (browser.downloadFlight?.flights ?? 0) == count+1 { flights += 1 }
            return destination
        }
        defer { page.onDownload = handler }
        try choose(title, in: menu)
        try await wait("The menu starts a real download in Rise's list", seconds: 15) { self.browser.downloads.items.count == before.count+1 }
        let item = browser.downloads.items.first { !before.contains($0.record.id) }!
        check(flights == 1 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "The download launches Rise's existing flight exactly once")
        try await wait("The file finishes in Downloads", seconds: 35) { item.isFinished }
        check(item.record.url.deletingLastPathComponent().standardizedFileURL.path == browser.downloadsFolder.standardizedFileURL.path, "The file uses Rise's configured Downloads folder")
        check(browser.tabs.count == tabs && page.url == url, "Saving keeps the page and tabs intact")
        check(item.totalBytes > 0 && item.receivedBytes == item.totalBytes, "The progress list records all received bytes")
        return item
    }
    func run() async throws {
        let prefs = UserDefaults(suiteName: "rise-video-download-\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        browser.window?.setContentSize(NSSize(width: 1440, height: 1000))
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let tab = browser.addTab(url: URL(string: "https://lens.maximos.work/")!)
        let page = tab.page as! ChromiumPage
        try await wait("The reported Lens video loads", seconds: 25) {
            await self.value("return document.querySelector('video')?.readyState >= 2", in: page) as? Bool == true
        }
        let duration = await value("return document.querySelector('video').duration", in: page) as? Double
        let (menu, context) = try await menu(in: page, locate: "const r=document.querySelector('video').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/3]")
        check(context.mediaKind == .video && context.sourceURL?.lastPathComponent == "hero-loop.mp4", "Chromium identifies Lens's actual video, including its query string")
        let saved = try await download("Download Video", from: menu, page: page)
        check(saved.record.url.lastPathComponent.hasPrefix("hero-loop") && saved.record.url.pathExtension == "mp4", "The video keeps its MP4 filename (uniquely numbered if already downloaded)")
        let asset = AVURLAsset(url: saved.record.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let savedDuration = try await asset.load(.duration).seconds
        check(!tracks.isEmpty && duration != nil && abs(savedDuration-duration!) < 0.1, "The saved MP4 is playable and has the full original duration")
        if ProcessInfo.processInfo.environment["RISE_DOWNLOAD_LENS_ONLY"] != "1" { try await localChecks() }
    }
    func localChecks() async throws {
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        let base = "http://127.0.0.1:\(ports[0])"
        let clip = try Data(contentsOf: folder.appendingPathComponent("clip.mp4"))
        let server = try DownloadMenuServer(clip: clip); defer { server.stop() }
        defer { print("Embedded player requests:", server.requests.map { $0.components(separatedBy: "\r\n").first ?? "" }) }
        try await wait("The frame fixture starts") { server.base != nil }
        print("Embedded player server:", server.base!)
        func html(_ name: String, _ body: String) throws -> URL {
            try "<!doctype html><title>\(name)</title>\(body)".write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
            return URL(string: "\(base)/\(name).html")!
        }
        let framed = try html("embedded", "<iframe style='width:700px;height:450px;border:0' src='\(server.base!)/frame.html'></iframe>")
        let page = browser.addTab(url: framed).page as! ChromiumPage
        try await wait("The cross-origin player loads") { await self.value("return document.querySelector('iframe') !== null && !document.querySelector('iframe').contentDocument", in: page) as? Bool == true }
        try await wait("The embedded document loads its video metadata") { server.requests.contains { $0.hasPrefix("GET /private.mp4") } }
        let frameCenter = "const r=document.querySelector('iframe').getBoundingClientRect(); return [r.x+200,r.y+180]"
        let (frameMenu, context) = try await menu(in: page, locate: frameCenter)
        if context.mediaKind != .video { print("Frame target:", context.point, context.sourceURL as Any, server.requests.map { $0.components(separatedBy: "\r\n").first ?? "" }) }
        check(context.mediaKind == .video && context.sourceURL?.port == URL(string: server.base!)?.port, "The context belongs to the embedded player's origin")
        let frameDownload = try await download("Download Video", from: frameMenu, page: page)
        check(try Data(contentsOf: frameDownload.record.url) == clip, "The frame's cookie and referrer authorize the full video, byte for byte")
        let request = server.requests.last { $0.hasPrefix("GET /private.mp4") } ?? ""
        check(request.contains("rise_download=approved") && request.contains("Referer: \(server.base!)/frame.html"), "The saving request retains the clicked frame's cookie and referrer")

        let noReferrer = browser.addTab(url: URL(string: "\(server.base!)/no-referrer.html")!).page as! ChromiumPage
        try await wait("The no-referrer player loads") { await self.value("return document.querySelector('video')?.readyState >= 1", in: noReferrer) as? Bool == true }
        let videoCenter = "const r=document.querySelector('video').getBoundingClientRect(); return [r.x+200,r.y+180]"
        let (policyMenu, _) = try await menu(in: noReferrer, locate: videoCenter)
        let policyDownload = try await download("Download Video", from: policyMenu, page: noReferrer)
        check(try Data(contentsOf: policyDownload.record.url) == clip, "No-referrer videos still save completely")
        check(!(server.requests.last { $0.hasPrefix("GET /policy.mp4") } ?? "").lowercased().contains("referer:"), "The download honors the document's no-referrer policy")

        let blobURL = try html("blob", """
        <video id=video controls style='width:600px;height:340px'></video><script>
        fetch('/clip.mp4').then(r=>r.blob()).then(b=>video.src=URL.createObjectURL(b));
        </script>
        """)
        let blobPage = browser.addTab(url: blobURL).page as! ChromiumPage
        try await wait("The blob-backed video loads") { await self.value("return document.querySelector('video')?.readyState >= 1", in: blobPage) as? Bool == true }
        let (blobMenu, blobContext) = try await menu(in: blobPage, locate: videoCenter)
        check(blobContext.sourceURL?.scheme == "blob", "The menu retains the video's blob URL")
        let blobDownload = try await download("Download Video", from: blobMenu, page: blobPage)
        check(try Data(contentsOf: blobDownload.record.url) == clip, "A file-backed blob saves from Chromium's own storage, byte for byte")

        // A menu can outlive a navigation. It must not use a new document's credentials.
        let (staleMenu, _) = try await menu(in: noReferrer, locate: videoCenter)
        noReferrer.load(URL(string: "\(base)/blob.html")!)
        try await wait("The original menu document navigates away") { noReferrer.url?.path == "/blob.html" && !noReferrer.isLoading }
        let count = browser.downloads.items.count, requests = server.requests.count
        try choose("Download Video", in: staleMenu)
        try await Task.sleep(for: .milliseconds(300))
        check(browser.downloads.items.count == count && server.requests.count == requests, "A stale menu cannot download with a later document's context")

        // Other items used the same empty bridge, so cover those call sites too.
        let links = try html("links", "<a id=link href='/clip.mp4?linked=1' download='linked-video.mp4'>Linked video</a><br><audio controls src='/clip.mp4' style='width:500px'></audio><br><img id=image src='/image.png' width=80 height=80>")
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1kAAAAASUVORK5CYII=")!
        try imageData.write(to: folder.appendingPathComponent("image.png"))
        let linksPage = browser.addTab(url: links).page as! ChromiumPage
        try await wait("The link, audio and image fixture loads") { linksPage.title == "links" && !linksPage.isLoading }
        for (selector, title, expected) in [("#link", "Download Linked File", clip), ("audio", "Download Audio", clip), ("#image", "Download Image", imageData)] {
            let (menu, _) = try await menu(in: linksPage, locate: "const r=document.querySelector('\(selector)').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]")
            let item = try await download(title, from: menu, page: linksPage)
            check(try Data(contentsOf: item.record.url) == expected, "\(title) saves the exact resource")
            if selector == "#link" { check(item.record.url.lastPathComponent == "linked-video.mp4", "The link's suggested filename is retained") }
        }
        let before = Set(browser.downloads.items.map(\.record.id))
        linksPage.browserView.download(URL(string: "\(base)/clip.mp4?direct=1")!)
        try await wait("The general Chromium download API also starts saving") { self.browser.downloads.items.contains { !before.contains($0.record.id) && $0.isFinished } }
        let direct = browser.downloads.items.first { !before.contains($0.record.id) }!
        check(try Data(contentsOf: direct.record.url) == clip, "The general API downloads through Rise's normal transfer list")
    }
}
