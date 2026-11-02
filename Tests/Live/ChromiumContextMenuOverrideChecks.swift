// python3 scripts/test-chromium-live.py Tests/Live/ChromiumContextMenuOverrideChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ContextMenuOverrideMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ContextMenuOverrideRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ContextMenuOverrideRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ valid: Bool, _ text: String) { print(valid ? "PASS" : "FAIL", text); if !valid { failures += 1 } }
    func wait(_ text: String, _ predicate: () async -> Bool) async throws {
        let until = Date().addingTimeInterval(10)
        while !(await predicate()), Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        let valid = await predicate(); check(valid, text)
        if !valid { throw NSError(domain: text, code: 1) }
    }
    func value(_ body: String, _ page: WebPage) async -> Any? { try? await page.evaluate(body, arguments: [:], in: nil, world: .page) }
    func point(_ selector: String, in page: WebPage) async -> NSPoint {
        let xy = await value("const r=document.querySelector('\(selector)').getBoundingClientRect();return [r.x+16,r.y+r.height/2]", page) as! [Double]
        return page.view.convert(NSPoint(x: xy[0], y: page.view.isFlipped ? xy[1] : page.view.bounds.height-xy[1]), to: nil)
    }
    func mouse(_ type: NSEvent.EventType, at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        browser.window!.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown || type == .leftMouseDown ? 1 : 0)!)
    }
    func rightClick(_ selector: String, in page: WebPage, modifiers: NSEvent.ModifierFlags = [], release: NSEvent.ModifierFlags? = nil) async -> NSMenu? {
        var menu: NSMenu?
        browser.presentContextMenu = { shown, _, _ in menu = shown }
        let at = await point(selector, in: page)
        mouse(.mouseMoved, at: at, modifiers: modifiers)
        try? await Task.sleep(for: .milliseconds(50))
        mouse(.rightMouseDown, at: at, modifiers: modifiers)
        mouse(.rightMouseUp, at: at, modifiers: release ?? modifiers)
        // Both native menu requests and the page's custom handlers cross process boundaries.
        try? await Task.sleep(for: .milliseconds(200))
        return menu
    }
    func choose(_ title: String, in menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else { check(false, "Has \(title)"); return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.saveWork?.cancel(); browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let suite = "Rise.ContextOverride.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1100, height: 900))
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")
        let site = "http://localhost:\(ports[0])", other = "http://127.0.0.1:\(ports[1])"
        let handlers = """
        window.seen=[];window.custom=0;
        for(const type of ['pointerdown','mousedown','pointerup','mouseup','auxclick','contextmenu']) {
          window.addEventListener(type,e=>{
            if(e.button!==2)return;
            seen.push(type);
            if(type==='contextmenu'||e.target.id==='hostile'){e.preventDefault();custom++;}
          },true);
        }
        """
        try "<script>\(handlers)</script><body style='margin:0'><a href='/child-link' style='display:block;padding:8px'>Cross-site link</a>".write(to: folder.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><head><script>\(handlers)</script></head><body style='font:18px system-ui;margin:20px'>
        <video id=video src=clip.mp4 controls muted loop style='width:320px;height:180px'></video>
        <a id=link href='/linked' style='display:block;padding:10px'>A link</a>
        <textarea id=edit>Copy this text</textarea>
        <button id=primary onclick='window.primaryShift=event.shiftKey'>Shift left click</button>
        <p id=hostile>Custom menu on pointer-down as well as contextmenu</p>
        <div id=shadow style='height:40px'></div>
        <iframe id=frame src='\(other)/child.html' style='border:0;width:400px;height:50px'></iframe>
        <script>document.querySelector('#shadow').attachShadow({mode:'closed'}).innerHTML='<a href="/shadow-link" style="display:block;padding:8px">Closed shadow link</a>';</script>
        """.write(to: folder.appendingPathComponent("menus.html"), atomically: true, encoding: .utf8)
        let tab = browser.addTab(url: URL(string: site+"/menus.html")!), page = tab.page as! ChromiumPage
        browser.hidePalette()
        try await wait("The real video and cross-origin frame load") { await self.value("return document.querySelector('#video')?.readyState>=2 && !!document.querySelector('#frame')", page) as? Bool == true }
        browser.window?.makeFirstResponder(page.view)

        let ordinary = await rightClick("#video", in: page)
        check(ordinary == nil, "Ordinary right-click keeps the website's menu")
        check((await value("return custom", page) as? Int ?? 0)>0, "The website's early window-capture handler runs normally")
        _ = await value("seen=[];custom=0;return 0", page)
        let video = await rightClick("#video", in: page, modifiers: .shift)
        check(video?.items.contains { $0.title == "Download Video" } == true, "Shift–right-click opens the real Download Video menu")
        check(await value("return seen.length===0 && custom===0", page) as? Bool == true, "Both pointer and context-menu handlers are bypassed")
        let destination = folder.appendingPathComponent("saved-video.mp4")
        var download: RCDownload?
        page.onDownload = { received, _ in download = received; return destination }
        choose("Download Video", in: video)
        try await wait("The native menu downloads its video") { download?.state == .finished }
        check(try Data(contentsOf: destination) == Data(contentsOf: folder.appendingPathComponent("clip.mp4")), "The downloaded file is the actual video")
        check(await rightClick("#video", in: page) == nil, "The next ordinary right-click isn't forced")

        _ = await value("const video=document.querySelector('#video'),player=document.createElement('div');player.id='player';player.style='position:relative;width:320px;height:180px';video.replaceWith(player);player.append(video);player.insertAdjacentHTML('beforeend','<div id=overlay style=\"position:absolute;inset:0;background:transparent;pointer-events:auto!important\"></div>');window.originalVideoStyle=video.getAttribute('style');window.originalOverlayStyle=document.querySelector('#overlay').getAttribute('style');return 0", page)
        let covered = await rightClick("#overlay", in: page, modifiers: .shift)
        check(covered?.items.contains { $0.title == "Download Video" } == true, "A transparent player overlay retains Download Video")
        check(await value("return document.querySelector('#video').getAttribute('style')===originalVideoStyle && document.querySelector('#overlay').getAttribute('style')===originalOverlayStyle", page) as? Bool == true, "Player controls and inline style priorities are restored immediately")
        download = nil
        try? FileManager.default.removeItem(at: destination)
        choose("Download Video", in: covered)
        try await wait("A video covered by player controls downloads normally") { download?.state == .finished }
        check(try Data(contentsOf: destination) == Data(contentsOf: folder.appendingPathComponent("clip.mp4")), "The overlay menu saves video bytes, not the webpage")
        check(await rightClick("#overlay", in: page) == nil, "Ordinary right-click on the player still reaches its custom menu")
        _ = await value("document.querySelector('#video').style.pointerEvents='none';return 0", page)
        check(await rightClick("#overlay", in: page, modifiers: .shift)?.items.contains { $0.title == "Download Video" } == true, "A video with pointer events disabled is still recognized behind its player")
        check(await value("return document.querySelector('#video').style.pointerEvents==='none'", page) as? Bool == true, "The video's original pointer-events:none is preserved")
        _ = await value("document.querySelector('#overlay').remove();document.querySelector('#video').style.removeProperty('pointer-events');document.body.insertAdjacentHTML('beforeend','<div id=modal role=dialog style=\"position:fixed;inset:0;background:white\">Unrelated dialog</div>');return 0", page)
        let modal = await rightClick("#modal", in: page, modifiers: .shift)
        check(modal != nil && modal?.items.contains { $0.title == "Download Video" } == false, "An unrelated dialog is not pierced to find a video behind it")
        _ = await value("document.querySelector('#modal').remove();return 0", page)

        let link = await rightClick("#link", in: page, modifiers: .shift)
        check(link?.items.contains { $0.title == "Copy Link" } == true && link?.items.contains { $0.title == "Download Linked File" } == true,
              "Links retain their native actions")
        _ = await value("document.querySelector('#edit').focus();document.querySelector('#edit').select();return 0", page)
        let edit = await rightClick("#edit", in: page, modifiers: .shift)
        check(edit?.items.contains { $0.title == "Cut" } == true && edit?.items.contains { $0.title == "Paste" } == true, "Editable fields retain their native menu")
        _ = await value("document.querySelector('#edit').blur();seen=[];custom=0;return 0", page)
        let hostile = await rightClick("#hostile", in: page, modifiers: .shift, release: [])
        check(hostile != nil, "The native menu wins even over a pointer-down custom menu")
        check(await value("return seen.length===0 && custom===0", page) as? Bool == true, "Releasing Shift mid-click still suppresses the website's mouse-up handler")
        let at = await point("#primary", in: page)
        mouse(.mouseMoved, at: at, modifiers: .shift)
        try await Task.sleep(for: .milliseconds(50))
        mouse(.leftMouseDown, at: at, modifiers: .shift); mouse(.leftMouseUp, at: at, modifiers: .shift)
        try await wait("Shift–left-click remains a normal primary click") { await self.value("return primaryShift===true", page) as? Bool == true }
        _ = await value("custom=0;document.querySelector('#link').dispatchEvent(new MouseEvent('contextmenu',{button:2,shiftKey:true,bubbles:true,cancelable:true}));return 0", page)
        check(await value("return custom>0", page) as? Bool == true, "Synthetic page events remain the page's own")
        _ = await value("Event.prototype.stopImmediatePropagation=function(){};return 0", page)
        check(await rightClick("#video", in: page, modifiers: .shift) != nil, "A website cannot disable the isolated override by changing Event.prototype")

        _ = await value("getSelection().removeAllRanges();return 0", page)
        let shadow = await rightClick("#shadow", in: page, modifiers: .shift)
        check(shadow?.items.contains { $0.title == "Copy Link" } == true, "Native hit testing still sees links inside a closed shadow root")
        let frame = await rightClick("#frame", in: page, modifiers: .shift)
        check(frame?.items.contains { $0.title == "Copy Link" } == true, "Cross-origin frames also use the override")

        _ = await value("const player=document.querySelector('#player');player.__reactFiber$riseCheck={memoizedProps:{},return:{memoizedProps:{variants:[{src:'https://video.twimg.com/low.mp4',type:'video/mp4',bitrate:256000},{src:'https://video.twimg.com/high.mp4?tag=29',type:'video/mp4',bitrate:832000},{src:'https://evil.test/other.mp4',type:'video/mp4',bitrate:999999}]},return:{memoizedProps:{variants:[{src:'https://video.twimg.com/wrong-player.mp4',type:'video/mp4',bitrate:9999999}]}}}};return 0", page)
        let variants = try await page.evaluate(ContextMenuVideoSource.xVariants, arguments: ["source": site+"/clip.mp4"], in: nil, world: .page) as? [[String: Any]] ?? []
        check(ContextMenuVideoSource.preferredVariant(variants)?.absoluteString == "https://video.twimg.com/high.mp4?tag=29", "Streaming video resolution uses the clicked player's best safe MP4")
        let absent = try await page.evaluate(ContextMenuVideoSource.xVariants, arguments: ["source": "blob:https://x.com/no-longer-present"], in: nil, world: .page) as? [Any]
        check(absent?.isEmpty == true, "A stale stream never picks another player's video")
        page.reload()
        try await wait("The page reloads") { await self.value("return document.querySelector('#video')?.readyState>=2", page) as? Bool == true && !page.isLoading }
        check(await rightClick("#video", in: page, modifiers: .shift)?.items.contains { $0.title == "Download Video" } == true, "The override is reinstalled on navigation")
    }
}
