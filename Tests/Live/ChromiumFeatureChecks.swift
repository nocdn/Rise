// Rise's features on Chromium pages, in a real Rise window: the tab's sound and its play button
// (also from a frame of another site, in a process of its own), picture in picture, find,
// downloads, camera and location prompts, and history after a relaunch.
// Run with python3 scripts/test-chromium-live.py features.
import AppKit
@testable import Rise
import RiseChromium

typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

@main @MainActor struct ChromiumFeatureMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        // A check that hangs reports it rather than holding everything up.
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumFeatureRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumFeatureRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseChromiumCheck-\(UUID().uuidString)"
    let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").map(String.init)
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    /// The two sites the pages come from.
    var site: String { "http://localhost:\(ports[0])" }
    var otherSite: String { "http://127.0.0.1:\(ports[1])" }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }
    func page(_ name: String, _ html: String) throws -> URL {
        try "<!doctype html><meta charset=utf-8><title>\(name)</title>\(html)".write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        return URL(string: "\(site)/\(name).html")!
    }
    func open(_ url: URL) async -> BrowserTab {
        let tab = browser.addTab(url: url)
        _ = await waitUntil("\(url.lastPathComponent) loads") { tab.page.url == url && !tab.page.isLoading }
        return tab
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func run() async {
        do { try await checks() } catch { check(false, "\(error)") }
    }

    func checks() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let video = "<video src=clip.mp4 autoplay loop playsinline style='width:480px'></video>"

        // The tab's sound, and its play button pausing and resuming the page's media.
        let media = await open(try page("media", "<h1>Media</h1>\(video)"))
        check(media.page.engine == .chromium, "Tabs open in Chromium")
        _ = await waitUntil("Chromium reports the tab making sound") { media.page.isPlayingAudio }
        _ = await waitUntil("The tab's media reports itself playing") { browser.playbackPaused(media.id) == false }
        browser.togglePlayback(media.id)
        _ = await waitUntil("The play button pauses it") { browser.playbackPaused(media.id) == true }
        check(await value("return document.querySelector('video').paused", in: media.page) as? Bool == true, "The page's video is paused")
        _ = await waitUntil("The tab goes quiet") { !media.page.isPlayingAudio }
        browser.togglePlayback(media.id)
        _ = await waitUntil("The play button resumes it") { browser.playbackPaused(media.id) == false }

        // Picture in picture: leaving the tab floats its video, live, and showing it takes it back.
        _ = browser.addTab()
        _ = await waitUntil("Leaving the tab floats its video") {
            browser.pictureInPicture.sourceTabID == media.id && browser.pictureInPicture.panel?.alphaValue == 1
        }
        if let panel = browser.pictureInPicture.panel {
            check(media.page.view.window === panel, "The page itself is in the floating window")
            let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
            func picture() -> Data? {
                capture(.null, 8, UInt32(panel.windowNumber), 1|16).flatMap { NSBitmapImageRep(cgImage: $0.takeRetainedValue()).representation(using: .png, properties: [:]) }
            }
            let first = picture(); try await Task.sleep(for: .milliseconds(600))
            check(first != nil && first != picture(), "The floating video moves")
        }
        browser.select(media.id)
        _ = await waitUntil("Showing the tab takes the page back") { media.page.view.window === browser.window }
        check(await value("return !document.querySelector('video').paused", in: media.page) as? Bool == true, "The video plays on in its tab")

        // A frame of another site, in a process of its own, reports its media and pauses with the tab.
        try "<!doctype html><title>Frame</title>\(video)".write(to: folder.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
        let framed = await open(try page("framed", "<h1>Framed</h1><iframe src='\(otherSite)/frame.html' allow=autoplay width=520 height=320></iframe>"))
        _ = await waitUntil("The other site's frame reports its media") { browser.playbackPaused(framed.id) == false }
        browser.togglePlayback(framed.id)
        _ = await waitUntil("The play button pauses the frame's video") { browser.playbackPaused(framed.id) == true }
        browser.togglePlayback(framed.id)
        _ = await waitUntil("And resumes it") { browser.playbackPaused(framed.id) == false }
        _ = browser.addTab()
        _ = await waitUntil("Leaving the tab floats the frame's video") {
            browser.pictureInPicture.sourceTabID == framed.id && browser.pictureInPicture.panel?.alphaValue == 1
        }
        browser.select(framed.id)
        _ = await waitUntil("Showing the tab takes it back") { framed.page.view.window === browser.window }
        for tab in [media, framed] { browser.closeTab(tab.id) }

        // Find.
        let text = await open(try page("find", "<p>An apple a day.</p><p>Apples, and more apple pie.</p>"))
        let found = await PageFind.find("apple", direction: .restart, in: text.page)
        check(found == PageFind.Matches(count: 3, index: 0), "Find counts every match: \(found)")
        let next = await PageFind.find("apple", direction: .next, in: text.page)
        check(next.index == 1, "Find steps to the next match: \(next)")

        // Downloads.
        let downloads = await open(try page("downloads", "<a id=d href=clip.mp4 download=clip-copy.mp4>Save</a>"))
        _ = await value("document.getElementById('d').click()", in: downloads.page)
        _ = await waitUntil("The download finishes in Rise's list") {
            browser.downloads.items.first.map { $0.record.url.lastPathComponent == "clip-copy.mp4" && $0.isFinished } == true
        }
        let saved = browser.downloadsFolder.appendingPathComponent("clip-copy.mp4")
        let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0
        let original = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("clip.mp4").path)[.size] as? Int) ?? -1
        check(size == original, "The whole file is saved where Rise put it (\(size) of \(original) bytes)")

        // Camera and location go through Rise's own prompt.
        let ask = await open(try page("permissions", "<h1>Permissions</h1>"))
        _ = await value("""
            navigator.mediaDevices.getUserMedia({video: true}).then(s => window.camera = 'granted ' + s.getVideoTracks().length, e => window.camera = e.name)
            """, in: ask.page)
        _ = await waitUntil("Rise asks before the site gets the camera") { browser.permissionCoordinator.popover.isShown }
        browser.permissionCoordinator.resolve(true)
        _ = await waitUntil("Allowing gives the site the camera") { await value("return window.camera", in: ask.page) as? String == "granted 1" }
        _ = await value("""
            navigator.geolocation.getCurrentPosition(() => window.place = 'granted', e => window.place = 'denied ' + e.code)
            """, in: ask.page)
        _ = await waitUntil("Rise asks before the site gets the location") { browser.permissionCoordinator.popover.isShown }
        browser.permissionCoordinator.resolve(false)
        _ = await waitUntil("Denying refuses it") { await value("return window.place", in: ask.page) as? String == "denied 1" }

        // History after a relaunch: a page made later goes straight to where the tab was, with its history.
        let first = try page("first", "<h1>First</h1>"), second = try page("second", "<h1>Second</h1>")
        let history = await open(first)
        history.page.load(second)
        _ = await waitUntil("The tab goes on to a second page") { history.page.url == second && !history.page.isLoading && history.page.canGoBack }
        guard let state = history.sessionState else { check(false, "The tab has history to save"); return }
        let restored = ChromiumPage()
        restored.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300); browser.root.addSubview(restored.view, positioned: .below, relativeTo: nil)
        check(restored.restoreSession(state, fallback: first), "A new page takes the saved history")
        _ = await waitUntil("It opens where the tab was") { restored.url == second && !restored.isLoading }
        check(restored.canGoBack, "With the page before it to go back to")
        restored.goBack()
        _ = await waitUntil("Back goes to the first page") { restored.url == first && !restored.isLoading }
    }
}
