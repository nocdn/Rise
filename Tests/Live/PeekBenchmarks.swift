import AppKit
import WebKit
@testable import Rise

@main @MainActor struct PeekBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = PeekVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class PeekVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    print("Reduce Motion is on; Peek opens without motion."); NSApp.terminate(nil); return
                }
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.window?.center(); browser.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let source = folder.appendingPathComponent("source.html"), target = folder.appendingPathComponent("target.html")
                try """
                <body style="margin:0;background:#f6f6ef;font:15px Verdana">
                <a id="link" href="target.html" style="position:absolute;left:120px;top:220px">Sites in ChatGPT</a></body>
                """.write(to: source, atomically: true, encoding: .utf8)
                try "<body style='background:#2a6df4'><h1>Target</h1></body>".write(to: target, atomically: true, encoding: .utf8)
                let tab = browser.addTab(url: source)
                try await waitUntil { !tab.webView.isLoading && tab.webView.url == source }
                // The pointer is outside the page, so the lookup falls back to the focused link.
                _ = try await tab.webView.evaluateJavaScript("document.getElementById('link').focus(); 0")
                let css = try await tab.webView.evaluateJavaScript("(r => [r.left, r.top, r.width, r.height])(document.getElementById('link').getBoundingClientRect())") as! [NSNumber]
                let z = tab.webView.pageZoom
                let link = tab.webView.convert(NSRect(x: css[0].doubleValue*z, y: css[1].doubleValue*z, width: css[2].doubleValue*z, height: css[3].doubleValue*z), to: browser.root)

                // Holding Shift over the link renders its page before the click.
                browser.renderPeekStandby(target)
                let standby = browser.peekStandby!.tab
                try await waitUntil { !standby.webView.isLoading && standby.webView.url == target }
                try await Task.sleep(for: .milliseconds(150))
                let rendered = try await standby.webView.takeSnapshot(configuration: nil)
                check(isBlue(rendered), "The invisible standby page renders")

                // PEEK_FRAMES=<folder> records the window while a Peek opens, for frame-by-frame review.
                if let out = ProcessInfo.processInfo.environment["PEEK_FRAMES"] {
                    if ProcessInfo.processInfo.environment["PEEK_LARGE"] != nil { browser.window?.setFrame(NSRect(x: 8, y: 1, width: 1496, height: 944), display: true) }
                    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                    let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
                    var source = tab.webView, peekURL = target
                    if let live = ProcessInfo.processInfo.environment["PEEK_SOURCE"].flatMap(URL.init(string:)) {
                        let page = browser.addTab(url: live); source = page.webView
                        try await waitUntil { !page.webView.isLoading && page.webView.url != nil }
                        try await Task.sleep(for: .milliseconds(800))
                        let pick = ProcessInfo.processInfo.environment["PEEK_LAST"] != nil
                            ? "const all = document.querySelectorAll('.titleline > a'); const a = all[all.length-1]; window.scrollTo(0, document.body.scrollHeight); a.focus(); a.href"
                            : "const a = document.querySelector('.titleline a'); a.focus(); a.href"
                        let href = try await page.webView.evaluateJavaScript(pick) as! String
                        try await Task.sleep(for: .milliseconds(300))
                        peekURL = URL(string: href)!
                        if ProcessInfo.processInfo.environment["PEEK_STANDBY"] != nil {
                            browser.renderPeekStandby(peekURL); try await Task.sleep(for: .milliseconds(2500))
                        }
                    }
                    for _ in 0..<3 {
                        var t = CACurrentMediaTime()
                        _ = try? await source.callAsyncJavaScript(BrowserController.peekLinkScript, arguments: ["x": -1, "y": -1, "locate": true], contentWorld: .defaultClient)
                        let js = CACurrentMediaTime()-t; t = CACurrentMediaTime()
                        let config = WKSnapshotConfiguration(); config.rect = NSRect(x: 100, y: 100, width: 200, height: 20); config.afterScreenUpdates = false
                        _ = try? await source.takeSnapshot(configuration: config)
                        print("js", js, "snapshot", CACurrentMediaTime()-t)
                    }
                    browser.showPeek(url: peekURL, from: source)
                    let start = CACurrentMediaTime(); var index = 0
                    while CACurrentMediaTime()-start < 1.6 {
                        if let image = capture(.null, 8, UInt32(browser.window!.windowNumber), 1|8|16)?.takeRetainedValue() {
                            let rep = NSBitmapImageRep(cgImage: image)
                            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "%03d-%.3f.png", index, CACurrentMediaTime()-start)))
                            index += 1
                        }
                        try await Task.sleep(for: .milliseconds(4))
                    }
                    print("captured", index); NSApp.terminate(nil); return
                }
                let restingShadow = shadowDepth(receded: false)
                browser.showPeek(url: target, from: tab.webView)
                let card = browser.peekCard!
                check(browser.peekTab === standby && browser.peekStandby == nil, "Peek adopts the Shift-hovered page")
                check(card.alphaValue == 0 && browser.peekBackdrop?.alphaValue == 0, "Peek waits hidden while its link is located")
                let opening = try await sampleGhost()
                check(!opening.isEmpty, "A stand-in card animates the open")
                check(opening.allSatisfy { !$0.clipped } && opening.dropFirst(opening.count/2).allSatisfy { $0.shadow > 0.2 }, "The card's shadow is visible while it travels: \(opening.map { ($0.shadow, $0.clipped) })")
                let pageScales = opening.map(\.pageScale)
                check(pageScales.contains { $0 < 0.999 && $0 > BrowserController.peekPageScale+0.002 }, "The page behind recedes gradually: \(pageScales)")
                check(pageScales.min()! < BrowserController.peekPageScale, "The page recedes with the same overshooting spring: \(pageScales.min()!)")
                check(abs(pageScales.last!-BrowserController.peekPageScale) < 0.001, "The page settles slightly smaller")
                // Read where the spring began, independent of when sampling started.
                let startSize = (opening.first!.startBounds ?? .zero).size
                check(abs(startSize.width-(link.width+6)) < 3 && abs(startSize.height-(link.height+4)) < 3, "Open starts at the clicked link: \(startSize) vs \(link.size)")
                check(browser.peekOrigin?.image != nil, "The clicked link is snapshotted")
                check(opening.contains { $0.frame.width > link.width*2 && $0.frame.width < card.frame.width-20 }, "Open passes through intermediate sizes: \(opening.map(\.frame.width))")
                let peak = opening.map(\.frame.width).max()!
                check(peak > card.frame.width+0.5 && peak < card.frame.width*1.02, "Open springs slightly past the card: \(peak) vs \(card.frame.width)")
                let growing = opening.filter { $0.frame.width < link.width+(card.frame.width-link.width)*0.9 }
                let handedOver = growing.first { $0.page > 0.5 && $0.link < 0.3 }
                check(handedOver != nil, "The page replaces the link while the card is still growing: \(growing.map { ($0.page, $0.link) })")
                check(handedOver?.image.map(isBlue) == true, "The growing card shows the Peek page")
                try await Task.sleep(for: .milliseconds(150))
                check(card.alphaValue == 1 && browser.peekLeftovers.isEmpty && browser.peekControls.allSatisfy { $0.alphaValue == 1 }, "Live Peek replaces the stand-in when settled")
                let recededShadow = shadowDepth(receded: true)
                check(restingShadow > 4 && Double(recededShadow) > Double(restingShadow)*0.5, "The receded page keeps its shadow undimmed: \(recededShadow) vs \(restingShadow)")

                browser.closePeek(animated: true)
                check(browser.peekTab == nil && browser.peekCard == nil, "Closing clears Peek state immediately")
                let closing = try await sampleGhost()
                check(!closing.isEmpty, "A stand-in card animates the close")
                let last = closing.last!.frame
                check(onPath(last, from: link, to: card.frame, before: 0.2), "Close ends on the link: \(last) vs \(link)")
                check(closing.last!.link > 0.9, "Close crossfades into the link")
                let smallest = closing.map(\.frame.width).min()!
                check(smallest < link.width+6-0.3 && smallest > link.width+6-3, "Close springs subtly past the link: \(smallest) vs \(link.width+6)")
                let pageReturn = closing.map(\.pageScale).max()!
                check(pageReturn > 1.0005 && pageReturn < 1.005, "The page springs subtly past full size: \(pageReturn)")
                check(abs(closing.last!.pageScale-1) < 0.001 && CATransform3DIsIdentity(browser.pageShadow.layer!.transform), "The page returns to full size")
                try await Task.sleep(for: .milliseconds(100))
                check(browser.peekLeftovers.isEmpty && card.superview == nil && !browser.root.subviews.contains { $0 is PeekGhost } && !browser.pageClip.subviews.contains { $0 is PeekBackdrop }, "Close removes every Peek view")

                // Without a locatable link, Peek still opens promptly from the center.
                browser.showPeek(url: target)
                try await Task.sleep(for: .milliseconds(900))
                check(browser.peekCard?.alphaValue == 1 && browser.peekLeftovers.isEmpty, "Peek without a source link still opens")
                // Escape mid-open reverses the growing card from where it is.
                browser.closePeek(); try await Task.sleep(for: .milliseconds(400))
                browser.showPeek(url: target, from: tab.webView)
                try await Task.sleep(for: .milliseconds(120))
                let opener = browser.peekGhosts.first!
                check(opener.phase == .opening, "The card is still growing")
                let before = presentedFrame(opener)
                browser.closePeek(animated: true)
                let reversing = try await sampleGhost()
                check(browser.peekGhosts.allSatisfy { $0 === opener } && opener.phase == .closing, "The same card reverses instead of being replaced")
                check(abs(reversing.first!.frame.width-before.width) < before.width*0.15, "Reversal continues from the current size: \(before.width) → \(reversing.first!.frame.width)")
                check(onPath(reversing.last!.frame, from: link, to: card.frame, before: 0.2), "The reversed card returns to the link")
                try await Task.sleep(for: .milliseconds(100))
                check(browser.peekGhosts.isEmpty && browser.peekLeftovers.isEmpty && abs(browser.pageShadow.layer!.transform.m11-1) < 0.0001, "Reversal leaves nothing behind")
                // A new Peek can start while the previous one is still shrinking.
                browser.showPeek(url: target, from: tab.webView); try await Task.sleep(for: .milliseconds(900))
                browser.closePeek(animated: true); try await Task.sleep(for: .milliseconds(70))
                browser.showPeek(url: target, from: tab.webView); try await Task.sleep(for: .milliseconds(900))
                check(browser.peekCard?.alphaValue == 1 && browser.peekGhosts.isEmpty && browser.pageClip.subviews.filter { $0 is PeekBackdrop }.count == 1, "Reopening during a close settles on one Peek")
                check(abs(browser.pageShadow.layer!.transform.m11-BrowserController.peekPageScale) < 0.0001, "The page stays receded behind the reopened Peek")
                // A back swipe pulls the complete live card, then closes from that
                // displayed frame. Reversing/cancelling springs it back first.
                let pulledCard = browser.peekCard!, peekWeb = browser.peekTab!.webView
                let resting = pulledCard.frame, pageBounds = peekWeb.bounds
                let router = HistorySwipeController(window: browser.window as! BrowserWindow,
                    pageAt: { _ in peekWeb }, feedback: { _, _, _, _ in })
                var clicks = 0
                router.isPeekPage = { $0 === peekWeb }; router.thresholdClick = { clicks += 1 }
                router.dragPeek = { [self] in browser.dragPeek(pull: $0) }
                router.releasePeek = { [self] committed in
                    if committed { browser.closePeek(animated: true) } else { browser.returnPeekFromSwipe() }
                }
                router.cancelPeek = { [self] in browser.returnPeekFromSwipe() }
                check(router.handle(scroll(.began, x: 60)), "Peek receives precise back swipes without page history")
                try await waitUntil { router.gesture.consumesScroll }
                try await Task.sleep(for: .milliseconds(40))
                check(abs(presentedFrame(pulledCard).width-resting.width*0.985) < 1, "The entire card shrinks proportionally during the drag")
                check(router.handle(scroll(.changed, x: 70)), "Drag reaches threshold")
                try await Task.sleep(for: .milliseconds(40))
                check(clicks == 1 && router.gesture.isArmed, "One threshold haptic arms dismissal")
                check(peekWeb.bounds == pageBounds, "Dragging never resizes the live webpage")
                let backgroundScale = browser.pageShadow.layer!.presentation()!.transform.m11
                check(backgroundScale > BrowserController.peekPageScale + 0.004 && backgroundScale < BrowserController.peekPageScale + 0.006,
                      "The background grows subtly while the Peek shrinks: \(backgroundScale)")
                check(browser.peekControls.allSatisfy { $0.layer!.transform.m11 < 1 }, "The controls follow the complete card")
                check(router.handle(scroll(.changed, x: -30)) && !router.gesture.isArmed, "Reversing disarms dismissal")
                check(router.handle(scroll(.ended)), "A reversed release is consumed")
                try await Task.sleep(for: .milliseconds(450))
                check(browser.peekTab != nil && CATransform3DIsIdentity(pulledCard.layer!.transform), "A reversed swipe springs back without closing")
                check(abs(presentedFrame(pulledCard).width-resting.width) < 0.5, "Return spring settles at the original size")
                check(abs(browser.pageShadow.layer!.presentation()!.transform.m11-BrowserController.peekPageScale) < 0.0001,
                      "Cancelling settles the background back to its original receded size")
                check(router.handle(scroll(.began, x: 120)), "Second swipe starts")
                try await waitUntil { router.gesture.isArmed }
                try await Task.sleep(for: .milliseconds(40))
                var dragged = presentedFrame(pulledCard)
                check(abs(dragged.width-resting.width*0.97) < 1 && abs(dragged.midX-resting.midX-20) < 1,
                      "Threshold gives a subtle 3% shrink and 20-point rightward shift: \(dragged) vs \(resting)")
                let thresholdWidth = dragged.width
                check(router.handle(scroll(.changed, x: 120)), "Peek keeps moving past the threshold")
                try await Task.sleep(for: .milliseconds(40))
                let further = presentedFrame(pulledCard)
                check(router.handle(scroll(.changed, x: 600)), "A long swipe still meets elastic resistance")
                try await Task.sleep(for: .milliseconds(40))
                dragged = presentedFrame(pulledCard)
                check(further.width < thresholdWidth && dragged.width < further.width,
                      "Peek never hard stops beyond the threshold")
                check(further.width-dragged.width < thresholdWidth-further.width,
                      "Larger additional travel gives diminishing shrinkage")
                check(router.handle(scroll(.ended)), "Armed release closes Peek")
                let swipeClose = try await sampleGhost()
                check(browser.peekTab == nil && !swipeClose.isEmpty, "Swipe closes through the source-link animation")
                let swipeStart = swipeClose.first!.startBounds!.size
                check(abs(swipeStart.width-dragged.width) < 1 && abs(swipeStart.height-dragged.height) < 1,
                      "Close begins at the smaller dragged size: \(swipeStart) vs \(dragged.size)")
                check(onPath(swipeClose.last!.frame, from: link, to: dragged, before: 0.2), "Swipe dismissal returns to its source link")
                check(router.handle(scroll([], x: 250, momentum: 1)) && router.handle(scroll([], x: 250, momentum: 3)), "Momentum cannot dismiss again")
                router.cancel()
                try await Task.sleep(for: .milliseconds(100))
                check(browser.peekGhosts.isEmpty && browser.peekLeftovers.isEmpty, "Swipe dismissal leaves no views behind")
                check(abs(browser.pageShadow.layer!.presentation()!.transform.m11-1) < 0.0001,
                      "Dismissal restores the background to full size")
                print("Peek motion verified: open \(opening.count) samples (peak \(Int(peak)) vs card \(Int(card.frame.width))), close \(closing.count) samples (smallest \(smallest) vs \(link.width+6), page \(pageReturn)), shadow \(recededShadow)/\(restingShadow).")
                NSApp.terminate(nil)
            } catch { fputs("PEEK VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    func scroll(_ phase: NSEvent.Phase, x: Int32 = 0, momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -x, wheel3: 0)!
        let raw: Int64 = phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: raw)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }
    struct Sample { var frame: NSRect; var page: Float; var link: Float; var image: NSImage?; var pageScale: CGFloat; var shadow: Float; var clipped: Bool; var startBounds: NSRect? }
    /// Presentation state of the travelling stand-in, in root coordinates.
    func sampleGhost() async throws -> [Sample] {
        var samples: [Sample] = [], seen = false
        for _ in 0..<150 {
            if let ghost = browser.root.subviews.last(where: { $0 is PeekGhost }) as? PeekGhost, let model = ghost.layer, let layer = model.presentation() {
                seen = true
                // AppKit may store the layer geometry unflipped; map it like the model frame.
                let flipped = abs(model.frame.minY-ghost.frame.minY) > 0.5
                let frame = NSRect(x: layer.frame.minX, y: flipped ? browser.root.bounds.height-layer.frame.maxY : layer.frame.minY, width: layer.frame.width, height: layer.frame.height)
                samples.append(Sample(frame: frame, page: ghost.page.layer?.presentation()?.opacity ?? 0,
                                      link: ghost.link.layer?.presentation()?.opacity ?? 0, image: ghost.pageImage,
                                      pageScale: (browser.pageShadow.layer?.presentation() ?? browser.pageShadow.layer!).transform.m11,
                                      shadow: layer.shadowOpacity, clipped: model.masksToBounds,
                                      startBounds: (model.animation(forKey: "peek.bounds") as? CABasicAnimation)?.fromValue.flatMap { ($0 as? NSValue)?.rectValue }))
            } else if seen { break }
            try await Task.sleep(for: .milliseconds(8))
        }
        return samples
    }
    func presentedFrame(_ view: NSView) -> NSRect {
        let model = view.layer!, layer = model.presentation() ?? model
        let flipped = abs(model.frame.minY-view.frame.minY) > 0.5
        return NSRect(x: layer.frame.minX, y: flipped ? browser.root.bounds.height-layer.frame.maxY : layer.frame.minY, width: layer.frame.width, height: layer.frame.height)
    }
    /// How much darker the page's shadow makes the background just outside its left edge.
    func shadowDepth(receded: Bool) -> Int {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
        guard let image = capture(.null, 8, UInt32(browser.window!.windowNumber), 1|8)?.takeRetainedValue() else { return 0 }
        let bitmap = NSBitmapImageRep(cgImage: image), scale = CGFloat(bitmap.pixelsWide)/browser.root.bounds.width
        let page = browser.pageShadow.frame, inset = receded ? page.width*(1-BrowserController.peekPageScale)/2 : 0
        let edge = page.minX+inset, y = Int(page.midY*scale)
        func luminance(_ x: CGFloat) -> Int {
            guard let color = bitmap.colorAt(x: Int(x*scale), y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return Int((color.redComponent+color.greenComponent+color.blueComponent)/3*255)
        }
        let background = luminance(edge-6)
        return background - stride(from: edge-5, to: edge-0.5, by: 0.5).map(luminance).min()!
    }
    func isBlue(_ image: NSImage) -> Bool {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let color = bitmap.colorAt(x: bitmap.pixelsWide/2, y: bitmap.pixelsHigh*3/4)?.usingColorSpace(.sRGB) else { return false }
        return color.blueComponent > 0.8 && color.redComponent < 0.4
    }
    /// Whether `frame` lies on the straight link-to-card path, at most `before` of the way along.
    func onPath(_ frame: NSRect, from link: NSRect, to card: NSRect, before limit: CGFloat) -> Bool {
        let progress = (frame.width-link.width)/(card.width-link.width)
        let x = link.midX+(card.midX-link.midX)*progress, y = link.midY+(card.midY-link.midY)*progress
        return progress < limit && abs(frame.midX-x) < 12 && abs(frame.midY-y) < 12
    }
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        check(condition(), "Timed out waiting for the page")
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
