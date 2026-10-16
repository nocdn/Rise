// Rise's floating video on Chromium: a page's video, played with sound, floats in Rise's panel when
// its tab is left, keeps painting the moving video, plays and pauses from the panel, and goes back to
// its tab still playing. Run with scripts/test-chromium-live.py float.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumFloatingVideoMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("DONE timeout"); exit(0) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        _ = RCEngine.start(withCachePath: folder + "/chromium", keychain: false)
        let run = ChromiumFloatingVideoRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumFloatingVideoRun: NSObject, NSApplicationDelegate {
    let folder: URL; var browser: BrowserController!
    var passes = 0, failures = 0
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    func check(_ ok: Bool, _ message: String) { print("\(ok ? "PASS" : "FAIL") \(message)"); if ok { passes += 1 } else { failures += 1 } }
    func value(_ script: String, in page: WebPage) async -> Any? { (try? await page.evaluate(script, arguments: [:], in: nil, world: .page)) ?? nil }
    func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return await condition()
    }
    func pixels(_ image: NSImage?) -> [UInt8]? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return bytes
    }
    func spread(_ p: [UInt8]?) -> Int { guard let p else { return -1 }; let v = p.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }; return (v.max() ?? 0)-(v.min() ?? 0) }
    func shot(_ window: NSWindow, _ name: String) {
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            try "<!doctype html><title>Video</title><body style='margin:0;background:#222'><video id=v src=clip.mp4 width=640 height=360 loop playsinline></video>".write(to: folder.appendingPathComponent("video.html"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>Other</title><h1>Other</h1>".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
            browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            let video = browser.addTab(url: URL(string: "http://localhost:\(port)/video.html")!)
            _ = await waitUntil(15) { await self.value("return document.querySelector('video').readyState >= 3", in: video.page) as? Bool == true }
            _ = await value("const v = document.querySelector('video'); v.muted = false; v.volume = 1; await v.play(); return true", in: video.page)
            let playing = await waitUntil(5) { await self.value("const v = document.querySelector('video'); return !v.paused && !v.muted && v.currentTime > 1", in: video.page) as? Bool == true }
            check(playing, "The video plays with sound")
            try? await Task.sleep(for: .seconds(1))
            let other = browser.addTab(url: URL(string: "http://localhost:\(port)/other.html")!)
            browser.select(other.id)
            let floated = await waitUntil(8) { self.browser.pictureInPicture.panel?.alphaValue == 1 && self.browser.pictureInPicture.panel?.hasVideoFrame == true }
            check(floated && browser.pictureInPicture.sourceTabID == video.id, "Leaving its tab floats it in Rise's panel")
            guard floated, let panel = browser.pictureInPicture.panel else { finish(); return }
            try? await Task.sleep(for: .milliseconds(500))
            shot(panel, "floating")
            let rect = panel.videoHost.bounds
            let first = pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))
            let frames = panel.renderedFrameCount
            try? await Task.sleep(for: .milliseconds(1500))
            let later = pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))
            check(panel.renderedFrameCount > frames+10, "The picture keeps painting (\(panel.renderedFrameCount-frames) frames in 1.5 s)")
            check(spread(first) > 30 && first != later, "It shows the moving video, not a blank picture (spread \(spread(first)))")
            let time = await value("return document.querySelector('video').currentTime", in: video.page) as? Double ?? 0
            panel.onTogglePlayback?()
            check(await waitUntil(3) { await self.value("return document.querySelector('video').paused", in: video.page) as? Bool == true }, "Its play button pauses the video")
            panel.onTogglePlayback?()
            check(await waitUntil(5) { await self.value("const v = document.querySelector('video'); return !v.paused && v.currentTime > \(time+0.2)", in: video.page) as? Bool == true }, "...and plays it again")
            check(spread(pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))) > 30, "The still picture for going back is the video")
            browser.pictureInPicture.returnToTab()
            let back = await waitUntil(4) { self.browser.pictureInPicture.panel == nil && video.page.view.window === self.browser.window }
            check(back && browser.selectedID == video.id, "Back-to-tab returns it to its tab")
            try? await Task.sleep(for: .milliseconds(600))
            check(await waitUntil(3) { await self.value("return !document.querySelector('video').paused", in: video.page) as? Bool == true }, "It keeps playing after it returns")
            if let window = browser.window { shot(window, "returned") }
            finish()
        }
    }
    func finish() { print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(0) }
}
