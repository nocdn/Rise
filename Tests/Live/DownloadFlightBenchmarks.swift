import AppKit
import WebKit
@testable import Rise

@main @MainActor struct DownloadFlightBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = DownloadFlightVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class DownloadFlightVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
    // DOWNLOAD_FRAMES=<folder> records the window during each flight, for frame-by-frame review.
    let frames = ProcessInfo.processInfo.environment["DOWNLOAD_FRAMES"].map(URL.init(fileURLWithPath:))

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    print("Reduce Motion is on; downloads save without motion."); NSApp.terminate(nil); return
                }
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                // Shown like the app shows it at launch: AppKit reorients layers after the window
                // appears, which once left the archive upside down until a download played.
                browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(800))
                check(archiveIsUpright(), "The archive is upright at launch")
                browser.window?.setContentSize(NSSize(width: 1100, height: 720)); browser.window?.center()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                browser.downloadsFolder = folder.appendingPathComponent("Downloads")
                let source = folder.appendingPathComponent("source.html")
                try """
                <body style="margin:0;background:#fff;font:15px -apple-system">
                <a id="get" href="data:text/plain;base64,SGVsbG8gUmlzZQ==" download="hello.txt" style="position:absolute;left:520px;top:180px">Download</a></body>
                """.write(to: source, atomically: true, encoding: .utf8)
                let tab = browser.addTab(url: source)
                try await waitUntil { !tab.webView.isLoading && tab.webView.url == source }
                try await Task.sleep(for: .milliseconds(300))

                // Into the sidebar's archive button.
                let button = browser.sidebar.archiveButton
                let resting = button.convert(button.bounds, to: browser.root)
                let sidebar = try await throwDownload(from: tab.webView, label: "sidebar")
                check(sidebar.glyphHiddenDuringFlight, "The button's glyph hands over to the moving archive")
                check(!button.isGlyphHidden, "The button shows its own glyph again afterwards")
                check(archiveIsUpright(), "The archive is upright after catching a download")
                check(sidebar.archive == resting, "The flight lands in the sidebar button: \(sidebar.archive) vs \(resting)")
                let downloaded = browser.downloadsFolder.appendingPathComponent("hello.txt")
                try await waitUntil { (try? String(contentsOf: downloaded, encoding: .utf8)) == "Hello Rise" }

                // With the sidebar collapsed, the archive slides in on a tile and leaves again.
                browser.toggleSidebar(); browser.root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                let tray = try await throwDownload(from: tab.webView, label: "tray")
                check(tray.trayPeak > 1.001 && tray.trayPeak < 1.06, "The tile springs in with a subtle overshoot: \(tray.trayPeak)")
                check(tray.archive.minX > 0 && tray.archive.maxY < browser.root.bounds.height, "The tile rests in the bottom-left corner: \(tray.archive)")
                try await waitUntil { FileManager.default.fileExists(atPath: self.browser.downloadsFolder.appendingPathComponent("hello 2.txt").path) }
                print("Download flight verified: sidebar \(sidebar.samples) frames (lid \(String(format: "%.2f", sidebar.lidPeak)), recoil \(String(format: "%.2f", sidebar.recoilPeak)) pt), tray \(tray.samples) frames (slide-in peak \(String(format: "%.3f", tray.trayPeak))), files numbered.")
                NSApp.terminate(nil)
            } catch { fputs("DOWNLOAD FLIGHT VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    struct Result { var samples = 0, lidPeak = 0.0, recoilPeak = 0.0, trayPeak = 0.0, glyphHiddenDuringFlight = false, archive = CGRect.zero }
    func throwDownload(from web: WKWebView, label: String) async throws -> Result {
        _ = try await web.evaluateJavaScript("document.getElementById('get').click(); 0")
        try await waitUntil { self.browser.downloadFlight != nil }
        let flight = browser.downloadFlight!
        var result = Result(archive: flight.restingArchive)
        let origin = flight.model.flights.first!.origin, expected = browser.downloadFlightOrigin
        check(hypot(origin.x-expected.x, origin.y-expected.y) < 40, "The download leaves from the pointer: \(origin) vs \(expected)")
        var opened = false, closedAfterOpening = false, landed = false
        let start = CACurrentMediaTime()
        while browser.downloadFlight === flight && CACurrentMediaTime()-start < 4 {
            let model = flight.model
            result.samples += 1
            result.lidPeak = max(result.lidPeak, model.lid.value)
            result.recoilPeak = max(result.recoilPeak, hypot(model.pose.offset.x, model.pose.offset.y))
            result.trayPeak = max(result.trayPeak, model.tray.value)
            result.glyphHiddenDuringFlight = result.glyphHiddenDuringFlight || browser.sidebar.archiveButton.isGlyphHidden
            if model.lid.value > 0.9 { opened = true }
            if opened && model.lid.value < 0.01 { closedAfterOpening = true }
            if model.flights.isEmpty { landed = true }
            if let frames {
                let folder = frames.appendingPathComponent(label)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if let image = capture(.null, 8, UInt32(browser.window!.windowNumber), 1|8|16)?.takeRetainedValue() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                        .write(to: folder.appendingPathComponent(String(format: "%03d-%.3f.png", result.samples, CACurrentMediaTime()-start)))
                }
            }
            try await Task.sleep(for: .milliseconds(frames == nil ? 8 : 4))
        }
        check(browser.downloadFlight == nil && !browser.root.subviews.contains { $0 is DownloadFlightView }, "The \(label) flight cleans up after settling")
        check(landed && opened && closedAfterOpening, "The \(label) archive opens, catches the download and closes")
        check(result.recoilPeak > 1 && result.recoilPeak < 2.5, "The \(label) archive recoils subtly: \(result.recoilPeak)")
        return result
    }
    /// The lid is wider than the box, so the wider ink sits at the top when the icon is upright.
    func archiveIsUpright() -> Bool {
        browser.root.layoutSubtreeIfNeeded(); browser.window?.displayIfNeeded()
        guard let image = capture(.null, 8, UInt32(browser.window!.windowNumber), 1|8)?.takeRetainedValue() else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image), scale = CGFloat(bitmap.pixelsWide)/browser.root.bounds.width
        let button = browser.sidebar.archiveButton, rect = button.convert(button.bounds, to: browser.root)
        let top = Int(rect.minY*scale), bottom = Int(rect.maxY*scale), left = Int(rect.minX*scale), right = Int(rect.maxX*scale)
        func inkWidth(_ rows: Range<Int>) -> Int {
            rows.map { y in
                let ink = (left..<right).filter { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return (color.redComponent+color.greenComponent+color.blueComponent)/3 < 0.7
                }
                return ink.isEmpty ? 0 : ink.last!-ink.first!
            }.max() ?? 0
        }
        let height = bottom-top, upper = inkWidth(top..<top+height/2), lower = inkWidth(top+height/2..<bottom)
        return upper > lower+Int(2*scale)
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        check(condition(), "Timed out waiting")
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
