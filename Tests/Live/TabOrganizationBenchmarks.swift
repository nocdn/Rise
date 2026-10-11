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
                browser.window!.sendEvent(event(.leftMouseDragged,point:NSPoint(x:45,y:12),view:browser.sidebar.rowsHost))
                check(browser.tabs.map(\.id) == [b.id,c.id,a.id] && clicks == 1,"Native vertical drag commits one crossing and haptic")
                check(row.convert(row.bounds, to: browser.sidebar.rowsHost).minX == 6 && row.frame.size == initial.size && b.webView === web,"Dragging keeps width, height, x-position and WebKit identity")
                try await Task.sleep(for:.milliseconds(80))
                let moved = browser.sidebar.rows[c.id]!
                check(moved.layer!.presentation()!.position.y != moved.layer!.position.y,"Neighbors visibly move instead of jumping")
                browser.window!.sendEvent(event(.leftMouseUp,point:NSPoint(x:45,y:12),view:browser.sidebar.rowsHost))
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
                let floating = browser.sidebar.rows[a.id]!, originalOrder = browser.tabs.map(\.id)
                floating.layer?.removeAllAnimations()
                let originalFrame = floating.frame
                let grab = floating.convert(NSPoint(x: 50, y: 18), to: browser.sidebar.rowsHost)
                var releases = 0; browser.sidebar.detachmentClick = { releases += 1 }
                browser.window!.sendEvent(event(.leftMouseDown, point: NSPoint(x: 50, y: 18), view: floating))
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x, y: grab.y-4), view: browser.sidebar.rowsHost))
                check(!browser.sidebar.drag!.isDetached && floating.superview === browser.sidebar.drag!.overlay,
                      "Vertical drags carry an unclipped shadow too")
                let shadowView = browser.sidebar.drag!.overlay!.shadowView
                try await Task.sleep(for: .milliseconds(35))
                let shadow = shadowView.layer!.presentation()!.shadowOpacity
                check(shadow > 0 && shadow < shadowView.layer!.shadowOpacity, "The drag shadow visibly fades in")
                try await Task.sleep(for: .milliseconds(180))
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x+24, y: grab.y), view: browser.sidebar.rowsHost))
                let resisted = floating.convert(floating.bounds, to: browser.sidebar.rowsHost)
                check(resisted.minX > originalFrame.minX && resisted.minX < originalFrame.minX+24,
                      "A rightward pull moves the row with resistance")
                let halfShadow = shadowView.layer!.shadowOpacity
                check(halfShadow > TabDragMotion.liftedShadowOpacity && halfShadow < TabDragMotion.detachedShadowOpacity,
                      "The card shadow strengthens as the pull approaches release")
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x+60, y: grab.y), view: browser.sidebar.rowsHost))
                try await Task.sleep(for: .milliseconds(60))
                check(browser.sidebar.drag!.isDetached && releases == 1, "The threshold releases the tab with one haptic")
                check(shadowView.layer!.presentation()!.shadowOpacity == TabDragMotion.detachedShadowOpacity,
                      "The detached card has its full shadow at the threshold")
                check(shadowView.layer!.shadowPath!.boundingBox == floating.bounds, "The shadow follows just the tab outline")
                check(!shadowView.clipsToBounds && !shadowView.layer!.masksToBounds, "AppKit does not clip the animated card shadow")
                check(abs(floating.layer!.presentation()!.transform.m41) > 0.1, "The released row visibly springs toward the cursor")
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: 600, y: 350), view: browser.sidebar.rowsHost))
                check(floating.superview === browser.sidebar.drag!.overlay, "The live row floats above the page")
                browser.window!.sendEvent(event(.leftMouseUp, point: NSPoint(x: 600, y: 350), view: browser.sidebar.rowsHost))
                check(browser.sidebar.drag == nil && browser.sidebar.returningDrag != nil, "An outside release starts a return flight")
                check(shadowView.layer!.animation(forKey: TabDragMotion.shadowKey) != nil, "The returning shadow fades out")
                try await Task.sleep(for: .milliseconds(70))
                check(abs(floating.layer!.presentation()!.transform.m41) > 0.1, "The return travels through the page instead of jumping")
                try await Task.sleep(for: .milliseconds(700))
                check(browser.sidebar.returningDrag == nil && floating.superview === browser.sidebar.rowsHost,
                      "The completed flight returns the actual row to the scroller")
                check(floating.frame == originalFrame && browser.tabs.map(\.id) == originalOrder && releases == 1,
                      "An outside drop restores the original slot and order")
                check(floating.dragFill == nil, "The return clears the solid drag appearance")
                // A downward edge pull has the same resistance, release and free flight as a sideways pull.
                browser.window!.sendEvent(event(.leftMouseDown, point: NSPoint(x: 50, y: 18), view: floating))
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x, y: grab.y+24), view: browser.sidebar.rowsHost))
                let elastic = floating.convert(floating.bounds, to: browser.sidebar.rowsHost)
                check(elastic.minY > originalFrame.minY && elastic.minY < originalFrame.minY+24,
                      "The list end allows movement with resistance")
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x, y: grab.y+60), view: browser.sidebar.rowsHost))
                try await Task.sleep(for: .milliseconds(60))
                check(browser.sidebar.drag!.isDetached && releases == 2, "A vertical edge pull releases with a haptic")
                check(abs(floating.layer!.presentation()!.transform.m42) > 0.1, "The edge release bounces vertically to the cursor")
                browser.window!.sendEvent(event(.leftMouseUp, point: NSPoint(x: grab.x, y: grab.y+60), view: browser.sidebar.rowsHost))
                let edgeShadow = browser.sidebar.returningDrag!.overlay!.shadowView
                try await Task.sleep(for: .milliseconds(130))
                check(edgeShadow.layer!.presentation()!.shadowOpacity < 0.001, "The return shadow disappears before the tab settles")
                try await Task.sleep(for: .milliseconds(600))
                check(floating.frame == originalFrame && browser.tabs.map(\.id) == originalOrder, "The edge drop returns to the last slot")
                // Release, then immediately leave: the returning overlay must not hold hover for its spring duration.
                browser.window!.sendEvent(event(.leftMouseDown, point: NSPoint(x: 50, y: 18), view: floating))
                browser.window!.sendEvent(event(.leftMouseDragged, point: NSPoint(x: grab.x, y: grab.y-4), view: browser.sidebar.rowsHost))
                browser.window!.sendEvent(event(.leftMouseUp, point: NSPoint(x: grab.x, y: grab.y-4), view: browser.sidebar.rowsHost))
                browser.window!.sendEvent(event(.mouseMoved, point: NSPoint(x: 600, y: grab.y), view: browser.sidebar.rowsHost))
                check(!floating.isHovered && floating.dragFill == nil && floating.layer!.backgroundColor!.alpha == 0,
                      "The first pointer movement clears hover during the return spring")
                try await Task.sleep(for: .milliseconds(600))
                browser.window?.setContentSize(NSSize(width: 900, height: 600))
                for _ in 0..<30 { browser.addTab() }
                browser.root.layoutSubtreeIfNeeded()
                let scrolling = browser.sidebar.rows[browser.selectedID!]!
                browser.window!.sendEvent(event(.leftMouseDown, point: NSPoint(x: 50, y: 18), view: scrolling))
                browser.window!.sendEvent(event(.leftMouseDragged,
                    point: NSPoint(x: 50, y: browser.sidebar.scroll.contentView.bounds.maxY-6), view: browser.sidebar.rowsHost))
                try await Task.sleep(for: .milliseconds(180))
                check(browser.sidebar.scroll.contentView.bounds.minY > 0, "The live clock autoscrolls a lifted vertical drag")
                browser.sidebar.cancelTabInteractions()
                print("PASS: native reordering, resisted side and list-end pulls, spring release and return, progressive card shadows, immediate hover exit, autoscroll, haptics and inline naming")
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
