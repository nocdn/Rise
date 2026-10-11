import AppKit
import WebKit
@testable import Rise

@main @MainActor struct TabOrganizationBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = TabOrganizationVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class TabOrganizationVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore:false)
                browser.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
                let a = browser.addTab(), b = browser.addTab(), c = browser.addTab()
                a.webView.loadHTMLString("<title>Actual page title</title><body>Real WebKit content",baseURL:nil)
                try await Task.sleep(for:.milliseconds(400))
                browser.select(b.id); browser.root.layoutSubtreeIfNeeded()
                let row = browser.sidebar.rows[b.id]!, initial = row.frame
                let web = b.webView
                var clicks = 0; browser.sidebar.crossingClick = { clicks += 1 }
                browser.window!.sendEvent(event(.leftMouseDown,point:NSPoint(x:50,y:18),view:row))
                try await Task.sleep(for:.milliseconds(150))
                let scale = row.layer!.presentation()!.affineTransform().a
                check(abs(scale-1) < 0.001,"Holding a tab does not scale it")
                let shadowScale = browser.sidebar.selectedTabShadow.layer!.presentation()!.affineTransform().a
                check(abs(scale-shadowScale) < 0.002,"The selected shadow keeps its full size")
                check(row.frame == initial,"Pressing leaves tab geometry unchanged")
                browser.window!.sendEvent(event(.leftMouseDragged,point:NSPoint(x:900,y:12),view:browser.sidebar.rowsHost))
                check(browser.tabs.map(\.id) == [b.id,c.id,a.id] && clicks == 1,"Native vertical drag commits one crossing and haptic")
                check(row.frame.minX == 6 && row.frame.size == initial.size && b.webView === web,"Dragging keeps width, height, x-position and WebKit identity")
                try await Task.sleep(for:.milliseconds(80))
                let moved = browser.sidebar.rows[c.id]!
                check(moved.layer!.presentation()!.position.y != moved.layer!.position.y,"Neighbors visibly move instead of jumping")
                browser.window!.sendEvent(event(.leftMouseUp,point:NSPoint(x:900,y:12),view:browser.sidebar.rowsHost))
                try await Task.sleep(for:.milliseconds(600))
                check(abs(row.layer!.presentation()!.affineTransform().a-1) < 0.001,"Release leaves the tab at full size")
                let old = row.layer!.position.y
                let d = browser.addTab(); browser.root.layoutSubtreeIfNeeded()
                check(browser.sidebar.rows[d.id]!.frame.minY == 0,"A new tab appears immediately at the top")
                try await Task.sleep(for:.milliseconds(70))
                let during = row.layer!.presentation()!.position.y
                check(during > old && during < row.layer!.position.y,"Existing rows visibly make space for a new tab")
                browser.closeTab(d.id)
                try await Task.sleep(for:.milliseconds(250))
                check(abs(row.layer!.presentation()!.position.y-old) < 0.01,"Closing a tab settles the list into the space above")
                browser.window!.sendEvent(event(.leftMouseDown,point:NSPoint(x:50,y:18),view:row,clicks:2))
                let editor = row.titleField.currentEditor() as! NSTextView
                check(editor.selectedRange().length == row.titleField.stringValue.utf16.count,"Double click selects the whole native title")
                editor.string = "Named workspace"
                _ = row.control(row.titleField,textView:editor,doCommandBy:#selector(NSResponder.insertNewline(_:)))
                check(b.customTitle == "Named workspace" && row.frame.size == initial.size,"Rename saves immediately without changing layout")
                print("PASS: native drag routing, preserved WebKit identity, no press scaling, neighbor movement, insertion/collapse and inline field editor")
                browser.sidebar.cancelTabInteractions(); browser.saveWork?.cancel(); browser.window?.orderOut(nil); NSApp.terminate(nil)
            } catch { fputs("TAB ORGANIZATION VERIFICATION FAILED: \(error)\n",stderr); exit(1) }
        }
    }
    func check(_ value:Bool,_ message:String) { if !value { fputs("FAIL: \(message)\n",stderr); exit(1) } }
    func event(_ type:NSEvent.EventType,point:NSPoint,view:NSView,clicks:Int=1)->NSEvent {
        NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
            windowNumber:browser.window!.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:type == .leftMouseUp ? 0 : 1)!
    }
}
