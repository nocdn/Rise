import AppKit
import WebKit
import Quartz
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
                // The archive's popover lists both downloads, newest first, with their sizes.
                browser.toggleSidebar(); browser.root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                browser.showDownloads()
                try await waitUntil { self.browser.downloadsPopover.isShown }
                try await Task.sleep(for: .milliseconds(500))
                let controller = browser.downloadsPopover.contentViewController as! DownloadsController
                let rows = controller.view.subviews.compactMap { $0 as? NSScrollView }.first!.documentView!.subviews.compactMap { $0 as? DownloadRow }
                check(rows.map { $0.item.record.url.lastPathComponent } == ["hello 2.txt", "hello.txt"], "The popover lists downloads newest first: \(rows.map(\.item.record.path))")
                check(DownloadRow.detail(for: rows[0].item.record.url, progress: nil) == "10 bytes", "Rows show the file size")
                let underPointer = rows.first { $0.window!.convertToScreen($0.convert($0.bounds, to: nil)).contains(NSEvent.mouseLocation) }
                check(rows.allSatisfy { $0.isHighlighted == ($0 === underPointer) }, "Opening highlights only a row under the pointer: \(rows.map(\.isHighlighted)), pointer over \(String(describing: underPointer?.item.record.path))")
                check(rows.allSatisfy { $0.isHighlighted || ($0.removeButton.isHidden && $0.previewButton.isHidden) }, "Row buttons wait for hover")
                check(rows[0].topRadius == 12 && rows[0].bottomRadius == 8 && rows[1].topRadius == 8 && rows[1].bottomRadius == 12,
                      "The list's outer corners follow the popover's")
                check(controller.view.window?.isKeyWindow == true && controller.view.window?.firstResponder === controller.view,
                      "The popover takes the keyboard: active \(NSApp.isActive), key \(String(describing: NSApp.keyWindow)), popover \(String(describing: controller.view.window)), responder \(String(describing: controller.view.window?.firstResponder))")
                rows[0].mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
                rows[0].layoutSubtreeIfNeeded()
                check(!rows[0].removeButton.isHidden && !rows[0].previewButton.isHidden, "Hovering a text file shows Quick Look and remove")
                check(rows[0].layer?.animationKeys()?.isEmpty ?? true, "The hover highlight is immediate")
                check(rows[0].previewButton.frame.maxX <= rows[0].removeButton.frame.minX && rows[0].removeButton.frame.maxX < rows[0].bounds.width,
                      "Quick Look sits beside the remove button at the row's end")
                check(rows[0].subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.frame.maxX <= rows[0].previewButton.frame.minX }, "Titles stop before the buttons")
                try await Task.sleep(for: .milliseconds(200))
                if let frames, let number = controller.view.window?.windowNumber,
                   let image = capture(.null, 8, UInt32(number), 1|8)?.takeRetainedValue() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent("popover.png"))
                }
                var opened: URL?
                controller.open = { opened = $0 }
                _ = rows[1].accessibilityPerformPress()
                check(opened == browser.downloadsFolder.appendingPathComponent("hello.txt"), "Clicking a row opens its file")
                let store = browser.sessionURL.deletingLastPathComponent().appendingPathComponent("downloads.json")
                check(DownloadList(storeURL: store).visible.count == 2, "Downloads persist across launches")

                // Arrow keys move the highlight and ignore the pointer until it moves.
                @MainActor func press(_ code: UInt16, _ characters: String) {
                    let window = browser.downloadsPopover.contentViewController!.view.window!
                    window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
                }
                press(125, "\u{F701}")
                check(controller.highlightedID == rows[1].item.record.id && controller.usesKeyboard, "Down moves the highlight to the next row")
                rows[0].mouseEntered(with: NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
                check(controller.highlightedID == rows[1].item.record.id, "The keyboard ignores rows passing under a still pointer")
                press(126, "\u{F700}")
                check(controller.highlightedID == rows[0].item.record.id && !rows[0].removeButton.isHidden, "Up moves it back, showing the row's buttons")
                let row1 = rows[1].window!.convertToScreen(rows[1].convert(rows[1].bounds, to: nil))
                controller.pointerMoved(to: NSPoint(x: row1.midX, y: row1.midY))
                check(controller.highlightedID == rows[1].item.record.id && !controller.usesKeyboard, "Moving the pointer hands the highlight to the row under it")
                if let frames, let number = controller.view.window?.windowNumber {
                    try await Task.sleep(for: .milliseconds(200))
                    if let image = capture(.null, 8, UInt32(number), 1|8)?.takeRetainedValue() {
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent("popover-last.png"))
                    }
                }
                press(126, "\u{F700}")

                // Space previews the highlighted file in Quick Look.
                let panel = QLPreviewPanel.shared()!
                let closeStarted = CACurrentMediaTime()
                press(49, " ")
                check(!panel.isVisible && browser.downloadsPopover.isShown, "Quick Look waits while the popover animates closed")
                while browser.downloadsPopover.isShown && CACurrentMediaTime()-closeStarted < 3 {
                    check(!panel.isVisible, "Quick Look doesn't interrupt the native popover closing animation")
                    try await Task.sleep(for: .milliseconds(10))
                }
                check(CACurrentMediaTime()-closeStarted > 0.05, "The native closing animation runs before Quick Look opens")
                try await waitUntil("for Quick Look: visible \(panel.isVisible), item \(String(describing: panel.currentPreviewItem?.previewItemURL)), key \(String(describing: NSApp.keyWindow)), first responder \(String(describing: NSApp.keyWindow?.firstResponder))") { panel.isVisible && (panel.currentPreviewItem?.previewItemURL == downloaded.deletingLastPathComponent().appendingPathComponent("hello 2.txt")) }
                try await waitUntil("for the popover to close") { !self.browser.downloadsPopover.isShown }
                // Don't attempt dismissal during Quick Look's own opening animation.
                try await Task.sleep(for: .milliseconds(300))
                panel.performClose(nil)
                try await waitUntil("for downloads to return after closing Quick Look: panel \(panel.isVisible), controller \(String(describing: panel.currentController)), id \(String(describing: self.browser.quickLookDownloadID)), url \(String(describing: self.browser.quickLookURL)), active \(NSApp.isActive)") { self.browser.downloadsPopover.isShown }
                let returned = browser.downloadsPopover.contentViewController as! DownloadsController
                check(returned.highlightedID == rows[0].item.record.id && returned.usesKeyboard,
                      "Closing Quick Look restores the previewed row with keyboard focus")
                check(returned.view.window?.firstResponder === returned.view, "The restored list takes the keyboard")

                // Space can close the preview and return to the same row repeatedly.
                press(49, " ")
                try await waitUntil("for Quick Look to reopen") { panel.isVisible && !self.browser.downloadsPopover.isShown }
                try await Task.sleep(for: .milliseconds(300))
                panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
                try await waitUntil("for downloads to return after Space") { !panel.isVisible && self.browser.downloadsPopover.isShown }

                // The X clears a row but keeps the file.
                let shown = browser.downloadsPopover.contentViewController as! DownloadsController
                let listed = { shown.view.subviews.compactMap { $0 as? NSScrollView }.first!.documentView!.subviews.compactMap { $0 as? DownloadRow } }
                check(shown.highlightedID == rows[0].item.record.id && shown.usesKeyboard, "Space restores the same selection")
                press(51, "\u{7F}")
                check(listed().map { $0.item.record.url.lastPathComponent } == ["hello.txt"], "Removing clears the row: \(listed().map(\.item.record.path))")
                check(FileManager.default.fileExists(atPath: downloaded.deletingLastPathComponent().appendingPathComponent("hello 2.txt").path), "Removing keeps the downloaded file")
                check(DownloadList(storeURL: store).visible.count == 1, "Removal persists")
                check(shown.highlightedID == listed().first?.item.record.id, "The keyboard highlight moves to the next row after Delete")
                check(listed()[0].topRadius == 12 && listed()[0].bottomRadius == 12, "A lone row rounds all its corners like the popover")
                listed()[0].removeButton.performClick(nil)
                check(shown.view.subviews.compactMap { $0 as? NSScrollView }.first!.documentView!.subviews.contains { ($0 as? NSTextField)?.stringValue == "No downloads yet" }, "An empty list says so")
                try await Task.sleep(for: .milliseconds(400))
                if let frames, let number = shown.view.window?.windowNumber,
                   let image = capture(.null, 8, UInt32(number), 1|8)?.takeRetainedValue() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: frames.appendingPathComponent("popover-empty.png"))
                }
                browser.downloadsPopover.performClose(nil)
                try await waitUntil("for the popover to close") { !self.browser.downloadsPopover.isShown }

                // More than five downloads scroll, and a preview returns to an offscreen row.
                for index in 1...7 {
                    let url = browser.downloadsFolder.appendingPathComponent("scroll-\(index).txt")
                    try "Scroll preview \(index)".write(to: url, atomically: true, encoding: .utf8)
                    browser.downloads.finish(browser.downloads.begin(url, progress: nil))
                }
                browser.showDownloads()
                try await waitUntil { self.browser.downloadsPopover.isShown }
                let longList = browser.downloadsPopover.contentViewController as! DownloadsController
                let scroll = longList.view.subviews.compactMap { $0 as? NSScrollView }.first!
                check(longList.preferredContentSize.height == 5*DownloadRow.height+2*DownloadsController.inset,
                      "The popover is capped at five rows: \(longList.preferredContentSize)")
                check(scroll.documentVisibleRect.height == 5*DownloadRow.height,
                      "The viewport fits exactly five rows, with padding outside it")
                check(longList.rows.count == 7 && scroll.documentView!.bounds.height > scroll.contentView.bounds.height,
                      "Additional rows remain in a scrollable document")
                longList.focus(longList.rows[0].item.record.id)
                for _ in 0..<6 { press(125, "\u{F701}") }
                let lastID = longList.rows[6].item.record.id, lastURL = longList.rows[6].item.record.url
                check(longList.highlightedID == lastID && scroll.documentVisibleRect.contains(longList.rows[6].frame),
                      "Arrow navigation reveals the last row")
                press(49, " ")
                try await waitUntil { panel.isVisible && panel.currentPreviewItem?.previewItemURL == lastURL && !self.browser.downloadsPopover.isShown }
                try await Task.sleep(for: .milliseconds(300))
                panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!)
                try await waitUntil("for downloads to return after Escape: panel \(panel.isVisible), delegate \(String(describing: panel.delegate)), controller \(String(describing: panel.currentController)), id \(String(describing: self.browser.quickLookDownloadID)), key \(String(describing: NSApp.keyWindow))") { !panel.isVisible && self.browser.downloadsPopover.isShown }
                let restored = browser.downloadsPopover.contentViewController as! DownloadsController
                let restoredScroll = restored.view.subviews.compactMap { $0 as? NSScrollView }.first!
                check(restored.highlightedID == lastID && restored.usesKeyboard && restoredScroll.documentVisibleRect.contains(restored.rows[6].frame),
                      "Quick Look restores the last row focused and scrolled into view")
                browser.downloadsPopover.performClose(nil)
                try await waitUntil { !self.browser.downloadsPopover.isShown }

                // With the sidebar collapsed, the list opens from the corner downloads land in.
                browser.toggleSidebar(); browser.root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(400))
                browser.toggleDownloads()
                try await waitUntil("for the collapsed-sidebar popover") { self.browser.downloadsPopover.isShown }
                let corner = browser.downloadsPopover.contentViewController!.view.window!.frame, content = browser.window!.frame
                check(corner.minX < content.minX+120 && corner.minY < content.minY+140, "The popover opens at the bottom-left corner: \(corner) in \(content)")
                browser.toggleDownloads()
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
            if model.lid.value > 0.5 { opened = true }  // Half open: frame capture can slow sampling past the brief peak.
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
        let state = flight.model
        let summary = "time \(state.time), flights \(state.flights.count), lid \(state.lid.value), tray \(state.tray.value)/\(state.tray.target), recoil \(state.pose.offset), elapsed \(CACurrentMediaTime()-start), samples \(result.samples)"
        check(browser.downloadFlight == nil && !browser.root.subviews.contains { $0 is DownloadFlightView }, "The \(label) flight cleans up after settling: \(summary)")
        check(landed && opened && closedAfterOpening, "The \(label) archive opens, catches the download and closes: landed \(landed) opened \(opened) closed \(closedAfterOpening), \(summary)")
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
    func waitUntil(_ what: @autoclosure () -> String = "", _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        check(condition(), "Timed out waiting \(what())")
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
