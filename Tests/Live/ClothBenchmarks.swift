// Runs inside a real NSApplication, without posting events to the user's input
// devices. python3 scripts/test-cloth-live.py exercises the same production router.
import AppKit
import WebKit
import MetalKit
@testable import Rise

@MainActor final class ClothVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failed = false
    func report(_ message: String) { FileHandle.standardOutput.write(Data((message+"\n").utf8)) }
    func check(_ condition: Bool, _ message: String) {
        if !condition { failed = true; report("FAIL: " + message) }
    }
    func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !predicate() { throw NSError(domain: "Cloth verification timeout", code: 1) }
    }
    func event(_ phase: NSEvent.Phase, x: Int32 = 0, momentum: Int64 = 0) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -x, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase == .began ? 1 : phase == .changed ? 2 : phase == .ended ? 4 : phase == .cancelled ? 8 : 0)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return NSEvent(cgEvent: cg)!
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!).deletingLastPathComponent()
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        Task {
            do { try await verify(in: folder) }
            catch { failed = true; report("FAIL: \(error)") }
            browser.historySwipe.cancel(); browser.pageCloth.cancel(); browser.saveWork?.cancel()
            report(failed ? "CLOTH VERIFICATION FAILED" : "CLOTH VERIFICATION PASSED")
            NSApp.terminate(nil)
        }
    }
    func verify(in folder: URL) async throws {
        let tab = browser.addTab(), web = tab.webView
        let colors = ["one":"#e6eee8", "two":"#e7edf5", "three":"#f2e5df"]
        for name in ["one","two","three"] {
            let url = folder.appendingPathComponent(name+".html")
            let html = """
            <!doctype html><meta charset=utf-8><title>\(name)</title><style>
            *{box-sizing:border-box}body{margin:0;padding:64px;background:\(colors[name]!);color:#29352d;font:18px -apple-system}
            header{display:flex;justify-content:space-between;border-bottom:1px solid #bbc4bd;padding-bottom:28px}
            h1{font:700 64px Georgia;max-width:700px;margin:76px 0 24px}p{max-width:650px;line-height:1.6}
            section{display:grid;grid-template-columns:repeat(3,1fr);gap:28px;margin-top:70px}
            article{border-top:1px solid #adb9b0;padding-top:20px}button{border:0;border-radius:24px;background:#29352d;color:white;padding:14px 28px;font:inherit}
            </style><header><b>smallhours / \(name)</b><span>Journal &nbsp;&nbsp; Objects &nbsp;&nbsp; About</span></header>
            <h1>Find a little<br>room to breathe.</h1><p>Page \(name). A real WebKit history surface, gently pulled at its edge. The native sidebar and navigation buttons stay in place.</p>
            <button>Find your inspiration →</button><section><article><small>01</small><h2>The everyday edit</h2>Objects worth keeping close.</article>
            <article><small>02</small><h2>Notes from the studio</h2>A quieter way to create.</article><article><small>03</small><h2>Room to breathe</h2>Finding space in the ordinary.</article></section>
            """
            try html.write(to: url, atomically: true, encoding: .utf8)
            web.loadFileURL(url, allowingReadAccessTo: folder)
            try await wait { web.title == name && !web.isLoading }
            try await Task.sleep(for: .milliseconds(80))
        }
        let chromeFrame = browser.pageShadow.frame, sidebarFrame = browser.sidebar.frame
        let arrowFrame = browser.toolbarButtons[1].frame
        let cloth = browser.pageCloth
        check(cloth.renderer != nil, "Metal renderer compiled")
        let router = HistorySwipeController(window: browser.window as! BrowserWindow, pageAt: { _ in web }, feedback: { direction,pull,armed,release in
            guard let direction, let arrow = self.browser.toolbarButtons[direction == .back ? 1 : 2] as? HistoryArrowButton else { return }
            if let release { arrow.release(committed: release) } else { arrow.drag(pull: pull, armed: armed) }
        })
        router.prepareCloth = { cloth.prepare($0) }
        router.dragCloth = { cloth.drag($0,direction:$1,distance:$2) }
        router.releaseCloth = { cloth.release(distance:$0,committed:$1,cancelled:$2) }
        router.cancelCloth = { cloth.cancel() }
        var clicks = 0; router.thresholdClick = { clicks += 1 }
        func begin(_ x: Int32) async throws {
            _ = router.handle(event(.began,x: x))
            try await wait { router.gesture.consumesScroll && cloth.isActive }
        }
        try await begin(180)
        try await wait { cloth.submittedFrames > 0 }
        let surface = web.superview?.subviews.compactMap { $0 as? ClothMetalView }.first
        check(surface?.layer?.mask is CAShapeLayer, "Visible Metal surface has the native bent outline mask")
        check(surface?.hitTest(.zero) == nil, "The visual overlay cannot intercept page input")
        check(cloth.renderer?.incoming != nil, "Back destination has a full-size cached preview")
        check(cloth.uniforms.pull > 0.52 && cloth.uniforms.pull < 0.54, "Increased resistance uses distance/(distance+160)")
        let backGap = CGPoint(x:1,y:web.frame.midY)
        check(browser.pageShadow.layer?.shadowPath?.contains(backGap) == false, "Back shadow follows the bend instead of the straight edge")
        check((browser.pageClip.layer?.mask as? CAShapeLayer)?.path?.contains(backGap) == false, "Back page backing bends with its content")
        browser.update()
        check(browser.pageShadow.layer?.shadowPath?.contains(backGap) == false, "A browser update preserves the deformed border")
        func checkHeaderCompression(forward: Bool) {
            let header = browser.developerBar.layer!
            let transform = header.affineTransform()
            let depth = web.frame.width * 0.05 * Double(cloth.uniforms.pull)
            let anchor = header.anchorPoint.x * browser.developerBar.bounds.width
            let left = anchor*(1-transform.a)+transform.tx
            check(abs(left-(forward ? 0 : depth)) < 0.01, "Developer header follows the full-height compressed edge")
            check(abs(transform.a-(1-depth/browser.pageClip.bounds.width)) < 0.0001 && transform.d == 1 && transform.b == 0 && transform.c == 0,
                "Developer header compresses horizontally without vertical shear")
        }
        checkHeaderCompression(forward: false)
        check(browser.pageShadow.frame == chromeFrame && browser.sidebar.frame == sidebarFrame && browser.toolbarButtons[1].frame == arrowFrame, "Only the inset page bends")
        check(clicks == 1, "One threshold click")
        try saveFrame("cloth-drag", cloth)
        _ = router.handle(event(.ended))
        check(cloth.phase == .returning && cloth.uniforms.elapsed < 0.03 && cloth.uniforms.strength > 0, "Ripple is submitted on finger-up")
        router.cancel(for: web) // The navigation delegate must not cancel its own reveal.
        check(cloth.phase == .returning, "Navigation-start callback preserves the release effect")
        try await Task.sleep(for: .milliseconds(90)); try saveFrame("cloth-ripple", cloth)
        try await wait { web.title == "two" && !web.isLoading && !cloth.isActive }
        check(cloth.phase == .idle && cloth.uniforms.pull == 0, "Return ends exactly flat and frees active GPU textures")
        check(cloth.renderer?.outgoing == nil, "Outgoing GPU surface released")
        check(browser.pageShadow.clothOutline == nil && browser.pageClip.layer?.mask == nil, "Outer edge and shadow restore on completion")
        check(browser.developerBar.layer?.affineTransform() == .identity, "Developer header restores after release")
        try await begin(150)
        _ = router.handle(event(.changed,x: -60)); check(!router.gesture.isArmed, "Reversal disarms navigation")
        _ = router.handle(event(.ended)); check(cloth.uniforms.reveal == 0, "Cancelled commit does not reveal another page")
        try await wait { !cloth.isActive }; check(web.title == "two", "Reversal leaves history unchanged")
        try await begin(-150)
        check(cloth.uniforms.forward == 1 && cloth.renderer?.incoming != nil, "Forward bends and reveals the mirrored edge")
        let forwardGap = CGPoint(x:browser.pageClip.bounds.width-1,y:web.frame.midY)
        check(browser.pageShadow.layer?.shadowPath?.contains(forwardGap) == false, "Forward shadow follows the right bend")
        check((browser.pageClip.layer?.mask as? CAShapeLayer)?.path?.contains(forwardGap) == false, "Forward page backing bends too")
        checkHeaderCompression(forward: true)
        _ = router.handle(event(.ended)); try await wait { web.title == "three" && !cloth.isActive }
        try await begin(150); _ = router.handle(event(.cancelled))
        check(cloth.uniforms.strength == 0, "System cancellation returns without a ripple")
        try await wait { !cloth.isActive }; check(web.title == "three", "System cancellation preserves history")
        try await begin(150); _ = router.handle(event([],momentum: 1))
        try await wait { web.title == "two" && !cloth.isActive }
        _ = router.handle(event([],x: 250,momentum: 3)); check(web.title == "two", "Momentum commits a missing finger-up only once")
        try await begin(-150); router.cancel(); check(!cloth.isActive, "New navigation/tab change interrupts the cloth immediately")
        let menuOwner = AppDelegate(); menuOwner.browser = browser; menuOwner.buildMenu()
        for (direction, shortcut, title) in [(HistoryDirection.back, false, "one"), (.forward, false, "two"), (.back, true, "one"), (.forward, true, "two")] {
            cloth.prepare(web); cloth.drag(web, direction: direction, distance: 180)
            try await wait { cloth.isActive }
            let arrow = browser.toolbarButtons[direction == .back ? 1 : 2] as! HistoryArrowButton
            arrow.drag(pull: 1, armed: true)
            if shortcut {
                let key = direction == .back ? "[" : "]"
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: browser.window!.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                check(NSApp.mainMenu!.performKeyEquivalent(with: event), "Default history shortcut dispatches")
            } else { arrow.performClick(nil) }
            check(!cloth.isActive && cloth.phase == .idle, "Buttons and shortcuts cancel the page transition synchronously")
            check(!arrow.isReturning && arrow.pull == 0 && arrow.image != nil, "Direct navigation restores the arrow without a spring")
            check(browser.pageShadow.clothOutline == nil && browser.pageClip.layer?.mask == nil, "Direct navigation leaves the inset page flat")
            try await wait { web.title == title && !web.isLoading }
            check(!cloth.isActive, "History navigation does not restart a ripple")
        }

        try await begin(150)
        web.loadFileURL(folder.appendingPathComponent("one.html"),allowingReadAccessTo:folder)
        try await wait { web.title == "one" && !cloth.isActive }
        check(cloth.phase == .idle, "A separate link or URL navigation cannot leave a stale cloth overlay")
        cloth.reduceMotion = { true }
        cloth.prepare(web); cloth.drag(web,direction:.back,distance:180)
        check(!cloth.isActive, "Reduce Motion leaves the live page untouched")
        cloth.reduceMotion = { false }
        web.pageZoom = 1.2
        try await begin(150)
        check(cloth.renderer?.incoming == nil, "An outdated zoom preview cannot be revealed")
        web.pageZoom = 1
        try await wait { !cloth.isActive }
        router.cancel()
        web.appearance = NSAppearance(named:.darkAqua)
        try await begin(150)
        check(cloth.renderer?.incoming == nil, "An outdated appearance preview cannot be revealed")
        router.cancel()
        report("PASS: real WebKit back/forward, cached reveal, fixed chrome, immediate release, reversal, cancellation, missing finger-up, animation-free buttons/shortcuts, interruption and Reduce Motion")
    }
    func saveFrame(_ name: String, _ cloth: PageClothTransition) throws {
        guard let directory = ProcessInfo.processInfo.environment["RISE_CLOTH_FRAMES"], let renderer = cloth.renderer else { return }
        let u = cloth.uniforms, width = Int(u.size.x), height = Int(u.size.y)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = .renderTarget
        let texture = renderer.device.makeTexture(descriptor: d)!
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = renderer.queue.makeCommandBuffer()!
        guard renderer.encode(pass,uniforms:u,into:command) else { return }
        command.commit(); command.waitUntilCompleted()
        var bytes = [UInt8](repeating:0,count:width*height*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:[.byteOrder32Little,CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)],provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(browser.theme.background.cgColor); context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.addPath(ClothMotion.outline(size:CGSize(width:width,height:height),pull:Double(u.pull),forward:u.forward > 0.5))
        context.clip(); context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name+".png"))
    }
}
@main @MainActor struct ClothVerifyMain {
    static func main() {
        let app = NSApplication.shared, delegate = ClothVerification()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); exit(delegate.failed ? 1 : 0)
    }
}
