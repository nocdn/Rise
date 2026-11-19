// Real Chromium anchoring, native Find-style annotation cards and semantic tab filtering.
// RISE_LIVE_STABLE_SIGNING=1 RISE_PEEK_OUT=build/annotation-proof python3 scripts/test-chromium-live.py Tests/Live/ChromiumAnnotationsChecks.swift
import AppKit
import Foundation
import RiseCore
import RiseChromium
@testable import Rise

final class AnnotationHTTP: URLProtocol {
    static let lock=NSLock()
    static var requests: [[[String:Any]]] = []
    static func recorded() -> [[[String:Any]]] { lock.lock();defer{lock.unlock()};return requests }
    private var stopped=false
    private let stateLock=NSLock()
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var data=request.httpBody ?? Data()
        if let stream=request.httpBodyStream { stream.open();defer{stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)} }
        let body=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        let messages=body["messages"] as? [[String:Any]] ?? []
        Self.lock.lock();Self.requests.append(messages);let number=Self.requests.count;Self.lock.unlock()
        let answer=number==1 ? "Stable identity lets the renderer recognize the same character across updates. It can animate that character from its old position to its new one, instead of removing it and inserting a replacement." : "Annotation 1 explains which characters persist. This passage explains when their movements run: a shared timeline keeps those individual transitions coordinated, so the whole phrase moves coherently."
        let pieces=["{\"snippet\":\"\"}\n"]+answer.split(separator:" ").map { String($0)+" " }
        DispatchQueue.global().async {
            let response=HTTPURLResponse(url:self.request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"text/event-stream"])!
            self.client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            Thread.sleep(forTimeInterval:0.35)
            for piece in pieces {
                self.stateLock.lock();let stopped=self.stopped;self.stateLock.unlock();if stopped{return}
                let chunk:[String:Any]=["choices":[["delta":["content":piece]]]]
                let json=String(decoding:try! JSONSerialization.data(withJSONObject:chunk),as:UTF8.self)
                self.client?.urlProtocol(self,didLoad:Data(("data: "+json+"\n\n").utf8));Thread.sleep(forTimeInterval:0.025)
            }
            self.client?.urlProtocol(self,didLoad:Data("data: [DONE]\n\n".utf8));self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock();stopped=true;stateLock.unlock() }
}

@main @MainActor struct AnnotationMain {
    static func main() {
        setvbuf(stdout,nil,_IONBF,0)
        DispatchQueue.main.asyncAfter(deadline:.now()+240){print("FAIL timed out");exit(1)}
        let folder=URL(fileURLWithPath:ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        let app=RCApplication.shared
        guard RCEngine.start(withCachePath:folder.appendingPathComponent("chromium").path,keychain:false)else{exit(1)}
        let runner=AnnotationRun(folder:folder);app.delegate=runner;app.setActivationPolicy(.regular);app.run();withExtendedLifetime(runner){}
    }
}
@MainActor final class AnnotationRun:NSObject,NSApplicationDelegate {
    let folder:URL
    var browser:BrowserController!
    var failures=0
    init(folder:URL){self.folder=folder}
    func check(_ value:Bool,_ name:String){print(value ? "PASS" : "FAIL",name);if !value{failures+=1}}
    func wait(_ name:String,_ test:() -> Bool)async throws {
        let end=Date().addingTimeInterval(12)
        while !test(),Date()<end{try await Task.sleep(for:.milliseconds(25))}
        check(test(),name);if !test(){throw NSError(domain:name,code:1)}
    }
    func command(_ args:[String])async throws->Data {
        try await Task.detached {
            let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/env");p.arguments=args;p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
            try p.run();let output=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            guard p.terminationStatus==0 else{throw NSError(domain:"Command failed: \(args.joined(separator:" ")): \(String(decoding:output,as:UTF8.self))",code:Int(p.terminationStatus))};return output
        }.value
    }
    func capture(_ name:String)async throws {
        try await Task.sleep(for:.milliseconds(350))
        if ProcessInfo.processInfo.environment["RISE_CAPTURE_EXTERNAL"] == "1" {
            let token = UUID().uuidString
            let ready: [String:Any] = ["pid":Int(getpid()),"name":name,"token":token]
            try JSONSerialization.data(withJSONObject:ready).write(to:folder.appendingPathComponent("capture-ready.json"),options:.atomic)
            let end = Date().addingTimeInterval(50)
            let receipt = folder.appendingPathComponent("capture-"+token+".done")
            while !FileManager.default.fileExists(atPath:receipt.path),Date()<end { try await Task.sleep(for:.milliseconds(100)) }
            guard FileManager.default.fileExists(atPath:receipt.path) else { throw NSError(domain:"Screenshot capture timed out",code:1) }
            print("SCREENSHOT",name); return
        }
        let data=try await command(["agent-desktop","list-windows"])
        let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let windows=object["data"] as? [[String:Any]] ?? []
        guard let id=windows.first(where:{($0["pid"] as? Int)==Int(getpid())})?["id"] as? String else{throw NSError(domain:"Capture window missing",code:1)}
        _=try await command(["agent-desktop","screenshot",folder.appendingPathComponent(name+".png").path,"--window-id",id])
        print("SCREENSHOT",name)
    }
    func applicationDidFinishLaunching(_ notification:Notification){Task{do{try await run()}catch{check(false,error.localizedDescription)};browser?.window?.close();print(failures==0 ? "ALL PASSED" : "\(failures) FAILED");exit(failures==0 ? 0 : 1)}}
    /// Send mouse events to the fixture window, including a physical mouse's middle button.
    func clickBadge(_ id:UUID, page:any WebPage, middle:Bool=false)async throws {
        guard let window=page.view.window else{throw NSError(domain:"Missing fixture window",code:1)}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        try await wait("The fixture window is active before delivering a click",{window.isKeyWindow&&NSApp.isActive})
        guard let value=try await page.runScript("return riseAnnotations.rect(id)",arguments:["id":id.uuidString],world:AnnotationScript.world) as? [String:Any],
              let r=value["rect"] as? [String:Double] else{throw NSError(domain:"Missing annotation badge",code:1)}
        let x=r["x"]!+r["width"]!/2,y=r["y"]!+r["height"]!/2
        let point=page.view.convert(NSPoint(x:x,y:page.view.isFlipped ? y : page.view.bounds.height-y),to:nil)
        for type in middle ? [NSEvent.EventType.otherMouseDown,.otherMouseUp] : [.leftMouseDown,.leftMouseUp] {
            let raw=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!.cgEvent!
            if middle{raw.setIntegerValueField(.mouseEventButtonNumber,value:2)}
            window.sendEvent(NSEvent(cgEvent:raw)!);try await Task.sleep(for:.milliseconds(40))
        }
    }
    func run()async throws {
        let html=#"""
        <!doctype html><html><head><meta charset="utf-8"><title>Why text animations need stable identity</title><meta name="description" content="A guide to identity, layout and shared timelines in text morphing animations."><style>
        body{margin:0;background:#fcfbf8;color:#242329;font:19px/1.75 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:760px;margin:55px auto;padding:0 48px}small{color:#847b92;font-size:12px;letter-spacing:1.6px;text-transform:uppercase}h1{font-size:43px;line-height:1.13;letter-spacing:-1.5px;max-width:650px;margin:20px 0 26px}h2{font-size:24px;margin:35px 0 10px}p{margin:15px 0}#second{margin-right:180px} .rule{height:1px;background:#ddd8e3;margin:28px 0}footer{color:#999;font-size:13px;margin:50px 0}</style></head><body><main><small>Interface notes · Motion & typography</small><h1>Why text animations need stable identity</h1><p>A good text transition helps the eye follow an idea as its wording changes. The important part is deciding what stays the same.</p><div class="rule"></div><h2>Keep track of what persists</h2><p id="first">Stable identities allow matching characters to move instead of being replaced.</p><p>The layout records each character’s position before and after the change. The difference becomes the motion between those positions.</p><h2>Give the movement a shared rhythm</h2><p id="second">A shared timeline keeps related transitions synchronized.</p><p>Characters that appear or disappear can fade while the surviving ones travel. Coordinating those changes makes the sentence feel like one continuous object.</p><footer>An article used for Rise’s annotation checks.</footer></main></body></html>
        """#
        let source = ProcessInfo.processInfo.environment["RISE_STRICT_CSP"] == "1"
            ? html.replacingOccurrences(of:"<style>",with:"<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'nonce-fixture'\"><style nonce=\"fixture\">") : html
        try source.write(to:folder.appendingPathComponent("annotations.html"),atomically:true,encoding:.utf8)
        let port=ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator:",")[0]
        let prefs=UserDefaults(suiteName:"AnnotationLive.\(UUID())")!
        browser=BrowserController(sessionURL:folder.appendingPathComponent("run-\(UUID())/session.json"),restore:false,preferences:prefs)
        browser.aiKeys.read={_ in nil};browser.aiKeys.write={_,_ in};browser.setAIKey(ModelChoice.liveOpenRouter.apiKey ?? "fixture",for:.openRouter);browser.setAIModel(PageAssistant.model,for:.openRouter)
        browser.window?.setContentSize(NSSize(width:1260,height:900));browser.showWindow(nil)
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AnnotationHTTP.self];let mockSession=URLSession(configuration:config);browser.annotations.session=mockSession
        let tab=browser.addTab(url:URL(string:"http://127.0.0.1:\(port)/annotations.html")!),page=tab.page
        try await wait("Article loads",{!page.isLoading && page.title?.contains("stable identity")==true})
        try await Task.sleep(for:.milliseconds(250))
        if tab.developer { browser.toggleDeveloperMode(for:tab);try await Task.sleep(for:.milliseconds(250)) }
        func select(_ id:String)async throws{_=try await page.runScript("const r=document.createRange();r.selectNodeContents(document.getElementById(id));const s=getSelection();s.removeAllRanges();s.addRange(r)",arguments:["id":id],world:nil)}
        try await select("first");browser.annotateSelection()
        try await wait("First annotation opens its Ask card",{browser.annotations.activeID != nil && browser.annotations.bar.mode == .ask})
        let key=PageAnnotationStore.key(for:page.url)!,first=browser.annotations.activeID!
        check(browser.annotations.store.document(for:key).annotations.first?.anchor.exact.contains("Stable identities")==true,"The saved anchor is the selected passage")
        let bar=browser.annotations.bar
        check(bar.askPlaceholder.stringValue=="Ask about this selection…" && !bar.askPlaceholder.superview!.isHidden,"A fresh annotation shows its contextual placeholder")
        let expanded=try await page.runScript("return riseAnnotations.rect(id)?.expanded",arguments:["id":first.uuidString],world:AnnotationScript.world) as? Bool
        check(expanded==true,"The number is hidden while its panel is expanded")
        if ProcessInfo.processInfo.environment["RISE_SKIP_CAPTURES"] != "1" {try await capture("annotation-empty")}
        bar.input.stringValue="Why does identity matter here?";bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:bar.input))
        (bar.input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location:bar.input.stringValue.utf16.count,length:0))
        if ProcessInfo.processInfo.environment["RISE_SKIP_CAPTURES"] != "1" { try await capture("annotation-typing") }
        bar.send();try await wait("Answer streams and saves",{browser.annotations.store.document(for:key).exchanges.count==1})
        try await Task.sleep(for:.milliseconds(500));if ProcessInfo.processInfo.environment["RISE_SKIP_CAPTURES"] != "1" { try await capture("annotation-answered") }
        browser.annotations.close();try await select("second");browser.annotateSelection()
        try await wait("A second independent annotation opens",{browser.annotations.activeID != nil && browser.annotations.activeID != first})
        let second=browser.annotations.activeID!
        bar.input.stringValue="How does this relate to annotation 1?";bar.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:bar.input));bar.send()
        try await wait("The second answer retains both annotations",{browser.annotations.store.document(for:key).exchanges.count==2})
        try await Task.sleep(for:.milliseconds(500));if ProcessInfo.processInfo.environment["RISE_SKIP_CAPTURES"] != "1" { try await capture("annotation-related-answer") }
        let requests=AnnotationHTTP.recorded()
        check(requests.count==2 && requests[1].contains{($0["content"] as? String ?? "").contains("Stable identity lets the renderer")},"The request contains the other annotation’s answer")
        check((requests.last?.last?["content"] as? String ?? "").contains("Annotation 1:"),"The request includes the numbered annotation index")
        // A click outside leaves the original click usable and folds the answer into its badge.
        let holdForCapture=ProcessInfo.processInfo.environment["RISE_CAPTURE_HANDOFF"] == "1"
        _=try await page.runScript("const prepare=riseAnnotations.prepareHandoff;let once=true;riseAnnotations.prepareHandoff=async id=>{if(once){once=false;await new Promise(resolve=>{if(hold)riseAnnotations.releaseHandoff=resolve;else setTimeout(resolve,120);});}return prepare(id);}",arguments:["hold":holdForCapture],world:AnnotationScript.world)
        let away=bar.convert(NSPoint(x:8,y:8),to:nil)
        let outside=NSEvent.mouseEvent(with:.leftMouseDown,location:away,modifierFlags:[],timestamp:0,windowNumber:browser.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        check(!browser.annotations.handleMouseDown(outside) && browser.annotations.activeID==nil,"Clicking away collapses without consuming the page click")
        try await Task.sleep(for:.milliseconds(240))
        check(browser.annotations.collapsingPanel?.superview != nil,"The landed surface covers a deliberately delayed renderer without a blank frame")
        if holdForCapture {
            try await capture("annotation-landed")
            _=try await page.runScript("riseAnnotations.releaseHandoff?.()",arguments:[:],world:AnnotationScript.world)
        }
        try await wait("The painted badge takes over the collapse surface",{browser.annotations.collapsingPanel==nil})
        check(browser.annotations.collapsingPanel==nil,"The collapse stand-in completes and releases its display link")
        let collapsed=try await page.runScript("return riseAnnotations.rect(id)?.expanded",arguments:["id":second.uuidString],world:AnnotationScript.world) as? Bool
        check(collapsed==false,"The real numbered badge takes over after collapse")
        if ProcessInfo.processInfo.environment["RISE_SKIP_CAPTURES"] != "1" {
            try await capture("annotation-collapsed")
            browser.chooseTheme(.dark);try await capture("annotation-collapsed-dark");browser.chooseTheme(.neutral)
        }
        try await clickBadge(second,page:page)
        try await wait("Clicking the collapsed number reopens its answer",{browser.annotations.activeID==second})
        check(bar.conversation.last?.answer.contains("Annotation 1")==true,"Reopening preserves the saved contextual answer")
        browser.annotations.close();page.reload();try await Task.sleep(for:.milliseconds(200));try await wait("Reload completes",{!page.isLoading})
        try await Task.sleep(for:.milliseconds(300))
        let count=try await page.runScript("return riseAnnotations.count()",arguments:[:],world:AnnotationScript.world) as? Int
        check(count==2,"Both quote anchors reattach after reload")
        check(PageAnnotationStore(url:browser.sessionURL.deletingLastPathComponent().appendingPathComponent("annotations.json")).document(for:key).exchanges.count==2,"Answers survive reopening the store")
        try await clickBadge(first,page:page,middle:true)
        try await wait("A mouse middle-click removes the collapsed annotation",{browser.annotations.store.document(for:key).annotations.count==1})
        check(browser.annotations.store.document(for:key).annotations.map(\.number)==[2],"Removing one note preserves the other note’s number")
        browser.annotations.removeAll(in:page);try await Task.sleep(for:.milliseconds(100))
        check((try await page.runScript("return riseAnnotations.count()",arguments:[:],world:AnnotationScript.world) as? Int)==0,"Remove all clears the page highlights and markers")
        _=try await page.runScript("const main=document.querySelector('main');for(const [id,context] of [['dup1','First unique context. '],['dup2','Second unique context. ']]){const section=document.createElement('section');section.dataset.fixture='duplicate';const lead=document.createElement('p');lead.textContent=context;const p=document.createElement('p');p.id=id;p.textContent='Repeated passage 😀 with identical wording.';section.append(lead,p);main.append(section)}document.getElementById('dup2').scrollIntoView({block:'center'})",arguments:[:],world:nil)
        try await select("dup2");browser.annotateSelection()
        try await wait("A repeated Unicode passage can be annotated",{browser.annotations.activeID != nil})
        let duplicate=browser.annotations.store.document(for:key).annotations.first!
        check(duplicate.anchor.prefix.contains("Second unique context"),"Neighbouring text disambiguates repeated passages")
        _=try await page.runScript("const p=document.createElement('p');p.textContent='Content inserted before all saved offsets.';document.querySelector('main').prepend(p);document.getElementById('dup2').style.cssText='position:fixed;right:0;bottom:0;width:100px;margin:0';",arguments:[:],world:nil)
        try await Task.sleep(for:.milliseconds(400))
        let geometry=try await page.runScript("const b=riseAnnotations.rect(id);const p=document.getElementById('dup2').getBoundingClientRect();return {badge:b,targetY:p.y,lines:document.getElementById('dup2').getClientRects().length,width:innerWidth,height:innerHeight}",arguments:["id":duplicate.id.uuidString],world:AnnotationScript.world) as? [String:Any] ?? [:]
        let marker=((geometry["badge"] as? [String:Any])?["rect"] as? [String:Any]) ?? [:]
        let x=marker["x"] as? Double ?? -100,y=marker["y"] as? Double ?? -100
        check(abs((marker["width"] as? Double ?? 0)-21)<0.1,"Marker styling survives a strict page content-security policy")
        check(x>=8 && x+21<=(geometry["width"] as? Double ?? 0)-8 && y>=8 && y+21<=(geometry["height"] as? Double ?? 0)-8,"The marker stays inside the viewport at the bottom-right edge")
        check(abs(y-(geometry["targetY"] as? Double ?? -1000))<40,"The marker follows the correct duplicate after offsets and layout change")
        browser.annotations.removeAll(in:page)
        _=try await page.runScript("document.querySelectorAll('[data-fixture=duplicate]').forEach(n=>n.remove());scrollTo(0,0);getSelection().removeAllRanges()",arguments:[:],world:nil)
        browser.annotateSelection();try await Task.sleep(for:.milliseconds(150))
        check(browser.annotations.store.document(for:key).annotations.isEmpty,"An empty selection cannot create an annotation")
        browser.smartTabSearch.collect(tab);try await wait("Compact page metadata is collected",{browser.smartTabSearch.detail(tab).contains("text morphing")})
        let repo=browser.addTab();repo.requestedURL=URL(string:"https://github.com/lochie/torph");repo.title="Torph — text morphing"
        browser.update();browser.smartTabSearch.lookup={_ in "{\"tabs\":[\"\(repo.id)\"]}"}
        browser.searchTabs();let sidebar=browser.sidebar!
        sidebar.searchRow.field.stringValue="find me the GitHub page of the text morphing library";sidebar.searchTabs(for:sidebar.searchRow.field.stringValue);sidebar.chooseSearchedTab()
        try await wait("Semantic results appear in the sidebar",{sidebar.modelSearchIDs != nil})
        check(sidebar.orderedIDs==[repo.id],"The model filters the existing rows without opening or navigating a tab")
        sidebar.chooseSearchedTab();check(browser.selectedID==repo.id && !sidebar.isSearchingTabs,"Enter selects a semantic result normally")
        if ProcessInfo.processInfo.environment["RISE_REAL_AI_CHECK"] == "1" {
            browser.smartTabSearch.lookup = nil
            browser.selectAIProvider(.openRouter)
            browser.searchTabs();sidebar.searchRow.field.stringValue="find me the GitHub page of the text morphing library";sidebar.searchTabs(for:sidebar.searchRow.field.stringValue);sidebar.chooseSearchedTab()
            try await wait("The live model answers the tab query",{!sidebar.searchRow.thinking})
            check(sidebar.modelSearchIDs?.first==repo.id,"The live model selects Torph for a natural-language description")
            sidebar.endTabSearch()
            browser.select(tab.id);try await select("first");browser.annotateSelection()
            try await wait("A live-provider annotation opens",{browser.annotations.activeID != nil})
            browser.annotations.session = .shared
            bar.input.stringValue = "According to the article, what does stable identity allow a character to do?";bar.send()
            try await wait("The live model streams an annotation answer",{browser.annotations.store.document(for:key).exchanges.count==1})
            let response = browser.annotations.store.document(for:key).exchanges.first!.answer.lowercased()
            check(response.contains("mov") || response.contains("match") || response.contains("replac"),"The live annotation answer is grounded in the article")
        }
        mockSession.invalidateAndCancel()
    }
}
